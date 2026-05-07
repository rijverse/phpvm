<div align="center">

# phpvm

**A fast PHP version switcher for Linux — TUI + system tray GUI.**

Drop a `.php-version` file in any project. `cd` in, the right PHP is already loaded.

![Bash](https://img.shields.io/badge/Bash-4%2B-1f425f?logo=gnubash&logoColor=white)
![Python](https://img.shields.io/badge/Python-3-3776ab?logo=python&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-update--alternatives-fcc624?logo=linux&logoColor=black)
![License](https://img.shields.io/badge/License-MIT-green)

</div>

---

```
┌─────────────────────────────────────────┐
│                  phpvm                  │
└─────────────────────────────────────────┘

  Active:  php8.2  (PHP 8.2.x)
  Project: 8.1

  ↑/↓  navigate   Enter  select   p  set-project   q  quit

  ────────────────────────────────────────

    php7.4
  ▌ php8.1                               ▐
    php8.2                                 ● active
    php8.3
```

---

## ✨ Features

| | |
|---|---|
| 🖥️ **Interactive TUI** | Arrow-key version picker right in your terminal |
| 🖼️ **System tray GUI** | One-click switching from your panel |
| 🪟 **Detached picker window** | Full GTK window with per-version SAPI / xdebug / FPM / EOL badges |
| 📁 **Per-project PHP** | `.php-version` or `composer.json` driven |
| ⚡ **Auto-switch on `cd`** | Bash / Zsh / Fish hooks, no manual `--set` |
| 🔇 **Silent operation** | Optional passwordless sudo for zero prompts |
| 🧹 **Clean uninstall** | Removes itself, backs up your shell rc |

---

## 🚀 Quick install

```bash
git clone https://github.com/YOUR_USERNAME/phpvm.git
cd phpvm && sudo bash install.sh
```

The installer asks: **CLI**, **GUI**, or **both** — and offers to wire up the shell hook and passwordless sudo.

> Removing it later: `sudo bash uninstall.sh`

### Upgrading

```bash
phpvm --self-update                              # uses repo URL captured at install
phpvm --self-update https://github.com/you/phpvm.git
phpvm --self-update https://github.com/you/phpvm.git v2.1.0   # specific tag/branch
```

Re-runs the installer in `--upgrade` mode: same install paths, same CLI/GUI choice, no re-prompting for sudoers or shell hooks. Falls back to a manual repo URL if the original one wasn't recorded (e.g. installed from a tarball).

### Requirements

- Linux with `update-alternatives` (Debian / Ubuntu)
- Bash 4+
- GUI extras: `python3-gi`, GTK3, AppIndicator3

---

## 💻 CLI

| Command | Action |
|---|---|
| `phpvm` | Open the interactive TUI |
| `phpvm --list` | Show all installed PHP versions |
| `phpvm --current` | Show what's active right now |
| `phpvm --set 8.2` | Switch globally to PHP 8.2 |
| `phpvm --auto` | Auto-switch from `.php-version` / `composer.json` |
| `phpvm --set-project 8.2` | Pin this directory to PHP 8.2 |
| `phpvm --enable-hook [shell]` | Add auto-switch hook to bash/zsh/fish |
| `phpvm --disable-hook [shell]` | Remove the hook (creates a backup) |
| `phpvm --window` | Launch a detached GTK picker window (frees the terminal) |
| `phpvm --self-update` | Pull latest from git and re-run installer non-interactively |
| `phpvm --help` | Full reference |

**TUI keys** &nbsp;&nbsp; <kbd>↑</kbd> <kbd>↓</kbd> / <kbd>k</kbd> <kbd>j</kbd> move &nbsp;·&nbsp; <kbd>Enter</kbd> switch &nbsp;·&nbsp; <kbd>p</kbd> pin &nbsp;·&nbsp; <kbd>q</kbd> quit

---

## 🖼️ Graphical UI

Two modes — both ship in the same `phpvm-gui` binary.

```bash
sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-ayatana-appindicator3-0.1

phpvm-gui              # tray applet (lives in your panel)
phpvm-gui --window     # detached GTK picker window (no tray)
phpvm --window         # same window, launched from the shell, frees the terminal
```

The **window mode** shows each version with live badges:

- 🟦 SAPIs available (`cli`, `fpm`, `apache2`)
- 🟧 `xdebug` enabled
- 🟩 / ⬜ `php-fpm` running / inactive
- 🟥 EOL versions (security-support ended)

Plus per-row actions: **Switch** to that version, **Restart FPM** for that version, project auto-detect, and a folder picker for one-off switches. Tooltip on each row shows the loaded `php.ini` path.

> **Restart FPM** needs a sudoers rule allowing `systemctl restart php*-fpm` without a password. Without it, the GUI notifies you and skips the action — switching itself is unaffected.

---

## 📁 Per-project PHP

```bash
echo "8.1" > .php-version
# or
phpvm --set-project 8.1
```

phpvm walks up the directory tree looking for `.php-version`. If it doesn't find one, it falls back to `require.php` in `composer.json` and picks the highest installed version that satisfies the constraint (`^`, `~`, `>=`, ranges, `|` — all supported).

---

## ⚙️ Shell hook (auto-switch on `cd`)

The easy way:

```bash
phpvm --enable-hook            # auto-detects $SHELL
phpvm --enable-hook zsh        # or be explicit
phpvm --disable-hook           # undo (rc backed up)
```

<details>
<summary><strong>Manual setup</strong></summary>

Pick the line for your install mode — `/etc/phpvm` for system installs, `~/.phpvm` for user installs:

```bash
# Bash
source /etc/phpvm/php-auto.bash      # or  ~/.phpvm/php-auto.bash

# Zsh
source /etc/phpvm/php-auto.zsh       # or  ~/.phpvm/php-auto.zsh

# Fish
source /etc/phpvm/php-auto.fish      # or  ~/.phpvm/php-auto.fish
```

</details>

---

## 🔇 Passwordless sudo

Every switch calls `sudo update-alternatives`. To skip the password prompt, drop a sudoers rule (the installer offers this):

```
# /etc/sudoers.d/phpvm
username ALL=(ALL) NOPASSWD: /usr/bin/update-alternatives --set php /usr/bin/php*
```

---

<details>
<summary><strong>📦 Registering PHP versions with update-alternatives</strong></summary>

If `phpvm` reports no versions, register them first:

```bash
sudo update-alternatives --install /usr/bin/php php /usr/bin/php8.3 83
sudo update-alternatives --install /usr/bin/php php /usr/bin/php8.2 82
sudo update-alternatives --install /usr/bin/php php /usr/bin/php8.1 81
```

</details>

<details>
<summary><strong>🗂️ Project layout</strong></summary>

```
phpvm/
├── phpvm.sh           CLI + TUI
├── phpvm-gui.py       system tray GUI
├── shell/
│   ├── php-auto.bash
│   ├── php-auto.zsh
│   └── php-auto.fish
├── install.sh
└── uninstall.sh
```

</details>

---

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Patches welcome — keep it dependency-free and `shellcheck`-clean.

## 📄 License

[MIT](LICENSE)
