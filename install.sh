#!/bin/bash
# phpvm Installer

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"

# curl|bash pipes stdin, so -t 0 fails even with a real terminal.
# Try opening /dev/tty (the controlling terminal) directly.
if [[ -t 0 ]] || { true < /dev/tty; } 2>/dev/null; then
    INTERACTIVE=1
else
    INTERACTIVE=0
fi

info()    { echo -e "  ${BLUE}→${NC} $*"; }
success() { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}!${NC} $*"; }
err()     { echo -e "  ${RED}✗${NC} $*" >&2; }

# bootstrap: when piped (curl | bash) or copied alone, this script has no
# sibling repo files. Clone the repo to a tmp dir, retarget SCRIPT_DIR, and
# continue in the same process so the EXIT trap below removes the clone.
if [[ ! -f "$SCRIPT_DIR/phpvm.sh" || ! -f "$SCRIPT_DIR/phpvm-gui.py" || ! -d "$SCRIPT_DIR/shell" ]]; then
    if ! command -v git &>/dev/null; then
        err "git required for remote install."
        echo -e "  ${DIM}Install git, or clone the repo and run ./install.sh from inside it.${NC}" >&2
        exit 1
    fi
    PHPVM_REMOTE="${PHPVM_REMOTE:-https://github.com/rijverse/phpvm.git}"
    PHPVM_REF="${PHPVM_REF:-main}"
    PHPVM_BOOTSTRAP_TMP=$(mktemp -d)
    trap 'rm -rf "$PHPVM_BOOTSTRAP_TMP"' EXIT
    info "Bootstrapping from ${CYAN}${PHPVM_REMOTE}${NC} @ ${BOLD}${PHPVM_REF}${NC}"
    if ! git clone --depth 1 --branch "$PHPVM_REF" "$PHPVM_REMOTE" "$PHPVM_BOOTSTRAP_TMP" >/dev/null 2>&1; then
        # branch may be a tag/sha rather than a branch; fall back to default clone + checkout
        if ! git clone --depth 1 "$PHPVM_REMOTE" "$PHPVM_BOOTSTRAP_TMP" >/dev/null 2>&1; then
            err "Clone failed: ${PHPVM_REMOTE}"
            exit 1
        fi
        if [[ "$PHPVM_REF" != "main" && "$PHPVM_REF" != "master" ]]; then
            (cd "$PHPVM_BOOTSTRAP_TMP" && git fetch origin "$PHPVM_REF" --depth 1 && git checkout FETCH_HEAD) >/dev/null 2>&1 \
                || { err "Checkout of ${PHPVM_REF} failed."; exit 1; }
        fi
    fi
    SCRIPT_DIR="$PHPVM_BOOTSTRAP_TMP"
fi

UPGRADE=0
for arg in "$@"; do
    case "$arg" in
        --upgrade|-U) UPGRADE=1 ;;
    esac
done

echo ""
echo -e "${BOLD}${BLUE}╭─────────────────────────────────────────╮${NC}"
echo -e "${BOLD}${BLUE}│${NC}             ${BOLD}phpvm Installer${NC}             ${BOLD}${BLUE}│${NC}"
echo -e "${BOLD}${BLUE}╰─────────────────────────────────────────╯${NC}"
echo ""

# determine install paths
if [[ $EUID -eq 0 ]]; then
    BIN_DIR="/usr/local/bin"
    HOOK_DIR="/etc/phpvm"
    DESKTOP_DIR="/usr/share/applications"
    CURRENT_USER="${SUDO_USER:-root}"
else
    BIN_DIR="$HOME/.local/bin"
    HOOK_DIR="$HOME/.phpvm"
    DESKTOP_DIR="$HOME/.local/share/applications"
    CURRENT_USER="$USER"
    warn "Not root, installing to user paths:"
    echo -e "  ${DIM}  bin     ${BIN_DIR}${NC}"
    echo -e "  ${DIM}  hooks   ${HOOK_DIR}${NC}"
    echo -e "  ${DIM}  desktop ${DESKTOP_DIR}${NC}"
    echo -e "  ${DIM}Run with sudo for system-wide install.${NC}"
fi

# what to install (interactive) or read from metadata (upgrade mode)

INSTALL_CLI=false
INSTALL_GUI=false

META_FILE="${HOOK_DIR}/install.meta"

if (( UPGRADE )); then
    if [[ -f "$META_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$META_FILE"
        info "Upgrade mode, replicating prior install (CLI=${INSTALL_CLI}, GUI=${INSTALL_GUI})"
    else
        warn "No metadata at ${META_FILE}; assuming both CLI + GUI"
        INSTALL_CLI=true
        INSTALL_GUI=true
    fi
else
    if (( ! INTERACTIVE )); then
        info "Non-interactive, defaulting to both CLI + GUI"
        INSTALL_CLI=true
        INSTALL_GUI=true
    else
        echo ""
        echo -e "  ${BOLD}What to install?${NC}"
        echo ""
        echo -e "    ${CYAN}1)${NC} CLI only        ${DIM}(phpvm terminal UI + commands)${NC}"
        echo -e "    ${CYAN}2)${NC} GUI only        ${DIM}(phpvm-gui system tray applet)${NC}"
        echo -e "    ${CYAN}3)${NC} Both            ${DIM}(CLI + GUI)${NC}"
        echo ""
        read -rp "  Choice [1/2/3] (default: 3): " choice < /dev/tty
        choice="${choice:-3}"

        case "$choice" in
            1) INSTALL_CLI=true ;;
            2) INSTALL_GUI=true ;;
            3) INSTALL_CLI=true; INSTALL_GUI=true ;;
            *)
                err "Invalid choice. Aborting."
                exit 1
                ;;
        esac
    fi
fi

echo ""
mkdir -p "$BIN_DIR"

# cli

if [[ "$INSTALL_CLI" == "true" ]]; then
    info "Installing CLI → ${CYAN}${BIN_DIR}/phpvm${NC}"
    cp "$SCRIPT_DIR/phpvm.sh" "$BIN_DIR/phpvm"
    chmod +x "$BIN_DIR/phpvm"
    success "CLI installed"
fi

# gui

if [[ "$INSTALL_GUI" == "true" ]]; then
    if ! command -v python3 &>/dev/null; then
        err "python3 not found, cannot install GUI"
        echo -e "  ${DIM}Install python3 then re-run.${NC}"
        INSTALL_GUI=false
    else
        info "Installing GUI → ${CYAN}${BIN_DIR}/phpvm-gui${NC}"
        cp "$SCRIPT_DIR/phpvm-gui.py" "$BIN_DIR/phpvm-gui"
        chmod +x "$BIN_DIR/phpvm-gui"
        success "GUI installed"

        if ! python3 -c "import gi" &>/dev/null; then
            warn "python3-gi not found, GUI won't start"
            echo -e "  ${DIM}Fix: sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-ayatana-appindicator3-0.1${NC}"
        fi

        echo ""
        info "Installing icon → hicolor theme"
        if [[ $EUID -eq 0 ]]; then
            ICON_DIR="/usr/share/icons/hicolor/scalable/apps"
        else
            ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
        fi
        mkdir -p "$ICON_DIR"
        cp "$SCRIPT_DIR/assets/phpvm.svg" "$ICON_DIR/phpvm.svg"
        if command -v gtk-update-icon-cache &>/dev/null; then
            gtk-update-icon-cache -f -t "$(dirname "$(dirname "$ICON_DIR")")" 2>/dev/null || true
        fi
        success "Icon installed → ${CYAN}${ICON_DIR}/phpvm.svg${NC}"

        mkdir -p "$DESKTOP_DIR"
        cat > "$DESKTOP_DIR/phpvm-gui.desktop" <<EOF
[Desktop Entry]
Name=phpvm
Comment=Switch PHP versions from system tray
Exec=${BIN_DIR}/phpvm-gui
Icon=phpvm
Type=Application
Categories=Development;
StartupNotify=false
EOF
        success "Desktop entry created"

        # autostart on login (user-scope only; xdg autostart is per-user)
        # under sudo, $HOME points at /root; resolve the real invoking user's home via passwd
        if [[ $EUID -eq 0 ]]; then
            USER_HOME=$(getent passwd "$CURRENT_USER" 2>/dev/null | cut -d: -f6)
        else
            USER_HOME="$HOME"
        fi
        AUTOSTART_DIR="${USER_HOME}/.config/autostart"
        AUTOSTART_FILE="${AUTOSTART_DIR}/phpvm-gui.desktop"

        if (( UPGRADE )); then
            if [[ -f "$AUTOSTART_FILE" ]]; then
                ans_auto="y"
                info "Refreshing existing autostart entry"
            else
                ans_auto="n"
            fi
        elif (( ! INTERACTIVE )); then
            ans_auto="n"
            info "Non-interactive, skipping autostart prompt"
        else
            echo ""
            echo -e "  ${BOLD}Launch phpvm-gui automatically on login?${NC}"
            echo -e "  ${DIM}Creates ${AUTOSTART_FILE}${NC}"
            read -rp "  Enable autostart? [y/N] " ans_auto < /dev/tty
        fi

        if [[ "$ans_auto" =~ ^[Yy]$ ]]; then
            AUTOSTART_CONTENT="[Desktop Entry]
Type=Application
Name=phpvm
Comment=Switch PHP versions from system tray
Exec=${BIN_DIR}/phpvm-gui
Icon=phpvm
Categories=Development;
X-GNOME-Autostart-enabled=true
StartupNotify=false"
            if [[ $EUID -eq 0 ]]; then
                # drop to the target user so the file lands with correct ownership/perms
                sudo -u "$CURRENT_USER" mkdir -p "$AUTOSTART_DIR"
                printf '%s\n' "$AUTOSTART_CONTENT" | sudo -u "$CURRENT_USER" tee "$AUTOSTART_FILE" >/dev/null
            else
                mkdir -p "$AUTOSTART_DIR"
                printf '%s\n' "$AUTOSTART_CONTENT" > "$AUTOSTART_FILE"
            fi
            success "Autostart enabled → ${CYAN}${AUTOSTART_FILE}${NC}"
        fi
    fi
fi

if [[ "$INSTALL_CLI" == "true" ]]; then

# shell hooks

echo ""
info "Installing shell hooks → ${CYAN}${HOOK_DIR}/${NC}"
mkdir -p "$HOOK_DIR"
cp "$SCRIPT_DIR/shell/php-auto.bash" "$HOOK_DIR/"
cp "$SCRIPT_DIR/shell/php-auto.zsh"  "$HOOK_DIR/"
cp "$SCRIPT_DIR/shell/php-auto.fish" "$HOOK_DIR/"
success "Shell hooks installed"

# shim: the `php` resolver that makes per-shell / per-project switching work.
# Lives under HOOK_DIR (which the hook prepends to PATH, and uninstall removes).
mkdir -p "$HOOK_DIR/shims"
cp "$SCRIPT_DIR/shell/shim-php" "$HOOK_DIR/shims/php"
chmod +x "$HOOK_DIR/shims/php"
success "Shim installed at ${CYAN}${HOOK_DIR}/shims/php${NC}"

# passwordless sudo

echo ""
echo -e "  ${BOLD}Passwordless sudo (for phpvm global only)${NC}"
echo -e "  ${DIM}Only the system-wide switch (phpvm global / --set) uses sudo.${NC}"
echo -e "  ${DIM}Per-shell (phpvm shell) and per-project (phpvm local) need none.${NC}"
echo ""
if (( UPGRADE )); then
    if [[ -f /etc/sudoers.d/phpvm ]] && grep -q 'php\*' /etc/sudoers.d/phpvm 2>/dev/null; then
        warn "Sudoers rule has old glob (php*), upgrading to tighter pattern"
        ans="y"
    else
        ans="n"
        [[ -f /etc/sudoers.d/phpvm ]] && info "Sudoers rule already present, keeping it."
    fi
elif (( ! INTERACTIVE )); then
    ans="n"
    info "Non-interactive, skipping sudoers prompt."
else
    read -rp "  Configure passwordless sudo for update-alternatives? [y/N] " ans < /dev/tty
fi
if [[ "$ans" =~ ^[Yy]$ ]]; then
    SUDOERS="/etc/sudoers.d/phpvm"
    SUDOERS_TMP="$(mktemp)"
    RULE="${CURRENT_USER} ALL=(ALL) NOPASSWD: /usr/bin/update-alternatives --set php /usr/bin/php[0-9].[0-9]"
    echo "$RULE" > "$SUDOERS_TMP"
    chmod 440 "$SUDOERS_TMP"
    if sudo visudo -c -f "$SUDOERS_TMP" &>/dev/null; then
        if [[ $EUID -eq 0 ]]; then
            mv "$SUDOERS_TMP" "$SUDOERS"
            chown root:root "$SUDOERS"
        else
            sudo install -o root -g root -m 440 "$SUDOERS_TMP" "$SUDOERS"
            rm -f "$SUDOERS_TMP"
        fi
        success "Sudoers rule added → ${CYAN}${SUDOERS}${NC}"
    else
        err "Sudoers validation failed, not installed"
        rm -f "$SUDOERS_TMP"
    fi
fi

# add hook to shell rc

echo ""
echo -e "  ${BOLD}Shell hook${NC}"
echo -e "  ${DIM}Powers per-shell switching (phpvm shell) and auto-switch on cd.${NC}"
echo -e "  ${DIM}Puts the shim dir on PATH and adds the phpvm() wrapper to your shell.${NC}"
echo ""

RC=""
HOOK_LINE=""
HOOK_ADDED=0
SHELL_NAME=$(basename "${SHELL:-bash}")
case "$SHELL_NAME" in
    bash)
        HOOK_LINE="source ${HOOK_DIR}/php-auto.bash"
        RC="$HOME/.bashrc"
        ;;
    zsh)
        HOOK_LINE="source ${HOOK_DIR}/php-auto.zsh"
        RC="$HOME/.zshrc"
        ;;
    fish)
        HOOK_LINE="source ${HOOK_DIR}/php-auto.fish"
        RC="$HOME/.config/fish/config.fish"
        ;;
esac

if [[ -n "$RC" ]]; then
    if grep -qF "$HOOK_LINE" "$RC" 2>/dev/null; then
        (( UPGRADE )) || warn "Hook already present in ${RC}"
    elif (( UPGRADE )); then
        info "Skipping shell hook prompt (upgrade mode)"
    else
        # default-enable: the everyday per-shell behavior depends on the hook
        ans="y"
        if (( INTERACTIVE )); then
            read -rp "  Enable the shell hook in ${RC}? [Y/n] " ans < /dev/tty
            ans="${ans:-y}"
        else
            info "Non-interactive, enabling the shell hook by default"
        fi
        if [[ ! "$ans" =~ ^[Nn]$ ]]; then
            {
                echo ""
                echo "# phpvm auto-switch"
                echo "$HOOK_LINE"
            } >> "$RC"
            success "Hook added to ${CYAN}${RC}${NC}"
            HOOK_ADDED=1
        fi
    fi
else
    warn "Shell '${SHELL_NAME}' not detected, add hook manually:"
    echo ""
    echo -e "  Bash: ${DIM}echo 'source ${HOOK_DIR}/php-auto.bash' >> ~/.bashrc${NC}"
    echo -e "  Zsh:  ${DIM}echo 'source ${HOOK_DIR}/php-auto.zsh'  >> ~/.zshrc${NC}"
    echo -e "  Fish: ${DIM}cp ${HOOK_DIR}/php-auto.fish ~/.config/fish/conf.d/phpvm.fish${NC}"
fi

fi # INSTALL_CLI

# path check

if [[ $EUID -ne 0 ]] && [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo ""
    warn "${BIN_DIR} not in PATH"
    echo -e "  ${DIM}Add to your shell RC: export PATH=\"\$PATH:${BIN_DIR}\"${NC}"
fi

# write install metadata for --self-update
mkdir -p "$HOOK_DIR"
PHPVM_VERSION_INSTALLED=$(grep -E '^VERSION="' "$SCRIPT_DIR/phpvm.sh" | head -1 | cut -d'"' -f2)
REPO_URL=""
if command -v git &>/dev/null && [[ -d "$SCRIPT_DIR/.git" ]]; then
    REPO_URL=$(git -C "$SCRIPT_DIR" config --get remote.origin.url 2>/dev/null || echo "")
    # convert git@host:owner/repo[.git] → https://host/owner/repo so --self-update works without ssh keys
    if [[ "$REPO_URL" =~ ^git@([^:]+):(.+)$ ]]; then
        REPO_URL="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    fi
fi
cat > "${HOOK_DIR}/install.meta" <<EOF
INSTALL_CLI=${INSTALL_CLI}
INSTALL_GUI=${INSTALL_GUI}
VERSION=${PHPVM_VERSION_INSTALLED}
REPO_URL=${REPO_URL}
INSTALLED_AT=$(date -Iseconds)
BIN_DIR=${BIN_DIR}
HOOK_DIR=${HOOK_DIR}
EOF

# done

echo ""
echo -e "${GREEN}${BOLD}Installation complete!${NC}"
echo ""
echo -e "  ${BOLD}Commands:${NC}"
if [[ "$INSTALL_CLI" == "true" ]]; then
    echo -e "    phpvm              Interactive TUI"
    echo -e "    phpvm --help       All CLI options"
fi
if [[ "$INSTALL_GUI" == "true" ]]; then
    echo -e "    phpvm-gui          System tray applet"
fi
if (( HOOK_ADDED )); then
    echo ""
    warn "${BOLD}Already open terminals won't have the hook yet${NC} (new ones do)."
    echo -e "    ${DIM}Activate it here:${NC} ${BOLD}source ${RC}${NC}"
fi

# launch gui immediately after install
if [[ "$INSTALL_GUI" == "true" ]] && (( INTERACTIVE )); then
    _DISPLAY="${DISPLAY:-}"
    _WAYLAND="${WAYLAND_DISPLAY:-}"
    _DBUS="${DBUS_SESSION_BUS_ADDRESS:-}"

    # sudo strips DISPLAY; recover it from the user's running session
    if [[ $EUID -eq 0 ]] && [[ -z "$_DISPLAY" ]] && [[ -z "$_WAYLAND" ]]; then
        while IFS= read -r _pid; do
            [[ -r "/proc/$_pid/environ" ]] || continue
            _env=$(tr '\0' '\n' < "/proc/$_pid/environ" 2>/dev/null)
            _d=$(printf '%s\n' "$_env" | grep '^DISPLAY=' | head -1 | cut -d= -f2)
            [[ -z "$_d" ]] && continue
            _DISPLAY="$_d"
            _DBUS=$(printf '%s\n' "$_env" | grep '^DBUS_SESSION_BUS_ADDRESS=' | head -1 | cut -d= -f2-)
            break
        done < <(pgrep -u "$CURRENT_USER" 2>/dev/null | head -10)
    fi

    if [[ -n "$_DISPLAY" ]] || [[ -n "$_WAYLAND" ]]; then
        if python3 -c "import gi" &>/dev/null; then
            echo ""
            info "Starting phpvm-gui..."
            if [[ $EUID -eq 0 ]]; then
                sudo -u "$CURRENT_USER" env \
                    DISPLAY="$_DISPLAY" \
                    WAYLAND_DISPLAY="$_WAYLAND" \
                    DBUS_SESSION_BUS_ADDRESS="$_DBUS" \
                    nohup "$BIN_DIR/phpvm-gui" >/dev/null 2>&1 &
            else
                nohup "$BIN_DIR/phpvm-gui" >/dev/null 2>&1 &
            fi
            disown
            success "phpvm-gui started"
        fi
    fi
fi

echo ""
