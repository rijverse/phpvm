# Changelog

All notable changes to phpvm. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
is [SemVer](https://semver.org/).

## [2.3.1] - 2026-05-20

### Added

- One-line remote installer — `install.sh` now self-bootstraps. When invoked without sibling repo files (e.g.
  `curl -fsSL …/install.sh | sudo bash`), it git-clones the repo into a `mktemp -d`, retargets `SCRIPT_DIR` at the
  clone, and continues in the same process so the EXIT trap removes the tmp dir on exit (no `exec`, no orphaned clone).
  `PHPVM_REMOTE` and `PHPVM_REF` env vars override the default repo URL and ref (`main`); falls back to a default-branch
  clone + `git fetch origin <ref> && checkout FETCH_HEAD` when `--branch <ref>` doesn't match a branch (so tags/SHAs
  work). Hard-fails with a clear message when `git` is missing.
- `phpvm --doctor` — full diagnostic that checks CLI install, PHP runtimes, composer, PHP-FPM units, sudoers rule, shell
  hook wiring, GUI/tray deps (python3-gi / GTK 3 / Ayatana or legacy AppIndicator3 / icon / `.desktop` entry /
  autostart / running process), and project detection. Counts pass / warn / fail and exits non-zero on any fail.
- `install.sh` now offers to enable autostart on login. Writes `~/.config/autostart/phpvm-gui.desktop` and, under sudo,
  drops it into the invoking user's `$HOME` (resolved via `getent passwd`) with correct ownership. Upgrade mode
  refreshes the file in place if it already exists.
- CI compatibility matrix (`.github/workflows/compat.yml`) — CLI and GUI jobs build on `ubuntu:20.04 / 22.04 / 24.04`
  containers. Runs shellcheck (`-S warning`), CLI smoke tests, and a GUI import + xvfb `--help` smoke test on every push
  and PR touching `phpvm.sh`, `phpvm-gui.py`, `install.sh`, `uninstall.sh`, `shell/**`, or `tests/**`.
- `tests/test_cli.sh`, `tests/test_gui.sh`, `tests/local-compat.sh` — smoke tests for CLI flags, GUI imports, and a
  Docker-driven local matrix runner.

### Changed

- README overhaul: centered logo + GUI screenshots (`assets/gui-window.png`, `assets/gui-tray-menu.png`,
  `assets/tui.png`), expanded `--doctor` row in the CLI table, new `--auto --print [dir]` row, "Things it won't do"
  limitations section, and explicit `Bash 4.3+` requirement (badge + "What you need").
- Installer + GUI visual presentation polished — new box-drawing styles, clearer status labels in the GTK window,
  refactored icon-install feedback. **Restart FPM** button now sits to the left of **Switch** in the row so the
  destructive-looking action isn't the primary target.
- `install.sh` autostart heredoc deduplicated into a single `AUTOSTART_CONTENT` template; the root and non-root branches
  differ only by the write wrapper (`tee` under `sudo -u` vs plain redirect).
- `shell/php-auto.zsh` and `shell/php-auto.fish` headers now document both `/etc/phpvm/` (system) and `~/.phpvm/` (user)
  install paths, matching the bash hook.
- `phpvm-gui.py` docstring clarifies that **Ayatana** AppIndicator3 is preferred and legacy AppIndicator3 is accepted as
  a fallback.
- `tests/local-compat.sh` aligned with CI — Ubuntu 18.04 dropped from the local matrix (CI never tested it; README only
  claims 20/22/24).
- `CONTRIBUTING.md` — real repo URL, Bash target tightened to `4.3+` (`local -n` is required), matching `phpvm.sh`'s
  guard.
- `.github/workflows/release.yml` — every step now earns its keep. Added a repo-integrity pre-check that fails the tag
  if any shipped file is missing (including `assets/phpvm.svg`, which the installer needs but the previous workflow
  never verified). Added a `bash -n` syntax gate across `phpvm.sh`, `install.sh`, `uninstall.sh`, and
  `shell/php-auto.bash`. Every `run:` block now uses `set -euo pipefail` so the changelog `awk` pipeline (and friends)
  can't silently produce empty output. `actions/checkout` and `softprops/action-gh-release` are pinned to commit SHAs
  with version comments for supply-chain hardening. Dropped the `shellcheck … || true` step (lint that always passes is
  theater — lint lives in `compat.yml` now). Dropped the `files:` upload list and `fetch-depth: 0` — the installer and
  `phpvm --self-update` both bootstrap via `git clone`, never via release artifacts, so the per-file uploads were
  decorative; GitHub's auto-attached source tarball still covers the "I want a versioned download" case.
- `.github/workflows/compat.yml` — `shellcheck` is now a real gate. Removed the `|| true` that silently swallowed every
  warning, hoisted lint into a dedicated `lint` job so it runs once instead of three times per matrix OS, and expanded
  the lint scope to include `tests/test_cli.sh` and `tests/test_gui.sh`. Split the GUI dependency install into a
  required step (python3, python3-gi, GTK 3, xvfb, libglib2.0-0 — fails fast) and an optional AppIndicator step (
  Ayatana → legacy → `::warning::`), removing the blanket `|| true` that was masking missing-python3 failures. Pinned
  `actions/checkout` to a commit SHA and added `set -euo pipefail` to every script block.

### Fixed

- `phpvm.sh` header comment said `v2.1.0` while `VERSION="2.2.0"` — header bumped to v2.2.0.
- `tests/test_cli.sh` was exercising non-existent subcommands (`list`, `current`, `use`) that the CLI never accepted;
  tests only passed because unknown commands return non-zero. Rewritten against the real flags (`--list`, `--current`,
  `--set`), with a regression test that asserts unknown positional `use` is rejected with `Unknown option`.
- `uninstall.sh` under `sudo` only cleaned the invoking user's autostart, desktop, and icon files — it left
  `~/.local/bin/phpvm{,-gui}`, the `~/.phpvm` hook directory, and the user's shell rc lines untouched. `SUDO_HOME` now
  propagates to `BIN_DIRS`, `HOOK_DIRS`, and the rc-cleanup loop.
- `set_project_tui` wrote `.php-version` without normalizing the version string or warning when an existing file held a
  different value — diverged from `cmd_set_project`. TUI now normalizes via `normalize_version` and prints an overwrite
  warning before the confirm prompt.
- README CLI table missed `phpvm --auto --print [dir]` and undersold `--doctor` ("install location, sudoers rule, and
  shell-hook setup") versus its actual scope.

---

## [2.2.0] - 2026-05-11

### Added

- `phpvm-gui` now falls back to `pkexec` (polkit graphical auth dialog) when passwordless sudo isn't configured.
  Switch / Restart FPM no longer silently no-op for users without the sudoers rule.
- Inline status label in the GTK window — switch and restart-fpm results render in the window itself (green/red),
  replacing the desktop-notification round-trip.
- `uninstall.sh` stops any running `phpvm-gui` (via `pkill -x`) before removing files. Avoids the "file in use" / stale
  tray icon after uninstall.
- GitHub Actions release workflow (`.github/workflows/release.yml`) for tag-triggered releases.

### Changed

- Sudo prompts everywhere now carry a labeled `-p` string (`[phpvm] switching PHP — password for %u:`,
  `[phpvm] restarting phpX.Y-fpm — password for %u:`) so users see who's asking when no nopasswd rule is set.
- Removed `sudo -n` quiet path and the rc=77 "password required" signaling from `do_switch` + `cmd_auto`. Shell-hook
  auto-switch is now plain `sudo` — passwordless if sudoers is configured, interactive prompt otherwise. Net: 60+ lines
  deleted from `phpvm.sh` and `phpvm-gui.py`.
- `cmd_auto` quiet mode prints terse stdout (`phpvm: switched to PHP X.Y`) instead of dispatching `notify-send`. GUI
  handles its own notifications via the inline status label.

---

## [2.1.0] - 2026-05-11

### Added

- `phpvm --auto --print [dir]` — print resolved project PHP version without switching. Used by `phpvm-gui` so the GUI
  and CLI share one constraint solver.
- `phpvm-gui --foreground` / `-F` — keep the GUI attached to the terminal (errors visible, useful for debugging).
- `phpvm-gui` now double-forks on launch so the calling shell returns immediately and the GUI survives terminal close.
  `.desktop` launchers and `phpvm --window` benefit too.

### Changed

- Auto-switch from shell hooks (`phpvm --auto --quiet`) now uses `sudo -n`. Without the nopasswd rule the hook no longer
  hangs on a silent password prompt — it sends a labeled desktop notification telling you what's asking and how to fix
  it.
- `do_switch` failures return rc=77 when password is required; cmd_auto branches on this to show a contextual
  notification instead of a generic "failed to switch".
- Sudoers glob tightened from `/usr/bin/php*` to `/usr/bin/php[0-9].[0-9]` — the old glob also matched `phpunit`,
  `php-config`, etc.
- `install.sh --upgrade` detects the old `php*` glob and rewrites the sudoers file to the tighter pattern.
- `phpvm-gui` REFRESH_MS bumped 5s → 15s and per-version SAPI/xdebug/ini lookups are now memoized per session (cleared
  on switch). Was forking PHP for every installed version every 5 seconds.
- `phpvm-gui` composer detection now shells out to `phpvm --auto --print` first so behavior matches the shell side
  exactly (supports `^`, `~`, ranges, `|`).
- `install.sh` no longer prompts when stdin isn't a tty (defaults to CLI+GUI, skips sudoers/hook prompts) — works under
  `curl … | sudo bash`.
- `uninstall.sh` cleans both `/usr/local/bin`/`/etc/phpvm` AND `~/.local/bin`/`~/.phpvm` instead of either/or.
- `install.sh` rewrites `git@host:owner/repo` remote URLs to `https://host/owner/repo` when recording REPO_URL, so
  `phpvm --self-update` works without an ssh-agent.

### Fixed

- `do_switch` no longer swallows `update-alternatives` stderr — failure messages reach the user.
- `.php-version` parsing now normalizes `php8.2`, `8.2.0`, leading/trailing whitespace to `X.Y`. Was a silent miss
  before.
- `phpvm --set-project` validates input and prompts before overwriting an existing `.php-version` with a different
  value.
- `phpvm --window` pre-checks for python3-gi/GTK3 and reports the install command instead of silently failing.
- Tray indicator guide string `"PHP 8.88"` → `"PHP 99.99"` so labels don't truncate on PHP 10.x or 8.10+.

### Security

- Sudoers glob tightening (see Changed) closes the case where the old `php*` rule could authorize unrelated
  `php-config` / `phpunit` binaries if they ever shipped at `/usr/bin/php…`.

---

## [2.0.0] - 2026-05-07

Initial public release.

- Interactive TUI version picker.
- System tray GUI (`phpvm-gui`) with SAPI / xdebug / FPM / EOL badges.
- Detached GTK picker window (`phpvm --window`).
- Per-project PHP via `.php-version` or `composer.json`.
- Auto-switch shell hooks for bash, zsh, fish.
- Passwordless sudo opt-in via installer.
- `phpvm --self-update`.
