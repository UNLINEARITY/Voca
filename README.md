# Voca — save selected text on macOS

[English](README.md) · [简体中文](README.zh-CN.md)

Voca is an open-source, local-first macOS menu bar app for saving selected text. Select text in another app, press a shortcut, and Voca quietly adds it to your library. Look up words, translate phrases, revisit what you saved in a fullscreen word galaxy, or keep a separate clipboard history. Your library stays on your Mac in SQLite.

## Requirements and build

- macOS 26 or later; a Mac with a trackpad is needed only for the optional gesture.
- Swift toolchain capable of building the Swift 5.9 package.

```bash
swift build          # Development build
./build.sh           # Release build, signed app bundle at build/Voca.app
open build/Voca.app  # Launch the menu bar app
```

The build script packages the embedded dictionary and dependency resources, signs the app (using the local “Voca Development” identity when available, otherwise ad-hoc), and verifies the signature. An ad-hoc signature may not preserve previously granted macOS privacy permissions across builds. The app currently has no installer or automatic updater.

## First run

1. Open Voca and select text in Safari, Notes, or another app.
2. Press **⌥⇧S** to save it. When macOS requests Accessibility access, open **System Settings → Privacy & Security → Accessibility**, add `build/Voca.app`, and enable it. The permission must be granted manually.
3. Select text again and press the shortcut. Voca saves silently and shows only a small confirmation toast at the bottom right; it never shows the selected text in the toast.

The app follows your macOS language preference by default: Simplified Chinese is supported, and English is the fallback. To override it, choose **Settings → General → Language → English / Simplified Chinese**; select **Follow system** to return to the macOS language. System permission dialogs and the macOS Services menu continue to follow macOS's own language setting.

## Everyday use

| Feature | How it works |
|---|---|
| Save selected text | Select text in any app and press **⌥⇧S** (customizable). Voca tries Accessibility first, then a temporary copy-and-restore fallback. Secure text fields are skipped. |
| Look up or translate | Select text and press **⌥⇧D**, or use the macOS text service **Look Up with Voca**. A cursor-side popup shows dictionary entries for words and supported phrases; unmatched text can use Apple's on-device English↔Chinese translation. The popup can save the selection and its translation as a note. |
| Open the workspace | Press **⌥⇧V** (customizable) or use the menu bar. The resizable workspace has Settings, Library, and Clipboard tabs, remembers the last tab, and by default reappears on the desktop and screen you are currently using instead of pulling you back to where it was last shown (configurable in Settings). |
| Browse the library | Search the full text, expand long entries, edit text or notes, copy, delete, or open a saved source URL. Saving identical text again merges it, increments its count, and adds an event to its timeline. |
| Clipboard history | When enabled, copied text and images appear in a separate history. Files appear for the current session only. Click **+** on a text entry to add it to the library; history is never silently merged into the library. |
| Word galaxy | Open the fullscreen galaxy from the menu bar or workspace. Explore library, clipboard text, or search results; rotate the sphere, open item details, and return to the workspace. A native fallback remains usable without screen capture. |
| Optional three-finger gesture | Enable the experimental gesture in the menu bar or Settings, then swipe down with three fingers on an Apple trackpad to save selected text. The keyboard shortcut remains available. |

Double-clicking a word or phrase in a library list or galaxy opens a read-only lookup popup. The embedded English→Chinese dictionary includes pronunciation, learning annotations, word families, related phrases, and synonyms where available; British and American speech buttons use system voices. Popup width, reading area height, and text sizes can be adjusted in Settings. The lookup language pair is English↔Chinese; the app's display language does not change the dictionary's underlying content.

### Navigation and shortcuts

- **⇧⌥← / ⇧⌥→**: cycle workspace tabs or galaxy modes when an editor or dialog is not handling the keys.
- **⇧⌥↓**: enter the galaxy for the current tab. **⇧⌥↑**: return to its workspace tab.
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

The library database is at `~/Library/Application Support/Voca/voca.sqlite`. Its saved-text library (`clips` and `clip_events`) is distinct from clipboard history (`clipboard_entries` and stored images). Text and image history are persisted without automatic deduplication or a retention cap; the workspace initially loads a recent window. Copied files are session-only.

Use **Settings → Database → Back Up** for a safe, compact SQLite snapshot while Voca is running. You can also inspect the database with a SQLite client. For a full manual reset, quit Voca before deleting `~/Library/Application Support/Voca/` — this permanently removes your data.

The bundled English→Chinese dictionary is generated by `scripts/make_dictionary.py` from [ECDICT](https://github.com/skywind3000/ECDICT) (MIT; including its root data) and [Moby Thesaurus II](https://www.gutenberg.org/ebooks/3202) (public domain). It does not modify your library.

## Troubleshooting

| Problem | What to try |
|---|---|
| Nothing is saved | Check Accessibility access for the **newly built** `Voca.app`. Some apps do not expose a selection or permit a simulated copy. |
| The shortcut does nothing | Check for a conflict with another app and record a different shortcut in Settings. |
| A browser URL is missing | Allow Automation for that browser if prompted. Capturing the text itself does not depend on URL access. |
| The right-click lookup service is missing | Enable Voca under **System Settings → Keyboard → Keyboard Shortcuts → Services → Text**. Some Electron apps do not show the Services submenu; use **⌥⇧D** instead. |
| The trackpad swipe is unavailable | Enable the experimental setting, check that the trackpad is connected, and check for an App Exposé conflict. Use **⌥⇧S** as a fallback. |
| The galaxy has no desktop refraction | Check Screen Recording permission. The native galaxy remains usable without it. |
| Voca does not start at login | Add `Voca.app` in **System Settings → General → Login Items**. |

## Development and license

```bash
swift build
swift test
./build.sh
```

The Swift package uses [GRDB](https://github.com/groue/GRDB.swift) for SQLite and [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) for configurable global shortcuts (both MIT-licensed). New source files must retain the project's AGPL header. See [AGENTS.md](AGENTS.md) for contribution and safety requirements.

Voca is licensed under [AGPL-3.0-or-later](LICENSE). © 2026 [UNLINEARITY](https://github.com/UNLINEARITY).
