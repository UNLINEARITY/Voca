# AGENTS.md

Guidance for AI coding agents and humans working on Voca, a macOS menu bar app for capturing selected text into a local-first SQLite library, with clipboard history and a fullscreen word galaxy.

## Project facts

- **Stack**: Swift 5 language mode (SPM `swift-tools-version: 5.9`), SwiftUI + AppKit, GRDB 7, KeyboardShortcuts 2.
- **Platform**: macOS 26+ (currently developed on macOS 27 / Swift 6.4, arm64).
- **License**: AGPL-3.0-or-later. Every new source file must carry the project’s standard GNU header and `SPDX-License-Identifier: AGPL-3.0-or-later`.
- **Local-only files**: `log.md`, `git-log.md`, `research/`, and `.vscode/` are ignored working material. Never stage, commit, or force-add them.

A historical implementation choice is not a permanent constraint. The user’s current request may replace existing architecture or visual design as long as the hard repository, privacy, and safety requirements below remain satisfied.

## Build and run

```bash
swift build
./build.sh
open build/Voca.app
open -n build/Voca.app --args --galaxy
```

`build.sh` is the supported release-bundle path today: it assembles resources, signs the app, and verifies the result. If packaging is changed, the replacement must preserve those outcomes and update the associated checks and documentation.

A completed build must contain zero errors and zero warnings.

## Versioning and releases

- The app version has a single source: the nearest Git tag, read by `build.sh` (`git describe --tags --abbrev=0`). It feeds the generated `Info.plist` (`CFBundleShortVersionString`) and Settings → About; the build number is the commit count. No source or documentation file carries a hand-maintained version number — preparing a release never involves version bumps elsewhere. Verify this before claiming one was missed.
- Preparing a release `<tag>`: write `docs/releases/<tag>.md` and `docs/releases/<tag>_CN.md` from the real `git diff <previous_tag>..<tag>` (not commit titles), structurally aligned and bilingual, with every claim checked against the diff; then run the full gate (`swift build`, `swift test`, `./build.sh`).
- Pushing a plain `x.y.z` tag triggers `.github/workflows/release.yml`: build → test → bundle → ZIP + DMG → GitHub Release combining the curated **English** notes with auto-generated ones; the workflow requires `docs/releases/<tag>.md` to exist. A tag is not itself a downloadable asset; CI artifacts are ad-hoc signed and not notarized.

## Source map

| File | Primary responsibility |
|---|---|
| `Sources/Voca/VocaApp.swift` | App entry, menu bar panel, library list, sheets, hotkeys |
| `Sources/Voca/WorkspaceNavigation.swift` | Unified library/clipboard window, keyboard routes, layer transitions |
| `Sources/Voca/CaptureEngine.swift` | Accessibility capture, copy fallback, browser context |
| `Sources/Voca/ClipboardWatcher.swift` | Pasteboard monitoring, history persistence, copy-back |
| `Sources/Voca/TrackpadGestureMonitor.swift` | Opt-in private trackpad monitoring, device lifecycle, save dispatch |
| `Sources/Voca/ThreeFingerSwipeRecognizer.swift` | Pure three-finger downward gesture state machine |
| `Sources/Voca/Store.swift` | GRDB schema, migrations, writes, queries, export |
| `Sources/Voca/Toast.swift` | Non-activating toast panel and save feedback animation |
| `Sources/Voca/UICommon.swift` | Shared UI constants: typography derivation, corner radii, floating-surface modifier, list truncation probe |
| `Sources/Voca/GalaxyView.swift` | Galaxy model, window, rendering, interaction |
| `Sources/Voca/GalaxyTimeWallView.swift` | Timeline tab static time wall: time-mapped layout, zoom/pan, date ticks, highlight & lookup |
| `Sources/Voca/DictionaryService.swift` | Embedded read-only ECDICT lookup, word detection, display formatting |
| `Sources/Voca/DictionaryCardView.swift` | Dictionary card for the lookup popup (phonetics, senses, tags, speak buttons) |
| `Sources/Voca/SpeechService.swift` | Offline system TTS with per-accent best-voice selection |
| `Sources/Voca/TranslationService.swift` | Apple on-device translation wrapper (en↔zh) and translator view |
| `Sources/Voca/SettingsView.swift` | Settings tab in the workspace panel: toggles, shortcuts, library management, database, about |
| `Sources/Voca/LibraryInfo.swift` | Library stats, database size, safe VACUUM INTO snapshot backup |
| `Sources/Voca/LookupPopupController.swift` | Cursor-side lookup/translation popup, service receiver, placement |
| `scripts/make_dictionary.py` | Generates the embedded dictionary.sqlite from the ECDICT CSV, wordroot.txt, and Moby Thesaurus |
| `build.sh` | Release bundle assembly, resources, signing, verification |

Treat this map as navigation, not as an architectural boundary. Update it when responsibilities move.

## Required behavior and safety invariants

### Packaging and permissions

- The runnable app bundle must include dependency resource bundles required at runtime, including KeyboardShortcuts localization resources. Bundles may only live under `Contents/` — code signing rejects unsealed contents at the `.app` root. The Release workflow builds on the `xcode-27` runner image (Swift 6.4 + macOS 27 SDK, matching local development): Swift ≤ 6.3.3 toolchains generate `Bundle.module` accessors that search the `.app` root, crashing packaged apps wherever a dependency (e.g. KeyboardShortcuts' recorder) first loads its module bundle, and the swift.org 6.4 toolchain against older SDKs cannot compile `translationTask`. `Voca_Voca.bundle` is resolved toolchain-independently through `AppResources.module`.
- Never reference `Bundle.module` directly: resolve module resources through `AppResources.module` in `UICommon.swift`. Toolchain-generated accessors have regressed across versions (a Swift 6.2-era accessor searched the `.app` root instead of `Contents/Resources`, crashing CI builds at launch); the bundled resolver's candidate chain is toolchain-independent.
- The final bundle must pass `codesign --verify` and satisfy its Designated Requirement. Do not assume an ad-hoc build preserves existing TCC grants.
- The generated Info.plist must include `NSAppleEventsUsageDescription` while the app sends Apple Events.
- Do not reset TCC permissions without the user’s explicit authorization.

### Capture and clipboard privacy

- Never capture text from secure text fields.
- Copy fallback must only accept pasteboard content after `changeCount` changes, and must restore the user’s previous pasteboard state.
- Simulated copies must not be recorded as clipboard-history entries.
- Skip pasteboard entries marked `org.nspasteboard.ConcealedType`.
- Copy-back initiated by Voca must synchronize watcher state so it is not re-ingested as external history.
- Browser-context failures must degrade honestly; absence of a URL must not prevent text capture.

### Storage and destructive actions

- Preserve merge-on-save behavior unless the requested product behavior explicitly changes: identical text increments its count, updates recency, records a timeline event, and adopts the newest non-nil URL.
- SQLite migrations must remain transactional and work against existing user databases.
- Delete and clear operations require confirmation that states their scope.
- Clipboard history and the saved-text library remain distinct unless an explicit migration changes that contract.

### UI and runtime safety

- Never remove an AppKit event monitor synchronously from inside its own callback; defer teardown until the callback has returned.
- A critical UI must not depend exclusively on ScreenCaptureKit output. The galaxy must retain a usable native fallback when capture is unavailable or returns no display content.
- A bundle-launch verification must confirm that the tested PID belongs to the newly built app rather than a stale instance. Terminate an existing process only as needed for the test and avoid discarding user state.
- Rendering callbacks should normally remain free of model mutations. If frame-driven state is required, keep ownership explicit and verify that it does not create update loops or unnecessary invalidation.
- Do not introduce potentially blocking database, AppleScript, or capture work on the main actor without measuring and justifying it. When an API requires the main thread, use a main-actor-aware entry point rather than an unconditional synchronous dispatch.

### User-facing behavior

- Every user-facing shortcut must be registered in `HelpShortcutCatalog` — customizable entries with their `KeyboardShortcuts.Name`, fixed keys as scenario lines. Voca Help renders the catalog, and a source-scan test fails when a `KeyboardShortcuts.Name` is added without a catalog entry, so Help covers all shortcuts by construction; never hand-write shortcut lines in `HelpContentView`.
- Saving remains silent apart from the bottom-right toast.
- Notes remain visually secondary and may span multiple lines.
- Markdown export contains entries and blockquoted notes separated by blank lines; it does not include URLs unless the user explicitly changes the format.

## Change discipline

- Make the smallest coherent change that satisfies the request.
- Do not refactor unrelated code or preserve an implementation solely because it appears in historical notes.
- When replacing a workaround, identify the behavior it protected and add or update a regression check where practical.
- Prefer `Logger`/`os_log` with deliberate privacy settings for durable diagnostics. Temporary file traces must be debug-only and removed before handoff unless the user asks to retain them.
- Read compiler and runtime errors before forming a theory. Validate assumptions against the current SDK and dependency versions.

Historical platform findings and the current galaxy implementation are references, not permanent mandates:

- [`docs/troubleshooting.md`](docs/troubleshooting.md)
- [`docs/galaxy-design.md`](docs/galaxy-design.md)

## Workflow contract

1. Implement → run `swift build` cleanly → run `./build.sh` → relaunch the newly built app → hand it to the user for testing.
2. **Never write `log.md` or `git-log.md`, and never create a Git commit, until the user has tested the change and explicitly asked.** Automated verification does not replace user acceptance.
3. For a requested commit, stage only project files, verify `git diff --cached --name-only` excludes local-only material, use an English Conventional Commit summary with mirrored English and Chinese description paragraphs (each 2–3 concise sentences), and report the commit hash.
4. External contributions are merged only with the contribution-license acknowledgment checked in the PR (see CONTRIBUTING.md); do not merge PRs lacking it.
