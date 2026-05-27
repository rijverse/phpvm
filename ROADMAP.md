# phpvm Roadmap

Detailed companion to the Roadmap checklist in [README.md](README.md). Items are
in the same order as the README. The top two are fully specced; the rest are
idea-stage notes so the whole picture lives in one place.

## Status overview

- [x] **1. `phpvm install <ver>`** (shipped, v2.4.0)
- [ ] **2. Per-shell switching, as the new default** (planned, v2.5.0)
- [ ] **3. Extension manager** (idea)
- [ ] **4. `phpvm exec <ver> <cmd>`** (idea)
- [ ] **5. Shell completion** (idea)
- [ ] **6. `phpvm install --lts` alias** (deferred, needs an EOL table)

Sequencing: ship #1 first since it's small, independent and low risk, then #2
which is the bigger architectural change. They don't touch the same code paths,
so the order is flexible.

---

## 1. `phpvm install <ver>` (v2.4.0, shipped)

Drive the upstream PHP repos so users stop hand-running `apt install`. Independent
of the per-shell inversion, lower risk, roadmap priority #1. The spec below is what
shipped; `cmd_install` and its helpers (`detect_distro_repo`, `ensure_php_repo`,
`_assemble_packages`) live in `phpvm.sh`.

### Repo / distro detection

Reads `/etc/os-release`:

- Ubuntu (or `ID_LIKE` contains `ubuntu`): `ppa:ondrej/php` via
  `add-apt-repository`. Needs `software-properties-common` first.
- Debian: Surý repo. Keyring goes to `/etc/apt/keyrings/sury-php.gpg`, source list
  at `/etc/apt/sources.list.d/sury-php.list` pinned to `$VERSION_CODENAME`.
- Anything else (Arch/Fedora/etc.): clean error, consistent with the "only
  `update-alternatives` distros" stance.

### Flow for `phpvm install 8.3`

1. Guard on `apt-get`. Reject patch-level args like `8.2.13` with the existing
   message style.
2. Idempotency. If `/usr/bin/php8.3` exists or it's already registered in
   `update-alternatives`, report and offer `phpvm shell` / `global`.
3. Assemble the package set. Default is `php8.3-cli php8.3-common php8.3-fpm`;
   `--minimal` drops fpm; `--with curl,mbstring,...` appends `php8.3-<ext>`.
4. Confirm interactively (repo-to-add plus packages), reading from `/dev/tty` like
   `install.sh` does. `--yes` skips for non-interactive.
5. Configure the repo only if `apt-cache show php8.3-cli` is empty, then
   `apt-get update`.
6. `sudo apt-get install -y <packages>`.
7. Defensive register. If `/usr/bin/php8.3` exists but isn't in
   `update-alternatives --list php`, register it (priority from the version, so
   `83`).
8. Offer to switch. `--use` auto-switches.
9. `--print` / dry-run: emit the repo and package list it would act on, without
   touching the system. Doubles as the CI-safe test path.

### Notes

- `apt` stays password-gated. The narrow `NOPASSWD` sudoers rule is scoped to
  `update-alternatives --set` only and must not absorb install.
- Version resolution supports explicit `X.Y` plus `latest` (cheap via `apt-cache`
  once the repo is configured). `--lts` is deferred, see item 6.

### Files touched

- `phpvm.sh`: `cmd_install` plus helpers (`detect_distro_repo`, `ensure_php_repo`,
  `resolve_install_target`), dispatch case, help text, version bump.
- `README.md`: move "Installing PHP itself" out of Current limits into a
  documented section, update the command table, tick the roadmap box.
- `CHANGELOG.md`: new entry.
- `tests/test_cli.sh`: no-arg usage error, unsupported-distro guard, and `--print`
  output assertions (no real apt).

---

## 2. Per-shell switching, as the new default (v2.5.0)

The architectural inversion. Gets its own release.

### Why invert the default

Today every switch is global via `update-alternatives --set php`, which moves
`/usr/bin/php` for the whole system and needs sudo. We're inverting this to match
how every modern version manager works:

- Per-shell switching becomes the default. Sudo-free, instant, and two terminals
  can run two PHP versions at once.
- Global switching becomes an explicit, optional command for system-wide and
  non-shell contexts (cron, systemd, other users, web/FPM).

This is non-breaking: `--set` and `--set-project` stay as aliases.

### Resolution model: three layers, two env vars

An explicit `phpvm shell` pin must be sticky, but the `cd`-hook's project
detection must be dynamic (re-evaluated every directory). Keep them distinct with
two variables, the same precedence order rbenv uses:

| Layer      | Source                                     | Var                   | Sticky?              |
|------------|--------------------------------------------|-----------------------|----------------------|
| shell      | `phpvm shell <v>`                          | `PHPVM_SHELL_VERSION` | yes, until `--unset` |
| local/auto | `.php-version` / `composer.json` (cd-hook) | `PHPVM_AUTO_VERSION`  | recomputed each `cd` |
| global     | `update-alternatives`                      | (system symlink)      | system-wide          |

The shim checks `PHPVM_SHELL_VERSION` first, then `PHPVM_AUTO_VERSION`, then falls
back to `/usr/bin/php`:

```sh
#!/bin/sh
v="${PHPVM_SHELL_VERSION:-$PHPVM_AUTO_VERSION}"
if [ -n "$v" ] && [ -x "/usr/bin/php$v" ]; then exec "/usr/bin/php$v" "$@"; fi
exec /usr/bin/php "$@"
```

This is what makes the everyday path sudo-free. The `cd`-hook stops calling
`update-alternatives` and instead just runs `export PHPVM_AUTO_VERSION=<v>` in
your shell (or unsets it when you leave a project). No password, no sudoers rule
for normal use.

### Command surface

| Verb                      | Scope            | Mechanism                   | sudo? |
|---------------------------|------------------|-----------------------------|-------|
| `phpvm shell <v>`         | current terminal | `PHPVM_SHELL_VERSION` env   | no    |
| `phpvm local <v>`         | this project     | writes `.php-version`       | no    |
| `phpvm global <v>`        | system default   | `update-alternatives`       | yes   |
| `phpvm --set <v>`         | alias for global | (kept for backwards-compat) | yes   |
| `phpvm --set-project <v>` | alias for local  | (kept for backwards-compat) | no    |

### Tradeoffs

1. Per-shell only works where the hook and shim are loaded. A shell pin is
   invisible to cron, systemd, other users, non-interactive shells, and the GUI.
   `global` remains the only thing that affects those contexts. The installer
   default-enables the hook to soften this.
2. The GUI is global by nature. A tray app isn't attached to a terminal, so it can
   only do global switches. The README's "panel and shell never disagree" promise
   gets reworded: the panel reflects the global default, and a shell may be pinned
   above it.
3. "What am I really on" has layers. `--current` and `--doctor` need to report the
   shell-pin, auto/local, and global separately, plus the effective one.

### Components

- Shim at `<HOOK_DIR>/shims/php` (see the resolution model above), with the shims
  dir prepended to PATH by the hook. Round 1 ships `php` only; `php-config`,
  `phpize` and `phar` are easy follow-ups.
- A `phpvm()` wrapper in `php-auto.{bash,zsh,fish}`. It routes `shell` through
  `eval "$(command phpvm sh-shell ...)"` and sends everything else straight to the
  binary. The hook also prepends the shims dir to PATH once, guarded against
  double-insert. fish gets its own function and `set -gx` syntax.
- cd-hook rewrite. `_php_switcher_auto` resolves via `phpvm --auto --print` and
  sets or unsets `PHPVM_AUTO_VERSION` locally. No subprocess switch, no sudo. It
  skips entirely when `PHPVM_SHELL_VERSION` is set, so an explicit pin wins.
- Binary verbs: `cmd_global` (today's `do_switch` / `--set`), `cmd_local` (today's
  `--set-project`), `cmd_sh_shell` (validates the version, emits
  `export PHPVM_SHELL_VERSION=<v>` or `echo '... not installed' >&2; false`), and
  `cmd_shell` (direct-invoke help via tty detection).
- TUI: Enter pins the shell, the new default. Implemented the fzf way: draw to
  `/dev/tty`, print only the `export ...` line to stdout, and let the wrapper run
  the bare TUI under `eval`. `g` does the global sudo switch inline
  (subprocess-safe), `p` writes `.php-version`. Without the wrapper (stdout is a
  tty), Enter falls back to global with a one-line note. This is the only part
  with real refactor risk, and the fallback keeps it safe.
- `--current` and `--doctor` report the shell-pin, auto/local, and global
  separately, plus the effective one. They read the exported vars fine as a
  subprocess.

### Direct-invocation fallback

If someone runs the real `phpvm shell 8.3` without the wrapper loaded, the binary
notices stdout is a tty (eval would have captured it) and prints "run
`phpvm --enable-hook`, or `eval \"$(phpvm sh-shell 8.3)\"`". Same trick the TUI
fallback uses.

### Installer / uninstaller / GUI

- `install.sh`: default-enable the hook (the default behavior now depends on it),
  install the shim (`chmod +x`), and downgrade the sudoers prompt to "only needed
  for `phpvm global`".
- `uninstall.sh`: shims live under `HOOK_DIR`, which is already `rm -rf`'d, and
  rc-line cleanup already strips the `source` line. Likely no change, but verify.
- GUI stays global. Relabel its action as "set system default" and reword the
  README "panel and shell never disagree" line.

### Files touched

- `phpvm.sh`: the verbs above, dispatch cases (`shell`, `sh-shell`, `local`,
  `global`), help text, doctor checks (shims dir present, on PATH, wrapper
  loaded), version bump.
- `shell/php-auto.{bash,zsh,fish}`: `phpvm()` wrapper, PATH-prepend, and the
  cd-hook rewrite to set/unset `PHPVM_AUTO_VERSION`.
- New `shell/shim-php` template, copied by `install.sh` to `<HOOK_DIR>/shims/php`.
- `README.md`: document per-shell switching, move it out of Current limits, update
  the table, tick the roadmap box, reframe the GUI.
- `CHANGELOG.md` plus `tests/test_cli.sh` (`sh-shell` emits the correct export and
  errors on a bad version, CI-safe and binary-level).

### Why this shape

The design is the rbenv / pyenv / asdf hybrid: a shim directory on `$PATH` plus a
thin `phpvm()` wrapper function that uses `eval` internally for the commands that
have to mutate the current shell. Rejected alternatives:

- Pure shell function (nvm-style). All logic lives in shell. Heavy, slow, hard to
  test. Nobody copies it anymore.
- User-facing `eval "$(phpvm shell 8.2)"`. People forget the `eval`, it silently
  no-ops, and the support burden lands in issues.

The hybrid keeps logic in the binary (one source of truth, testable), keeps the
shell function tiny, and follows a path three major version managers have already
validated.

---

## 3. Extension manager (idea)

`phpvm ext install xdebug redis imagick` per version, installing the matching
`php<ver>-<ext>` packages and wiring up the ini. None of the existing PHP version
managers do this well, so it could be a differentiator. Not specced yet.

---

## 4. `phpvm exec <ver> <cmd>` (idea)

Run a one-off in a specific version without switching, like `nvm exec`, e.g.
`phpvm exec 8.1 composer install`. Handy for CI and quick sanity checks. Should be
trivial once the shim exists, since it just sets `PHPVM_SHELL_VERSION` for a single
child process. Not specced yet.

---

## 5. Shell completion (idea)

bash/zsh/fish completion for `shell`, `global`, `install` and friends, so
`phpvm global <TAB>` lists installed versions and `phpvm install <TAB>` lists
available ones. Not specced yet.

---

## 6. `phpvm install --lts` alias (deferred)

Track the moving LTS target without remembering version numbers. Deferred because
it needs a maintained EOL/support table to know which minor counts as "LTS" at any
given time. `latest` ships with item 1; `--lts` waits until the install flow is
solid and we've decided how to source EOL data.
