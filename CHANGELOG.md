# Changelog

All notable changes to phpvm. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning
is [SemVer](https://semver.org/).

## [2.6.0] - 2026-05-28

### Added

- `phpvm which <version>` prints the absolute binary path (e.g. `/usr/bin/php8.2`) for one installed PHP version.
  Mirrors `nvm which` / `pyenv which` / `rbenv which` so scripts and IDE config tools can pipe the result straight
  into wherever an interpreter path is needed (PhpStorm CLI Interpreter, VS Code `php.validate.executablePath`,
  LSP-Intelephense `phpExecutablePath`, NetBeans interpreters, CI configs). Returns the bare path on stdout, nothing
  else, so it composes. Accepts both `8.2` and `php8.2`.
- `phpvm --list --paths` adds an absolute-path column next to each version, with the active marker preserved.
  Designed for visual IDE setup: one command lists every interpreter you can register and where it lives. Includes
  a dim footer pointing at the README's "Using with your IDE" section so the recipe is one prompt away.
- `phpvm --list --json` emits `[{"version":"8.2","path":"/usr/bin/php8.2","active":true}, ...]` on a single pass:
  dependency-free (no `jq` needed to produce), stable schema (`version` / `path` / `active`), one entry per
  installed PHP, valid JSON ready for tooling and shell-scripted pipelines
  (`jq -r '.[] | select(.active).path'`).
- `phpvm shell <ver>` and `phpvm shell --unset` now emit a confirmation line via stderr ("pinned this terminal to
  PHP 8.2." / "shell pin removed for this terminal."). Previously silent on success, which left users wondering
  whether anything happened. The line is emitted inside the eval'd snippet so it preserves "after the eval"
  ordering.
- Inactive-shim hint: when `phpvm shell <ver>` succeeds but the shim isn't on PATH in the caller's terminal
  (common scenario: terminal was opened before the hook landed), the eval'd snippet prints "shim not on PATH in
  this terminal, so php still resolves to `<bin>`." plus the exact `source` command to activate it. The same
  warning block shows up at the bottom of `phpvm --current` when a shell or project pin is set but `php` resolves
  to a non-shim binary, so the layer view explains the mismatch users were hitting.
- `tests/test_install.sh`: new behavioral suite (18 checks) for `install.sh` and `uninstall.sh`. Static guards
  against the sudo-`$HOME` regression class, behavioral install in a fake HOME (writes to the right rc, no
  leakage, idempotent on re-run, `--upgrade` restores a missing hook), uninstall round-trip (hook removed, backup
  left, hook dir cleared), and a static + runtime check on the zsh hook (no `BASH_SOURCE` / `PROMPT_COMMAND`,
  zsh-native chpwd handler, shim prepended, `phpvm()` defined). The runtime block auto-skips when zsh isn't
  installed. Wired into `tests/local-compat.sh` so the docker matrix (Ubuntu 20.04 / 22.04 / 24.04) runs it, zsh
  added to the apt install step.

### Fixed

- `install.sh` wrote the per-user rc + autostart files using `$HOME`, which under `sudo` points at `/root`. The
  shell hook line landed in root's bashrc (or got silently dropped when that file didn't exist), so users who
  ran `sudo ./install.sh` never got `source /etc/phpvm/php-auto.bash` in their own rc. `phpvm shell <ver>` then
  printed the "needs the shell wrapper" guidance every time. Resolved by resolving `USER_HOME` and `USER_SHELL`
  from `getent passwd "$CURRENT_USER"` when `EUID=0`, and writing the rc file via `sudo -u "$CURRENT_USER" tee -a`
  so ownership stays with the invoking user. Same treatment for fish's `~/.config/fish/` directory creation.
  Consolidated the duplicate `USER_HOME` resolution that the autostart block had been doing inline.
- `install.sh --upgrade` silently skipped the shell-hook block entirely. Users hit by the prior `$HOME` bug
  couldn't recover via `--upgrade` / `--self-update` and the hook stayed missing forever. Upgrade mode now writes
  the hook line when it's missing (no prompt, since upgrade implies "I want this installed").
- `shell/php-auto.zsh` was a copy of the bash hook and broken in zsh on two counts: `${BASH_SOURCE[0]}` is empty
  outside bash so `_PHPVM_HOOK_DIR` resolved to the current working directory instead of the hook's own location,
  and `PROMPT_COMMAND` doesn't exist in zsh so the cd auto-switch never fired. Rewrote using `${(%):-%x}` for the
  script-self path (zsh prompt-expansion `%x`) and `add-zsh-hook chpwd _php_switcher_auto` (with an array-append
  fallback for older zsh without the `add-zsh-hook` autoload). Idempotent on re-source: `add-zsh-hook -d chpwd`
  first strips the prior registration, and the fallback path uses an `${array[(r)pattern]}` check to skip
  duplicates.
- `uninstall.sh` aborted at the first `sudo rm` when sudo couldn't prompt (running under `set -e` without a
  controlling terminal, or with cached creds expired), leaving rc files unswept and `~/.phpvm` half-removed.
  Wrapped removals in a new `_rm_path` helper that tries `sudo -n` (non-interactive), falls back to a regular
  `sudo rm` with stderr suppressed, and warns + continues instead of failing the script. Result: a user without
  active sudo creds still gets a usable partial uninstall (their own files cleaned, system files left alone with
  a clear warning).

### Changed

- Internal cleanup: install.sh autostart block no longer duplicates the `USER_HOME` lookup, as both that block and
  the new shell-hook writer read from the single resolution near the top. No user-visible change.

### Docs

- README: new "Using with your IDE" section explaining why a GUI IDE doesn't pick up shell env vars, the three
  primitives phpvm exposes (`which`, `--list --paths`, `--list --json`), and copy-pasteable recipes for PhpStorm,
  VS Code (Intelephense / PHP Tools workspace settings), Sublime / Zed / Helix (LSP), NetBeans, and CI/`jq`.
  States the reasoning (forward-compat: paths instead of IDE config files) so contributors don't try to add a
  per-IDE config writer later. CLI table gains rows for `--list --paths`, `--list --json`, and `phpvm which`.
- `--doctor` sample output in README bumped to v2.6.0.

## [2.5.1] - 2026-05-28

### Added

- `install.sh` now launches `phpvm-gui` immediately after installation when the user selected GUI (options 2 or 3).
  Runs in the background with `nohup` + `disown` so the tray icon appears without the installer blocking. When run
  under `sudo`, the session env is mostly stripped, so the installer harvests the full set it needs (`DISPLAY`,
  `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`, `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`, `XDG_DATA_DIRS`,
  `XDG_CONFIG_DIRS`, `XAUTHORITY`, `DBUS_SESSION_BUS_ADDRESS`) from a user-owned graphical process via
  `/proc/<pid>/environ` and re-launches as the real user with `sudo -u env ...`. Without `XDG_RUNTIME_DIR` the
  AppIndicator backend can't render the label next to the tray icon, and a `gnome-terminal` later spawned from the
  tray menu (`Open Terminal UI`) can't reach its session bus, so all of those vars matter for the tray to be usable.
  Skipped silently in non-interactive mode (CI/scripts) or when `python3-gi` is absent.

### Fixed

- Shell hook only ensured the shim dir was *somewhere* in `PATH`, not first. On boxes where something prepends `/bin:`
  or `/usr/bin:` to `PATH` after the hook runs (login shells re-reading `/etc/environment`, snap `profile.d` scripts,
  IDE-injected environments), the shim got demoted and `php` resolved to `/usr/bin/php` (the global symlink), so
  `phpvm shell <ver>` set `PHPVM_SHELL_VERSION` correctly but had no effect on subsequent `php` calls. The hook now
  forces the shim to position 0 every time it is sourced, stripping any stale copies first so PATH does not grow on
  re-source. Applied to all three hooks (`php-auto.bash`, `php-auto.zsh`, `php-auto.fish`).
- Uninstaller failed to stop a running `phpvm-gui` because `pgrep/pkill -x phpvm-gui` matched on `comm`, which is
  `python3` (from the shebang), not `phpvm-gui`. The kill step was silently skipped, the binary got removed, and the
  Python process kept its tray indicator registered on D-Bus, so the icon stuck around after uninstall. Switched to
  `pgrep/pkill -f` with a tight cmdline pattern (`(^|[/ ])phpvm-gui( |$)` so it won't match unrelated processes that
  happen to mention the name), plus a short post-TERM wait and a SIGKILL fallback if the GTK loop ignores SIGTERM.

### Changed

- `install.sh` now prints a prominent warning at the end when it has just added the shell hook, telling the user that
  already-open terminals won't pick it up until they `source` their rc. New terminals work automatically. Replaces the
  easy-to-miss dim one-liner that fired regardless. The same gotcha is now documented in README's "Installing" section.
- Repo-wide typography sweep: removed all em dashes and Unicode ellipses from code, comments, prose, and CLI output
  (62 occurrences). Replaced with commas, colons, periods, or parens, and ellipses became ASCII `...`. Unicode
  arrows (`→`) kept as house style for status glyphs.

### Docs

- README: new `Installing` blockquote calling out the post-install `source ~/.bashrc` step for the terminal that ran
  the installer, plus a new collapsed `<details>` block with sample `phpvm --doctor` output showing what each
  subsystem check looks like on a healthy install. Documented `sudo bash install.sh --upgrade` / `-U` for local-clone
  upgrades (same path `--self-update` runs after it pulls).
- CONTRIBUTING: added the typography rule to ground rules, a Tests section listing `tests/test_cli.sh`,
  `tests/test_gui.sh`, and `tests/local-compat.sh`, a CI pointer at `.github/workflows/compat.yml`, and a Changelog
  section pointing PR authors at the `[Unreleased]` block.

---

## [2.5.0] - 2026-05-28

### Added

- Per-shell switching, now the default. `phpvm shell <ver>` switches PHP for the current terminal only, with no sudo,
  so two terminals can run two versions at once. It follows the rbenv / pyenv / asdf model: a `php` shim on `PATH`
  (installed to `<hook dir>/shims/php`) reads `PHPVM_SHELL_VERSION` and execs the matching `/usr/bin/phpX.Y`, falling
  back to the global symlink. `phpvm shell --unset` drops the pin.
- `phpvm local <ver>` and `phpvm global <ver>` as the project and system-wide verbs. `local` writes `.php-version`
  (no sudo), and `global` moves the `update-alternatives` symlink (sudo). The old `--set` and `--set-project` flags stay as
  aliases, so existing usage and scripts keep working.
- A `php` shim template (`shell/shim-php`) plus a `phpvm()` shell wrapper in each hook. The wrapper routes `shell` and
  the bare TUI through `eval` (fish uses `| source`) so they can change the current shell, while everything else calls the
  binary directly.
- Resolution is now three layers: shell pin (`PHPVM_SHELL_VERSION`), then project (`PHPVM_AUTO_VERSION`, set by the
  cd-hook from `.php-version` / `composer.json`), then the global symlink. An explicit shell pin always wins, so it is
  never overridden by a later `cd`.

### Changed

- The cd-hook no longer runs a sudo global switch. It now resolves the project version with `phpvm --auto --print` and
  exports `PHPVM_AUTO_VERSION` (or unsets it on leaving), which the shim reads. The everyday path is sudo-free.
- The TUI now pins the current shell on Enter when launched through the wrapper (drawing to the terminal while emitting
  the assignment on stdout, the way fzf does), with `g` for a global switch and `p` for the project. Run without the
  wrapper, Enter falls back to a global switch and notes how to enable per-shell pinning.
- `phpvm --current` reports the shell pin, project, and global layers separately, plus the effective version. `--doctor`
  gains a "Per-shell switching" section that checks the shim and whether the shim dir is on `PATH`.
- `install.sh` installs the shim, enables the shell hook by default (the everyday behavior depends on it), and reframes
  the sudoers prompt as needed only for `phpvm global`.
- The GUI is documented as global by nature: the tray reflects and sets the system default, and a shell pinned with
  `phpvm shell` can legitimately sit above it.

### Fixed

- `phpvm install` no longer risks hanging on an unattended `--yes` run. apt is now invoked as
  `sudo env DEBIAN_FRONTEND=noninteractive apt-get ...`, so a package postinst (e.g. tzdata) can't block on an
  interactive debconf prompt. `sudo` resets the environment, which is why the frontend is set through `env` rather than
  an inline assignment, and apt stays password-gated exactly as before.

---

## [2.4.0] - 2026-05-27

### Added

- `phpvm install <ver>` installs a PHP minor version from the upstream repo so you no longer hand-run `apt install`.
  Detects the distro from `/etc/os-release`: Ubuntu (and derivatives carrying `ubuntu` in `ID_LIKE`, e.g. Mint, Pop!_OS)
  use Ondřej Surý's `ppa:ondrej/php`, and Debian uses the deb.sury.org repo with a keyring under `/etc/apt/keyrings/sury-php.gpg`
  and a `[signed-by=...]` source list pinned to `$VERSION_CODENAME`. Other distros get a clean error. Default package set is
  `phpX.Y-cli phpX.Y-common phpX.Y-fpm`, where `--minimal` drops fpm and `--with curl,mbstring` appends `phpX.Y-<ext>`. Accepts
  explicit `X.Y` or `latest` (resolved via `apt-cache` once the repo is configured), and patch levels like `8.2.13` are rejected.
  Idempotent: reports and exits if the version is already present. After installing it defensively registers the `php`
  alternative if the package didn't, then offers to switch (`--use` auto-switches). `--print` is a dependency-free, CI-safe
  dry-run that prints the repo and package list without touching the system.
- `phpvm --help` documents the new `install` verb and its flags.

### Security

- `phpvm install` keeps `apt`/`add-apt-repository` under a normal password-gated `sudo`. The passwordless sudoers rule stays
  scoped to `update-alternatives --set` only, and install never widens it.

---

## [2.3.3] - 2026-05-27

### Changed

- Repository moved to `github.com/rijverse/phpvm` (previously `rijoanul-shanto/phpvm`). The `PHPVM_REMOTE` default in
  `install.sh` (used by the remote bootstrap clone and by the `--self-update` fallback when no URL was recorded at
  install time) now points at the new location, along with every repo link in `README.md`, `CONTRIBUTING.md`,
  `index.html`, and `social-preview.html`.

### Added

- Project landing page (`index.html`): a feature showcase of the taskbar indicator, tray menu, GUI window, and TUI
  picker, each with an annotated screenshot.
- Social preview: `social-preview.html` rendered to `assets/showcase/social-preview.png` (1280×640) for the GitHub repo
  preview, plus Open Graph / Twitter Card meta tags on the landing page and a `rijverse` workspace badge linking to the
  organization.

---

## [2.3.2] - 2026-05-20

### Fixed

- `install.sh` prompts were silently skipped under `curl ... | sudo bash` because piping replaces stdin with the pipe,
  making `[[ -t 0 ]]` return false even when a real terminal is attached. All interactivity checks now use
  `(true < /dev/tty) 2>/dev/null` to detect a controlling terminal instead of testing stdin, and all `read` calls
  redirect from `/dev/tty` directly. The one-line installer is now fully interactive, same prompts as running
  `bash install.sh` locally. Truly headless environments (CI, `nohup`, no controlling tty) still fall back to defaults.

### Changed

- README: corrected the installer interactivity note to reflect `/dev/tty`-based detection.
- README: added `## Uninstalling` section with a remote one-liner (`curl ... | sudo bash`), local clone form, itemized list of
  what gets removed (binaries, hook dir, sudoers rule, desktop/autostart entries, icons, shell RC lines), RC backup
  behaviour, and the sudo-user note.

---

## [2.3.1] - 2026-05-20

### Added

- One-line remote installer: `install.sh` now self-bootstraps. When invoked without sibling repo files (e.g.
  `curl -fsSL .../install.sh | sudo bash`), it git-clones the repo into a `mktemp -d`, retargets `SCRIPT_DIR` at the
  clone, and continues in the same process so the EXIT trap removes the tmp dir on exit (no `exec`, no orphaned clone).
  `PHPVM_REMOTE` and `PHPVM_REF` env vars override the default repo URL and ref (`main`), falling back to a default-branch
  clone + `git fetch origin <ref> && checkout FETCH_HEAD` when `--branch <ref>` doesn't match a branch (so tags/SHAs
  work). Hard-fails with a clear message when `git` is missing.
- `phpvm --doctor`: full diagnostic that checks CLI install, PHP runtimes, composer, PHP-FPM units, sudoers rule, shell
  hook wiring, GUI/tray deps (python3-gi / GTK 3 / Ayatana or legacy AppIndicator3 / icon / `.desktop` entry /
  autostart / running process), and project detection. Counts pass / warn / fail and exits non-zero on any fail.
- `install.sh` now offers to enable autostart on login. Writes `~/.config/autostart/phpvm-gui.desktop` and, under sudo,
  drops it into the invoking user's `$HOME` (resolved via `getent passwd`) with correct ownership. Upgrade mode
  refreshes the file in place if it already exists.
- CI compatibility matrix (`.github/workflows/compat.yml`): CLI and GUI jobs build on `ubuntu:20.04 / 22.04 / 24.04`
  containers. Runs shellcheck (`-S warning`), CLI smoke tests, and a GUI import + xvfb `--help` smoke test on every push
  and PR touching `phpvm.sh`, `phpvm-gui.py`, `install.sh`, `uninstall.sh`, `shell/**`, or `tests/**`.
- `tests/test_cli.sh`, `tests/test_gui.sh`, `tests/local-compat.sh`: smoke tests for CLI flags, GUI imports, and a
  Docker-driven local matrix runner.

### Changed

- README overhaul: centered logo + GUI screenshots (`assets/gui-window.png`, `assets/gui-tray-menu.png`,
  `assets/tui.png`), expanded `--doctor` row in the CLI table, new `--auto --print [dir]` row, "Things it won't do"
  limitations section, and explicit `Bash 4.3+` requirement (badge + "What you need").
- Installer + GUI visual presentation polished: new box-drawing styles, clearer status labels in the GTK window,
  refactored icon-install feedback. **Restart FPM** button now sits to the left of **Switch** in the row so the
  destructive-looking action isn't the primary target.
- `install.sh` autostart heredoc deduplicated into a single `AUTOSTART_CONTENT` template, with the root and non-root branches
  differ only by the write wrapper (`tee` under `sudo -u` vs plain redirect).
- `shell/php-auto.zsh` and `shell/php-auto.fish` headers now document both `/etc/phpvm/` (system) and `~/.phpvm/` (user)
  install paths, matching the bash hook.
- `phpvm-gui.py` docstring clarifies that **Ayatana** AppIndicator3 is preferred and legacy AppIndicator3 is accepted as
  a fallback.
- `tests/local-compat.sh` aligned with CI, where Ubuntu 18.04 was dropped from the local matrix (CI never tested it, and the README only
  claims 20/22/24).
- `CONTRIBUTING.md`: real repo URL, Bash target tightened to `4.3+` (`local -n` is required), matching `phpvm.sh`'s
  guard.
- `.github/workflows/release.yml`: every step now earns its keep. Added a repo-integrity pre-check that fails the tag
  if any shipped file is missing (including `assets/phpvm.svg`, which the installer needs but the previous workflow
  never verified). Added a `bash -n` syntax gate across `phpvm.sh`, `install.sh`, `uninstall.sh`, and
  `shell/php-auto.bash`. Every `run:` block now uses `set -euo pipefail` so the changelog `awk` pipeline (and friends)
  can't silently produce empty output. `actions/checkout` and `softprops/action-gh-release` are pinned to commit SHAs
  with version comments for supply-chain hardening. Dropped the `shellcheck ... || true` step (lint that always passes is
  theater, and lint lives in `compat.yml` now). Dropped the `files:` upload list and `fetch-depth: 0`, where the installer and
  `phpvm --self-update` both bootstrap via `git clone`, never via release artifacts, so the per-file uploads were
  decorative, and GitHub's auto-attached source tarball still covers the "I want a versioned download" case.
- `.github/workflows/compat.yml`: `shellcheck` is now a real gate. Removed the `|| true` that silently swallowed every
  warning, hoisted lint into a dedicated `lint` job so it runs once instead of three times per matrix OS, and expanded
  the lint scope to include `tests/test_cli.sh` and `tests/test_gui.sh`. Split the GUI dependency install into a
  required step (python3, python3-gi, GTK 3, xvfb, libglib2.0-0, fails fast) and an optional AppIndicator step (
  Ayatana → legacy → `::warning::`), removing the blanket `|| true` that was masking missing-python3 failures. Pinned
  `actions/checkout` to a commit SHA and added `set -euo pipefail` to every script block.

### Fixed

- `phpvm.sh` header comment said `v2.1.0` while `VERSION="2.2.0"`, and the header was bumped to v2.2.0.
- `tests/test_cli.sh` was exercising non-existent subcommands (`list`, `current`, `use`) that the CLI never accepted,
  tests only passed because unknown commands return non-zero. Rewritten against the real flags (`--list`, `--current`,
  `--set`), with a regression test that asserts unknown positional `use` is rejected with `Unknown option`.
- `uninstall.sh` under `sudo` only cleaned the invoking user's autostart, desktop, and icon files, leaving
  `~/.local/bin/phpvm{,-gui}`, the `~/.phpvm` hook directory, and the user's shell rc lines untouched. `SUDO_HOME` now
  propagates to `BIN_DIRS`, `HOOK_DIRS`, and the rc-cleanup loop.
- `set_project_tui` wrote `.php-version` without normalizing the version string or warning when an existing file held a
  different value, which diverged from `cmd_set_project`. TUI now normalizes via `normalize_version` and prints an overwrite
  warning before the confirm prompt.
- README CLI table missed `phpvm --auto --print [dir]` and undersold `--doctor` ("install location, sudoers rule, and
  shell-hook setup") versus its actual scope.

---

## [2.2.0] - 2026-05-11

### Added

- `phpvm-gui` now falls back to `pkexec` (polkit graphical auth dialog) when passwordless sudo isn't configured.
  Switch / Restart FPM no longer silently no-op for users without the sudoers rule.
- Inline status label in the GTK window: switch and restart-fpm results render in the window itself (green/red),
  replacing the desktop-notification round-trip.
- `uninstall.sh` stops any running `phpvm-gui` (via `pkill -x`) before removing files. Avoids the "file in use" / stale
  tray icon after uninstall.
- GitHub Actions release workflow (`.github/workflows/release.yml`) for tag-triggered releases.

### Changed

- Sudo prompts everywhere now carry a labeled `-p` string (`[phpvm] switching PHP, password for %u:`,
  `[phpvm] restarting phpX.Y-fpm, password for %u:`) so users see who's asking when no nopasswd rule is set.
- Removed `sudo -n` quiet path and the rc=77 "password required" signaling from `do_switch` + `cmd_auto`. Shell-hook
  auto-switch is now plain `sudo` (passwordless if sudoers is configured, interactive prompt otherwise). Net: 60+ lines
  deleted from `phpvm.sh` and `phpvm-gui.py`.
- `cmd_auto` quiet mode prints terse stdout (`phpvm: switched to PHP X.Y`) instead of dispatching `notify-send`. GUI
  handles its own notifications via the inline status label.

---

## [2.1.0] - 2026-05-11

### Added

- `phpvm --auto --print [dir]`: print resolved project PHP version without switching. Used by `phpvm-gui` so the GUI
  and CLI share one constraint solver.
- `phpvm-gui --foreground` / `-F`: keep the GUI attached to the terminal (errors visible, useful for debugging).
- `phpvm-gui` now double-forks on launch so the calling shell returns immediately and the GUI survives terminal close.
  `.desktop` launchers and `phpvm --window` benefit too.

### Changed

- Auto-switch from shell hooks (`phpvm --auto --quiet`) now uses `sudo -n`. Without the nopasswd rule the hook no longer
  hangs on a silent password prompt, sending a labeled desktop notification telling you what's asking and how to fix
  it.
- `do_switch` failures return rc=77 when password is required, and cmd_auto branches on this to show a contextual
  notification instead of a generic "failed to switch".
- Sudoers glob tightened from `/usr/bin/php*` to `/usr/bin/php[0-9].[0-9]`, as the old glob also matched `phpunit`,
  `php-config`, etc.
- `install.sh --upgrade` detects the old `php*` glob and rewrites the sudoers file to the tighter pattern.
- `phpvm-gui` REFRESH_MS bumped 5s → 15s and per-version SAPI/xdebug/ini lookups are now memoized per session (cleared
  on switch). Was forking PHP for every installed version every 5 seconds.
- `phpvm-gui` composer detection now shells out to `phpvm --auto --print` first so behavior matches the shell side
  exactly (supports `^`, `~`, ranges, `|`).
- `install.sh` no longer prompts when stdin isn't a tty (defaults to CLI+GUI, skips sudoers/hook prompts), working under
  `curl ... | sudo bash`.
- `uninstall.sh` cleans both `/usr/local/bin`/`/etc/phpvm` AND `~/.local/bin`/`~/.phpvm` instead of either/or.
- `install.sh` rewrites `git@host:owner/repo` remote URLs to `https://host/owner/repo` when recording REPO_URL, so
  `phpvm --self-update` works without an ssh-agent.

### Fixed

- `do_switch` no longer swallows `update-alternatives` stderr, allowing failure messages to reach the user.
- `.php-version` parsing now normalizes `php8.2`, `8.2.0`, leading/trailing whitespace to `X.Y`. Was a silent miss
  before.
- `phpvm --set-project` validates input and prompts before overwriting an existing `.php-version` with a different
  value.
- `phpvm --window` pre-checks for python3-gi/GTK3 and reports the install command instead of silently failing.
- Tray indicator guide string `"PHP 8.88"` → `"PHP 99.99"` so labels don't truncate on PHP 10.x or 8.10+.

### Security

- Sudoers glob tightening (see Changed) closes the case where the old `php*` rule could authorize unrelated
  `php-config` / `phpunit` binaries if they ever shipped at `/usr/bin/php...`.

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
