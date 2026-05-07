# phpvm

TUI and system tray GUI for switching PHP versions on Linux. Drop a `.php-version` file in a project root and it switches automatically when you `cd` in.

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

## Requirements

- Linux with `update-alternatives` (Debian/Ubuntu, anything apt-based)
- Bash 4+
- GUI only: `python3-gi`, GTK3, AppIndicator3

## Install

```bash
git clone https://github.com/YOUR_USERNAME/phpvm.git
cd phpvm
sudo bash install.sh
```

The installer asks whether you want CLI, GUI, or both. It also handles the shell hook setup and can configure passwordless sudo so version switching doesn't prompt you on every `cd`.

To remove everything: `sudo bash uninstall.sh`

## CLI

```bash
phpvm                      # interactive TUI
phpvm --list               # show installed versions
phpvm --current            # show what's active
phpvm --set 8.2            # switch to 8.2
phpvm --auto               # switch based on project config
phpvm --set-project 8.2    # write .php-version in cwd
phpvm --help
```

**TUI keys:** `↑`/`↓` or `k`/`j` — move | `Enter` — switch | `p` — pin version to project | `q` — quit

## System tray

```bash
phpvm-gui
```

Shows active PHP version in the system tray. Click to switch versions or run auto-detect against a project folder.

Install the GTK dependencies first:

```bash
sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-ayatana-appindicator3-0.1
```

## Per-project PHP

Put a `.php-version` file in your project root:

```bash
echo "8.1" > .php-version
# or let phpvm write it
phpvm --set-project 8.1
```

phpvm walks up the directory tree looking for `.php-version`. If none is found it falls back to the `require.php` constraint in `composer.json`.

### Shell hook

Source the hook in your shell RC so phpvm checks the version on every `cd`:

```bash
# ~/.bashrc
source /etc/phpvm/php-auto.bash

# ~/.zshrc
source /etc/phpvm/php-auto.zsh

# ~/.config/fish/conf.d/phpvm.fish
source /etc/phpvm/php-auto.fish
```

The installer can add this automatically.

### Passwordless sudo

Every version switch runs `sudo update-alternatives`. To make that silent, add a sudoers rule (the installer offers to do this):

```
# /etc/sudoers.d/phpvm
username ALL=(ALL) NOPASSWD: /usr/bin/update-alternatives --set php /usr/bin/php*
```

## Registering PHP versions

If phpvm shows no versions, you need to register them with `update-alternatives` first:

```bash
sudo update-alternatives --install /usr/bin/php php /usr/bin/php8.3 83
sudo update-alternatives --install /usr/bin/php php /usr/bin/php8.2 82
sudo update-alternatives --install /usr/bin/php php /usr/bin/php8.1 81
```

## Project layout

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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
