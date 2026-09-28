# Voca — a local-first text library for macOS

English · [Simplified Chinese](README.zh-CN.md)

<p align='center'><img src='docs/pictures/voca-1.png' width=90%></p>

Voca is an open-source menu bar app that helps you collect and revisit text on your Mac. Save a selection without leaving the app you're using, look up words in a bundled dictionary, translate with macOS, and explore your library in a fullscreen timeline or word galaxy. A separate clipboard history keeps copied text and images within reach. Your collection stays in a local SQLite database.

<p align='center'><img src='docs/pictures/voca-2.png' width=90%></p>

## Download and install

Voca requires macOS 26 or later. Check [GitHub Releases](https://github.com/UNLINEARITY/Voca/releases) for an app download. If a DMG is available, open it and drag Voca into Applications; for a ZIP, extract `Voca.app` and move it there. Launch the installed app from Applications, not from a mounted DMG.

If macOS blocks an unnotarized download, try opening Voca and then choose **System Settings → Privacy & Security → Open Anyway**. Grant permissions to the installed app. Voca does not update itself automatically. Only the optional three-finger gesture requires an Apple trackpad.

## First run

1. Open Voca and select text in Safari, Notes, or another app.
2. Press **⌥⇧S** to save it. When macOS requests Accessibility access, open **System Settings → Privacy & Security → Accessibility**, add the copy of `Voca.app` you opened (in Applications or `build/`), and enable it. The permission must be granted manually.
3. Select text again and press the shortcut. Voca saves silently and shows only a small confirmation toast at the bottom right; it never shows the selected text in the toast.

The app follows your macOS language preference by default: Simplified Chinese is supported, and English is the fallback. To override it, choose **Settings → General → Language → English / Simplified Chinese**; select **Follow system** to return to the macOS language. System permission dialogs and the macOS Services menu continue to follow macOS's own language setting.

## Everyday use

<p align='center'><img src='docs/pictures/voca-3.png' width=90%></p>

<p align='center'><img src='docs/pictures/voca-4.png' width=90%></p>

| Feature | How it works |
|---|---|
| Save selected text | Select text in any app and press **⌥⇧S** (customizable). Voca tries Accessibility first, then a temporary copy-and-restore fallback. Secure text fields are skipped. |
| Look up or translate | Select text and press **⌥⇧D**, or use the macOS text service **Look Up with Voca**. A cursor-side popup shows dictionary entries for words and supported phrases; unmatched text can use Apple's on-device English↔Chinese translation. The popup can save the selection and its translation as a note. |
| Open the workspace | Press **⌥⇧V** (customizable) or use the menu bar. The resizable Settings, Library, and Clipboard workspace remembers your last tab and opens on your current screen and desktop by default (configurable in Settings). |
| Browse the library | Add entries directly with the toolbar button or **⌘N**, search the full text, expand long entries, edit text or notes, copy, delete, or open a saved source URL. Saving identical text again merges it, increments its count, and adds an event to its timeline. |
| Clipboard history | When enabled, copied text and images appear in a separate history. Files appear for the current session only. Click **+** on a text entry to add it to the library; history is never silently merged into the library. |
| Word galaxy and timeline | Open the fullscreen view from the menu bar or workspace. Browse library and clipboard text on a rotatable sphere — library words grow with their save count — or explore saved entries on a time-mapped wall. Open item details or return to the workspace; the sphere remains usable without screen capture. |
| Optional three-finger gesture | Enable the experimental gesture in the menu bar or Settings, then swipe down with three fingers on an Apple trackpad to save selected text. The keyboard shortcut remains available. |

Double-clicking a word or phrase in a library list or galaxy opens a read-only lookup popup. The embedded English→Chinese dictionary includes pronunciation, learning annotations, word families, related phrases, and synonyms where available; British and American speech buttons use system voices. Popup width, reading area height, and text sizes can be adjusted in Settings. The lookup language pair is English↔Chinese; the app's display language does not change the dictionary's underlying content. When Settings → Dictionary → Speak after lookup is on, opening a dictionary card speaks the word automatically, British first and then American.

### Navigation and shortcuts

- **⇧⌥← / ⇧⌥→**: cycle workspace tabs or galaxy modes when an editor or dialog is not handling the keys.
- **⇧⌥↓**: enter the galaxy for the current tab. **⇧⌥↑**: return to its workspace tab.
- **⌥⇧G**: toggle Galaxy Settings when the galaxy is focused (customizable in Settings or the menu bar panel).
- **Esc**: close the lookup popup or leave the galaxy.
- The three global shortcuts (save, lookup, workspace) can be changed in the menu bar or Settings.

All single-entry and clear-library/history actions require a scope-specific confirmation. Markdown export writes entries in recency order, with notes as blockquotes separated by blank lines; it does not export source URLs.

## Permissions and privacy

- **Accessibility** is required to read selected text and to use the copy fallback. Voca does not read secure text fields. The fallback accepts clipboard contents only after a pasteboard change and restores the prior contents; simulated copies do not enter history.
- **Automation (Apple Events)** may be requested separately for Safari or a supported Chromium browser to read the current tab URL. If denied or unavailable, text is still saved without a URL. Firefox does not expose a supported tab URL path.
- **Screen Recording** may be requested for the galaxy's live desktop refraction. Captured frames are processed in memory and not saved. The galaxy still works when permission or display capture is unavailable.
- Clipboard monitoring is optional. Entries marked as concealed by a password manager are skipped. Voca-initiated copy-back does not re-enter history.
- Lookup uses a bundled, read-only dictionary; translation and speech use macOS system capabilities. Apple may prompt to download the language packs required for on-device translation. Voca does not require an account or cloud service.

The three-finger gesture is **off by default** and uses an undocumented macOS MultitouchSupport interface. It may stop working after a system update. If it conflicts with App Exposé, change that gesture in **System Settings → Trackpad → More Gestures**; Voca will not change your system settings.

## Your data

The library database is at `~/Library/Application Support/Voca/voca.sqlite`. Its saved-text library (`clips` and `clip_events`) is distinct from clipboard history (`clipboard_entries` and stored images). Text and image history persist without content-based merging or a retention cap; repeated copies within two seconds can be suppressed. The workspace initially loads a recent window. Copied files are session-only.

Use **Settings → Database → Back Up** for a safe, compact SQLite snapshot while Voca is running. You can also inspect the database with a SQLite client. For a full manual reset, quit Voca before deleting `~/Library/Application Support/Voca/` — this permanently removes your data.

The bundled English→Chinese dictionary is generated by `scripts/make_dictionary.py` from [ECDICT](https://github.com/skywind3000/ECDICT) (MIT; including its root data) and [Moby Thesaurus II](https://www.gutenberg.org/ebooks/3202) (public domain). It does not modify your library.

## Troubleshooting

| Problem | What to try |
|---|---|
| Nothing is saved | Check Accessibility access for the `Voca.app` you actually opened (in Applications or `build/`). Some apps do not expose a selection or permit a simulated copy. |
| The shortcut does nothing | Check for a conflict with another app and record a different shortcut in Settings. |
| A browser URL is missing | Allow Automation for that browser if prompted. Capturing the text itself does not depend on URL access. |
| The right-click lookup service is missing | Enable Voca under **System Settings → Keyboard → Keyboard Shortcuts → Services → Text**. Some Electron apps do not show the Services submenu; use **⌥⇧D** instead. |
| The trackpad swipe is unavailable | Enable the experimental setting, check that the trackpad is connected, and check for an App Exposé conflict. Use **⌥⇧S** as a fallback. |
| The galaxy has no desktop refraction | Check Screen Recording permission. The native galaxy remains usable without it. |
| Voca does not start at login | Add `Voca.app` in **System Settings → General → Login Items**. |

## Contributing

Contributions are welcome — submitting a PR means agreeing to the contribution license terms in [CONTRIBUTING.md](CONTRIBUTING.md).

## Development and license

To build from source, use a Swift toolchain that supports Swift 5.9 packages:

```bash
swift build          # Development build
swift test           # Run tests
./build.sh           # Signed release bundle at build/Voca.app
open build/Voca.app  # Launch the locally built app
```

The build script packages the dictionary and dependency resources, signs the app (using a local development identity when available, otherwise ad-hoc), and verifies the signature. An ad-hoc signature may not preserve previously granted macOS privacy permissions across builds.

The Swift package uses [GRDB](https://github.com/groue/GRDB.swift) for SQLite and [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) for configurable global shortcuts (both MIT-licensed). New source files must retain the project's AGPL header. See [AGENTS.md](AGENTS.md) for contribution and safety requirements.

Voca is licensed under [AGPL-3.0-or-later](LICENSE). © 2026 [UNLINEARITY](https://github.com/UNLINEARITY) · [unlinearity@gmail.com](mailto:unlinearity@gmail.com).
