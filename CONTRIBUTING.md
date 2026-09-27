# Contributing to Voca

Thank you for your interest in improving Voca — a local-first, fully offline macOS menu bar app for saving and understanding text.

## How to contribute

1. Fork the repository and create a focused feature branch.
2. Make sure the quality gates pass locally (CI runs the same checks on your PR):

   ```bash
   swift build   # must compile with zero warnings
   swift test    # all tests must pass
   ```

3. Open a pull request against `main` and check the boxes in the PR template.

## License of contributions

> Submitting a pull request means you agree that your contribution joins this repository under AGPL-3.0-or-later **and** grants the maintainer a commercial re-license right over it (you keep your copyright). If you cannot agree, open an issue to discuss instead.

## Good first contributions

- Glossary additions: append rows to [`scripts/terms.csv`](scripts/terms.csv) (word, Chinese gloss, English gloss, tag) and run `python3 scripts/make_terms.py`.
- Bug reports with reproduction steps (macOS version, app version from Settings → About).
- Fixes and improvements for the library, clipboard history, dictionary card, timeline wall, or galaxy; corrections to the bundled English / Simplified Chinese strings.

Before touching capture, clipboard, or storage code, read the safety invariants in [AGENTS.md](AGENTS.md). New source files carry the standard AGPL header; local-only material (`log.md`, `git-log.md`, `research/`, `.vscode/`) never enters Git.
