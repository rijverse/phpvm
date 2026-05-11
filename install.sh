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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()    { echo -e "  ${BLUE}→${NC} $*"; }
success() { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}!${NC} $*"; }
err()     { echo -e "  ${RED}✗${NC} $*" >&2; }

UPGRADE=0
for arg in "$@"; do
    case "$arg" in
        --upgrade|-U) UPGRADE=1 ;;
    esac
done

echo ""
echo -e "${BOLD}${BLUE}┌─────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${BLUE}│            phpvm Installer              │${NC}"
echo -e "${BOLD}${BLUE}└─────────────────────────────────────────┘${NC}"
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
    warn "Not root — installing to user paths:"
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
        info "Upgrade mode — replicating prior install (CLI=${INSTALL_CLI}, GUI=${INSTALL_GUI})"
    else
        warn "No metadata at ${META_FILE}; assuming both CLI + GUI"
        INSTALL_CLI=true
        INSTALL_GUI=true
    fi
else
    if [[ ! -t 0 ]]; then
        info "Non-interactive — defaulting to both CLI + GUI"
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
        read -rp "  Choice [1/2/3] (default: 3): " choice
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
    info "Installing CLI → ${BIN_DIR}/phpvm"
    cp "$SCRIPT_DIR/phpvm.sh" "$BIN_DIR/phpvm"
    chmod +x "$BIN_DIR/phpvm"
    success "CLI installed"
fi

# gui

if [[ "$INSTALL_GUI" == "true" ]]; then
    if ! command -v python3 &>/dev/null; then
        err "python3 not found — cannot install GUI"
        echo -e "  ${DIM}Install python3 then re-run.${NC}"
        INSTALL_GUI=false
    else
        info "Installing GUI → ${BIN_DIR}/phpvm-gui"
        cp "$SCRIPT_DIR/phpvm-gui.py" "$BIN_DIR/phpvm-gui"
        chmod +x "$BIN_DIR/phpvm-gui"
        success "GUI installed"

        if ! python3 -c "import gi" &>/dev/null; then
            warn "python3-gi not found — GUI won't start"
            echo -e "  ${DIM}Fix: sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-ayatana-appindicator3-0.1${NC}"
        fi

        mkdir -p "$DESKTOP_DIR"
        cat > "$DESKTOP_DIR/phpvm-gui.desktop" <<EOF
[Desktop Entry]
Name=phpvm
Comment=Switch PHP versions from system tray
Exec=${BIN_DIR}/phpvm-gui
Icon=dialog-information
Type=Application
Categories=Development;
StartupNotify=false
EOF
        success "Desktop entry created"
    fi
fi

if [[ "$INSTALL_CLI" == "true" ]]; then

# shell hooks

echo ""
info "Installing shell hooks → ${HOOK_DIR}/"
mkdir -p "$HOOK_DIR"
cp "$SCRIPT_DIR/shell/php-auto.bash" "$HOOK_DIR/"
cp "$SCRIPT_DIR/shell/php-auto.zsh"  "$HOOK_DIR/"
cp "$SCRIPT_DIR/shell/php-auto.fish" "$HOOK_DIR/"
success "Shell hooks installed"

# passwordless sudo

echo ""
echo -e "  ${BOLD}Passwordless sudo for auto-switching${NC}"
echo -e "  ${DIM}Without this, each auto-switch prompts for your password.${NC}"
echo ""
if (( UPGRADE )); then
    if [[ -f /etc/sudoers.d/phpvm ]] && grep -q 'php\*' /etc/sudoers.d/phpvm 2>/dev/null; then
        warn "Sudoers rule has old glob (php*) — upgrading to tighter pattern"
        ans="y"
    else
        ans="n"
        [[ -f /etc/sudoers.d/phpvm ]] && info "Sudoers rule already present — keeping it."
    fi
elif [[ ! -t 0 ]]; then
    ans="n"
    info "Non-interactive — skipping sudoers prompt."
else
    read -rp "  Configure passwordless sudo for update-alternatives? [y/N] " ans
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
        success "Sudoers rule added → ${SUDOERS}"
    else
        err "Sudoers validation failed — not installed"
        rm -f "$SUDOERS_TMP"
    fi
fi

# add hook to shell rc

echo ""
echo -e "  ${BOLD}Auto-switch hook${NC}"
echo -e "  ${DIM}Automatically switches PHP when entering project directories.${NC}"
echo ""

RC=""
HOOK_LINE=""
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
    elif [[ ! -t 0 ]]; then
        info "Non-interactive — skipping shell hook (run: phpvm --enable-hook)"
    else
        read -rp "  Add auto-switch hook to ${RC}? [y/N] " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            {
                echo ""
                echo "# phpvm auto-switch"
                echo "$HOOK_LINE"
            } >> "$RC"
            success "Hook added to ${RC}"
        fi
    fi
else
    warn "Shell '${SHELL_NAME}' not detected — add hook manually:"
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
    # Convert git@host:owner/repo[.git] → https://host/owner/repo so --self-update works without ssh keys
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
echo ""
echo -e "  ${DIM}Reload shell or run: source ${RC:-~/.bashrc}${NC}"
echo ""
