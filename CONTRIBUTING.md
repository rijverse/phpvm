# Contributing

Patches welcome. The core is intentionally simple — a bash script and a Python tray app, no build step.

## Setup

```bash
git clone https://github.com/rijverse/phpvm.git
cd phpvm
```

Run directly while developing:

```bash
bash phpvm.sh
./phpvm-gui.py
```

## A few ground rules

- Keep `phpvm.sh` self-contained. No dependencies beyond `update-alternatives` and standard bash tools
- Target Bash 4.3+ (`local -n` is required); avoid 5-only builtins
- Don't break keyboard navigation in the TUI
- Run `shellcheck phpvm.sh` before opening a PR and fix everything it flags

## Reporting bugs

Open an issue and include:
- OS and bash version (`bash --version`)
- Your registered PHP versions (`update-alternatives --list php`)
- What you expected vs. what happened
- Terminal emulator — some TUI rendering quirks are terminal-specific

## Pull requests

1. Fork and branch off `main`
2. Make your change, run shellcheck
3. Open a PR with a short description of what and why
