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
| `Sources/Voca/GalaxyView.swift` | Galaxy model, window, rendering, interaction |
| `Sources/Voca/DictionaryService.swift` | Embedded read-only ECDICT lookup, word detection, display formatting |
| `Sources/Voca/DictionaryCardView.swift` | Dictionary card in the edit sheet (phonetics, senses, tags, speak buttons) |
| `Sources/Voca/SpeechService.swift` | Offline system TTS with per-accent best-voice selection |
| `Sources/Voca/TranslationService.swift` | Apple on-device translation wrapper (en↔zh) and translator view |
| `Sources/Voca/LookupPopupController.swift` | Cursor-side lookup/translation popup, service receiver, placement |
| `scripts/make_dictionary.py` | Generates the embedded dictionary.sqlite from the ECDICT CSV |
| `build.sh` | Release bundle assembly, resources, signing, verification |

Treat this map as navigation, not as an architectural boundary. Update it when responsibilities move.

## Required behavior and safety invariants

### Packaging and permissions

- The runnable app bundle must include dependency resource bundles required at runtime, including KeyboardShortcuts localization resources.
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
3. For a requested commit, stage only project files, verify `git diff --cached --name-only` excludes local-only material, use an English Conventional Commit summary with mirrored English and Chinese description paragraphs, and report the commit hash.
