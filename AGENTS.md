# AGENTS.md

Guidance for AI coding agents (and humans) working on Voca — a macOS menu bar app for globally capturing selected text into a local-first SQLite library, with clipboard history and a fullscreen "galaxy" word sphere.

## Project Facts

- **Stack**: Swift 5 language mode (SPM `swift-tools-version: 5.9`), SwiftUI + AppKit, GRDB 7 (SQLite), KeyboardShortcuts 2.
- **Platform**: macOS 14+ (developed and tested on macOS 27 / Swift 6.4 toolchain, arm64).
- **License**: AGPL-3.0-or-later. Every source file carries the standard GNU header + `SPDX-License-Identifier: AGPL-3.0-or-later`. Add it to any new file.
- **Local-only files**: `log.md` and `git-log.md` are private working logs. They are gitignored and must NEVER be staged, committed, or force-added. `research/` and `.vscode/` are also ignored.
- **Commit style**: English Conventional Commit summary + two mirrored description paragraphs (English first, Chinese second).

## Build & Run

```bash
swift build          # debug compile — must pass with zero errors AND zero warnings
./build.sh           # release build + assemble build/Voca.app + codesign + verify
open build/Voca.app  # launch
open -n build/Voca.app --args --galaxy  # force a NEW instance with the galaxy open (testing)
```

Never ship a build that produced warnings; every warning so far has predicted a real bug.

## Source Map

| File | Responsibility |
|---|---|
| `Sources/Voca/VocaApp.swift` | App entry, menu bar panel, records window, edit/timeline sheets, hotkey wiring |
| `Sources/Voca/CaptureEngine.swift` | AX selection capture, ⌘C fallback, browser URL query (`BrowserTabURL`) |
| `Sources/Voca/ClipboardWatcher.swift` | changeCount polling, history persistence, copy-back, history UI |
| `Sources/Voca/Store.swift` | GRDB schema/migrations, merge-on-save, queries, markdown export |
| `Sources/Voca/Toast.swift` | Non-activating bottom-right toast panel |
| `Sources/Voca/GalaxyView.swift` | Galaxy model, fullscreen window controller, sphere layout (native frosted core + refractive ring), detail panel |
| `build.sh` | Assemble + sign the .app; the ONLY correct way to produce a runnable bundle |

## Hard-Won Platform Lessons

These each cost a crash, a silent failure, or a debugging session. Respect them.

### 1. Packaging: dependency resource bundles are mandatory

SPM executables that depend on packages with localized strings (KeyboardShortcuts) MUST copy the generated `*.bundle` from `.build/release/` into `Voca.app/Contents/Resources/`. Without it the app **crashes with `EXC_BREAKPOINT` in `Bundle.module` initialization the moment a `KeyboardShortcuts.Recorder` renders** — i.e., on first click of the menu bar icon, long after launch. `build.sh` does this copy; never assemble a bundle by hand without it.

### 2. Code signing: ad-hoc signatures silently break TCC grants

A linker-signed (ad-hoc) binary gets a new CDHash on every rebuild. macOS TCC keys accessibility/automation grants on the code signature, so **every rebuild invalidates permissions while System Settings still shows the app as enabled** — the user sees "permission granted" but every check fails. The fix in place: a self-signed identity named `Voca Development` in the login keychain (trusted for code signing); `build.sh` signs with it and falls back to ad-hoc only if missing. After signing, `codesign --verify` must report `satisfies its Designated Requirement`. A signature that fails verify (e.g., after adding Resources without re-signing) also breaks trust.

### 3. `NSAppleEventsUsageDescription` or bust

Sending Apple Events without `NSAppleEventsUsageDescription` in Info.plist is **silently denied with no prompt** on modern macOS (Sequoia+). Symptom: browser URL query returns nothing and no authorization dialog ever appears. The key is in `build.sh`'s generated plist — keep it there. Automation prompts are per (source, target) pair and appear once.

### 4. Never remove an event monitor from inside its own callback

Calling `NSEvent.removeMonitor` synchronously inside the monitored handler releases the monitor mid-invocation → **segfault in `objc_release` during autorelease pool drain**. The crash log points at `NSApplication.run`, nowhere near the cause. `GalaxyWindowController` defers `close()` with `DispatchQueue.main.async` — preserve that pattern.

### 5. NSHostingController resizes windows to SwiftUI's "ideal size"

`window.contentViewController = NSHostingController(rootView:)` shrinks the window to the view's fitting size. A `Canvas` has no intrinsic size, so a fullscreen contentRect collapsed into a small block in the corner. Use `window.contentView = NSHostingView(rootView:)` **plus an explicit `setFrame(..., display: true)`** afterwards. Transparent fullscreen overlay = `styleMask: [.borderless, .fullSizeContentView]`, `isOpaque = false`, `backgroundColor = .clear`.

### 6. Canvas specifics

- There is **no `context.shadow` property**. Use `context.drawLayer { layer in layer.addFilter(.shadow(...)); layer.draw(...) }`.
- Per-item transforms (the text-on-sphere effect) are `translateBy` / `rotate(by:)` / `scaleBy(x:y:)` inside a `drawLayer`.
- Mutating model state inside the Canvas closure is fine (it runs on main); use `TimelineView(.animation)` as the frame driver and clamp `dt`.
- For 60fps with hundreds of texts: draw back-to-front, skip the drop-shadow layer for back-half items, cache nothing per frame you can compute with SIMD math.

### 7. GRDB / SQLite migration rules learned by crash

- GRDB 7 has **no `alterTable` helper** — write raw `ALTER TABLE` SQL in migrations.
- SQLite **rejects non-constant defaults** (`CURRENT_TIMESTAMP`) in `ADD COLUMN`. Use a constant default, then backfill with `UPDATE`.
- Column type is `.integer`, not `.int64`. Ordering uses `Column("createdAt").desc`, not a bare property name.
- Migrations are transactional: a failed one rolls back cleanly, so a fixed migration re-runs on next launch. A **fatalError in app init from a failed migration looks like a random startup crash** — read the error before assuming code bugs.
- The whole app runs Swift 5 language mode; GRDB writes happen synchronously on main (fine at this scale) and `@Published` updates must land on main.

### 8. Text capture engine patterns

- Primary path: `AXUIElementCreateSystemWide()` + `kAXSelectedTextAttribute`. Check `kAXFocusedUIElementAttribute` role `== "AXSecureTextField"` to skip password fields.
- **Conditional downcast `as?` to CF types (AXUIElement) is a compile error** ("always succeeds"). Compare `CFGetTypeID(raw) == AXUIElementGetTypeID()` then `unsafeBitCast`.
- Fallback: post ⌘C via `CGEvent`, poll `pasteboard.changeCount` (≤400ms), read string **only if changeCount actually changed** (avoids stale-clipboard false positives), then snapshot-restore the user's pasteboard.
- Pause the clipboard watcher while simulating ⌘C (thread-safe static flag in `CaptureEngine.isSimulatingCopy`) or the watcher records both the copy and the restore.

### 9. Clipboard monitoring truth

macOS has **no push API for pasteboard changes** — polling `changeCount` on a 0.5s timer is the canonical technique (same as Maccy/Raycast). The per-tick cost is an integer compare; do not "optimize" this into event taps (they miss right-click copies and need Input Monitoring permission). Skip entries marked `org.nspasteboard.ConcealedType` (password-manager convention). Text entries persist to `clipboard_entries` (≤200); images/files are session-only by design.

### 10. Browser URL via AppleScript

`BrowserTabURL` maps bundle IDs to AppleScript targets: Safari uses `URL of front document`; Chromium family (Chrome/Edge/Brave/Arc/Vivaldi/Opera) uses `URL of active tab of front window`. Firefox exposes nothing — honest degradation to app-name only. `NSAppleScript` must run on the main thread (background capture path wraps it in `DispatchQueue.main.sync`). Accept only `http`-prefixed results. Failures are logged with an `NSAppleScript` error dictionary via `NSLog` (search Console for `Voca:`).

### 11. SDK quirks on the macOS 27 SDK

- `NSPasteboard.types` is Optional — unwrap before `.contains`.
- `DateFormatter` styles are `.medium/.short`; `.abbreviated/.standard` belong to `Date.FormatStyle` only.
- `executeAndReturnError` returns a non-optional descriptor here — no optional chaining.
- Typos cost real time: one `NScreen` instead of `NSScreen` killed a build; read compiler output before theorizing.

### 12. Interaction design settled by user testing

- Silent save + bottom-right toast; destructive actions (delete/clear, both windows) require `confirmationDialog` with scope stated (timeline cascade, "does not affect library").
- Merge-on-save semantics: same text → count+1, float to top (`lastSeenAt`), one timeline event per save, URL takes newest non-nil.
- Notes: light-gray inline display, unbounded lines; markdown export = bare entries + `>` blockquote notes, blank line between blocks, **no URLs in export**.
- Copy-back from app UI must sync the watcher's `lastChangeCount` so self-writes never enter clipboard history.

### 13. The stale-process trap: `open` activates, it does not launch

If any Voca instance is already running, `open build/Voca.app` merely activates it and **silently drops `--args`**. During a multi-minute rebuild the owner (or a login item) can relaunch the old binary, so your "test" of a new build actually exercises stale code — symptoms include "no visual change no matter what I edit". Always `pkill -x Voca` first, then `open -n … --args …` to force a new instance, and verify the PID changed.

### 14. NSLog is redacted to `<private>` in the unified log

NSLog with dynamic format arguments shows up as `(Foundation) <private>` in `log show` — message-content predicates (`eventMessage CONTAINS …`) never match, which looks exactly like "the code never ran". Do not conclude anything from absent logs. For real diagnostics, write trace lines to a file (e.g. `/tmp/voca_*.txt`) from the code under test, or filter by `process == "Voca"` and notice the `<private>` cadence.

### 15. ScreenCaptureKit fails silently — never gate critical UI on it

When the screen-recording grant is present-but-ineffective, `CGPreflightScreenCaptureAccess()` can return **true**, `SCShareableContent.getExcludingDesktopWindows` returns **no error**, and the content comes back with empty/missing displays — every guard fails silently, the stream never delivers a frame, and an MTKView lens renders nothing forever. Consequences: (a) diagnose in both launch modes — a directly-executed binary inherits the terminal's TCC grants and works, while the `open`-launched bundle uses its own identity; (b) critical visuals must degrade to native primitives (see the galaxy design below). Also: **never run `tccutil reset` on a working grant** "to re-test the flow" — it destroys a functioning permission and the re-grant may not become effective for the bundle.

### 16. macOS has no `timeout` command

`timeout 5 ./binary` fails with command-not-found and runs nothing. Use `(binary & echo $! > pid); sleep N; kill $(cat pid)`.

### 17. Tooling discipline learned the hard way

- Regex/script bulk edits of Swift via `python3` silently no-op when anchors drift — or worse, eat enclosing braces. Use precise anchored edits and `grep`-verify every injection.
- This model has no vision: `screencapture -x /tmp/x.png` + a subagent with `read_image` is a reliable ground-truth loop for UI debugging; ask the subagent to describe specific regions, not to guess causes.
- A `--galaxy` launch argument opens the star map at startup (AppDelegate) — keep it for automation.

## Galaxy View Notes (design settled 2026-09-22, owner-approved)

Current structure in `GalaxyView.sphere(diameter:)`, outer→inner:

1. **Metal refraction lens** (`GalaxyLensView`, full lens circle, 1.4× sphere diameter) — original refraction+dispersion shader; only its outer annulus is visible.
2. **Native glass ring** (same 1.4× circle, `.glassEffect(.clear)`) — guaranteed transparent refractive fallback when ScreenCaptureKit delivers nothing.
3. **Frosted core** (sphere diameter): `.ultraThinMaterial` + radial dark-bias gradient (`black 0.10 → 0.28`), top-left highlight (`white 0.22`), rim stroke — always readable, zero permissions.
4. **SceneKit word sphere** (`GalaxySphereView`) — curved ribbon labels, font size = save count, morpher-based zoom (0.5–2.5×, persisted), auto-rotate 0.06 rad/s with inertia drag.

Tuning: a live panel (slider icon in the galaxy top bar) exposes ten persisted parameters via the `GalaxyTuning` singleton — dispersion, chroma exponent, refraction warp/falloff, rim strength, fresnel tint, sphere scale, ring scale, and frosted-core center/edge darkening. Metal-side values ride a `tuning` float4 uniform each frame; defaults are the owner-approved preset. **Known open issue**: in `open`-launched sessions the Metal lens still does not composite even after a re-granted Screen Recording permission (native glass ring carries the look); the panel and all parameters are verified working and will drive the lens once capture delivers frames.

## Workflow Contract (from the human owner)

1. Implement → `swift build` clean → `./build.sh` → relaunch → hand to the user for testing.
2. **Never write `log.md`/`git-log.md` or commit until the user has tested and explicitly asked.** This rule was established after a premature write.
3. Commit shape: stage only project files, verify `git diff --cached --name-only` excludes the private logs, bilingual message, report the hash.
