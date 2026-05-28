# Contributing

Patches welcome. The core is intentionally simple: a bash script and a Python tray app, no build step.

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
- Target Bash 4.3+ (`local -n` is required), avoiding 5-only builtins
- Don't break keyboard navigation in the TUI
- Run `shellcheck phpvm.sh` before opening a PR and fix everything it flags
- Plain ASCII punctuation in code, comments, prose, and CLI output: no em dashes, en dashes, or Unicode ellipses. Use commas, colons, periods, parentheses, or `...`. Unicode arrows (`→`) are house style and stay

## Tests

Two suites live under `tests/`. Both are plain bash, no fixtures or framework. Run them before opening a PR:

```bash
bash tests/test_cli.sh       # 35 checks against phpvm.sh + hook: --version, --list, --auto, sh-shell, shim, hook PATH order
bash tests/test_gui.sh       # 5 checks against phpvm-gui.py: gi / GTK / AppIndicator imports + syntax + xvfb smoke
```

Cross-distro compat (Ubuntu 20.04 / 22.04 / 24.04) runs in Docker:

```bash
bash tests/local-compat.sh           # all three
bash tests/local-compat.sh 22.04     # one
```

CI runs the same two suites across the three Ubuntu versions via `.github/workflows/compat.yml` on every PR that touches `phpvm.sh`, `phpvm-gui.py`, `install.sh`, `uninstall.sh`, `shell/`, or `tests/`. Keep them green.

### Hook changes must add or update a hook test

Any change to `shell/php-auto.bash`, `shell/php-auto.zsh`, `shell/php-auto.fish`, or `shell/shim-php` must include a corresponding test in `tests/test_cli.sh` that **sources the hook** (do not just lint or grep it) and asserts the behavior end to end. Cover both the success path and a hostile environment that exercises the change. For PATH-touching changes, that means at minimum:

- assert `/etc/phpvm/shims` (or the per-test hook dir) ends up at PATH position 0, not just "somewhere in PATH",
- pre-populate PATH with an entry that would shadow the shim (e.g. `/bin:` first) and confirm the hook still wins,
- source the hook two or three times back-to-back and confirm the shim entry appears exactly once (idempotence).

This rule exists because v2.5.1 shipped a hook regression that passed all 33 existing tests: the hook was never sourced under test, the shim binary was tested in isolation, and the bug only manifested when an environmental actor (PAM, snap profile.d, IDE) prepended to PATH after the hook ran. A naive "did the hook add the shim?" test would have passed against the broken code.

## Changelog

The repo follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Add an entry under `## [Unreleased]` in `CHANGELOG.md` for any user-visible change (new flag, fixed bug, changed behavior, removed feature). Internal refactors and pure doc tweaks don't need one.

## Reporting bugs

Open an issue and include:
- OS and bash version (`bash --version`)
- Your registered PHP versions (`update-alternatives --list php`)
- Output of `phpvm --doctor` if relevant (it covers CLI install, runtimes, FPM, sudo, hook, shim, GUI, and project state)
- What you expected vs. what happened
- Terminal emulator (some TUI rendering quirks are terminal-specific)

## Pull requests

1. Fork and branch off `main`
2. Make your change, run `shellcheck phpvm.sh` and both test suites
3. Add a `CHANGELOG.md` entry under `[Unreleased]` if the change is user-visible
4. Open a PR with a short description of what and why
