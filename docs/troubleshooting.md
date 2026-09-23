# Voca development troubleshooting

This document records observed platform failures and compatibility details. It is diagnostic context, not a prohibition against replacing the current implementation. When an implementation changes, preserve the affected behavior and update this document if the old finding no longer applies.

## Bundle resources and signing

KeyboardShortcuts uses package resources. A release bundle that omits its generated resource bundle may launch successfully and then fail when a `KeyboardShortcuts.Recorder` first renders. Verify dependency resources in `Voca.app/Contents/Resources` after changing packaging.

TCC permissions are sensitive to application identity and signing. A rebuilt or invalidly signed app can lose effective Accessibility, Automation, or Screen Recording access even while System Settings still appears enabled. `build.sh` currently prefers the `Voca Development` identity and falls back to ad-hoc signing. Always inspect signing verification before diagnosing capture code.

Sending Apple Events requires `NSAppleEventsUsageDescription` in the generated Info.plist. Automation authorization is granted per source/target pair.

Do not reset a working TCC grant merely to reproduce a prompt. Reset it only with the user’s explicit authorization and a concrete recovery plan.

## AppKit and SwiftUI windows

Removing an `NSEvent` monitor from within its active callback can release it mid-invocation. Defer window closure or monitor teardown until the callback has returned.

An `NSHostingController` may use the hosted SwiftUI view’s fitting size. A view without a useful intrinsic size can consequently collapse a window that was intended to fill the screen. The current galaxy uses an `NSHostingView` and reapplies the intended frame. Alternative window arrangements are valid if fullscreen sizing is verified.

SwiftUI rendering closures should generally be treated as rendering work rather than state-management entry points. Keep per-frame mutations explicit and watch for feedback loops or excessive invalidation.

## GRDB and SQLite migrations

Observed compatibility details for the current dependency and deployment targets:

- Use SQL for schema operations not exposed by the installed GRDB API.
- SQLite does not accept a non-constant default such as `CURRENT_TIMESTAMP` in every `ADD COLUMN` scenario. A safe migration can add a constant default and then backfill.
- GRDB column type and ordering APIs must match the installed major version.
- Migrations are transactional; a failed migration should roll back and run again after correction.

Do not interpret these observations as a requirement to keep synchronous database writes on the main actor. Measure new write paths, especially imports, migrations, and batch operations, and keep expensive work away from UI-critical execution.

## Selection capture

The current primary path uses the Accessibility API and rejects focused elements with the secure-text-field role. The copy fallback posts Command-C, waits for the pasteboard change count to advance, reads only the new value, and restores a pasteboard snapshot.

The clipboard watcher must ignore the simulated copy and its restoration. Any replacement capture mechanism must preserve secure-field exclusion, stale-pasteboard protection, and clipboard restoration.

When bridging Core Foundation types, validate the runtime type identifier before using an unsafe cast. Do not rely on a conditional cast that the compiler considers unconditional.

## Clipboard monitoring

The current watcher polls `NSPasteboard.changeCount`; macOS does not provide an equivalent pasteboard-change notification covering all copy mechanisms. Event taps alone miss operations such as contextual-menu copies and add permission requirements. A different monitoring design is acceptable if it demonstrates equivalent coverage and comparable cost.

Entries marked with `org.nspasteboard.ConcealedType` are treated as sensitive and skipped. Text history persists with its configured limit; image and file handling may use different lifetimes.

## Browser context

The current implementation queries supported browsers through AppleScript. Safari and Chromium-family browsers expose different script interfaces, while unsupported browsers degrade to application-name context without a URL.

AppleScript execution must respect AppKit/Foundation threading requirements. Prefer an explicit main-actor boundary and avoid `DispatchQueue.main.sync` from a path that might already be on the main thread. Log failures without turning URL lookup into a capture failure.

## Stale processes

`open build/Voca.app` may activate an existing Voca process instead of starting the newly built executable, and arguments may then be ignored. For integration testing:

1. Identify the existing Voca PID, if any.
2. Close it safely when a clean launch is required.
3. Launch with `open -n` when testing launch arguments.
4. Confirm that the new PID and executable correspond to the rebuilt bundle.

Do not terminate a process blindly when it may contain user state.

## Logging

Unified logging can redact dynamic values depending on API and privacy annotations. Use `Logger` or `os_log` with intentional public/private interpolation rather than assuming an absent message means a path did not execute.

For short-lived diagnostics, a debug-only trace file can be useful, but it must not become an unconditional product side effect. Remove temporary instrumentation before handoff unless the user explicitly requests it.

## ScreenCaptureKit

A nominal Screen Recording grant does not guarantee that ScreenCaptureKit will return usable display content for every launch identity. Bundle-launched and terminal-launched processes can also have different effective TCC contexts.

Treat missing displays or frames as a recoverable condition. Critical visuals must remain available through native rendering, and diagnostics should distinguish permission state, content discovery, stream startup, and frame delivery.
