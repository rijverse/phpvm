#!/bin/bash
# phpvm Installer

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()    { echo -e "  ${BLUE}→${NC} $*"; }
success() { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}!${NC} $*"; }
err()     { echo -e "  ${RED}✗${NC} $*" >&2; }

echo ""
echo -e "${BOLD}${BLUE}┌─────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${BLUE}│            phpvm Installer              │${NC}"
echo -e "${BOLD}${BLUE}└─────────────────────────────────────────┘${NC}"
echo ""

# Determine install paths
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
    warn "Not root — installing to ${BIN_DIR}"
    echo -e "  ${DIM}Run with sudo for system-wide install.${NC}"
fi

# what to install

echo ""
echo -e "  ${BOLD}What to install?${NC}"
echo ""
echo -e "    ${CYAN}1)${NC} CLI only        ${DIM}(phpvm terminal UI + commands)${NC}"
echo -e "    ${CYAN}2)${NC} GUI only        ${DIM}(phpvm-gui system tray applet)${NC}"
echo -e "    ${CYAN}3)${NC} Both            ${DIM}(CLI + GUI)${NC}"
echo ""
read -rp "  Choice [1/2/3] (default: 3): " choice
choice="${choice:-3}"

INSTALL_CLI=false
INSTALL_GUI=false
case "$choice" in
    1) INSTALL_CLI=true ;;
    2) INSTALL_GUI=true ;;
    3) INSTALL_CLI=true; INSTALL_GUI=true ;;
    *)
        err "Invalid choice. Aborting."
        exit 1
        ;;
esac

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
read -rp "  Configure passwordless sudo for update-alternatives? [y/N] " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    SUDOERS="/etc/sudoers.d/phpvm"
    RULE="${CURRENT_USER} ALL=(ALL) NOPASSWD: /usr/bin/update-alternatives --set php /usr/bin/php*"
    if [[ $EUID -eq 0 ]]; then
        echo "$RULE" > "$SUDOERS"
        chmod 440 "$SUDOERS"
    else
        echo "$RULE" | sudo tee "$SUDOERS" > /dev/null
        sudo chmod 440 "$SUDOERS"
    fi
    if sudo visudo -c -f "$SUDOERS" &>/dev/null; then
        success "Sudoers rule added → ${SUDOERS}"
    else
        err "Sudoers validation failed — removing invalid file"
        rm -f "$SUDOERS"
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
    if grep -qF "phpvm" "$RC" 2>/dev/null; then
        warn "Hook already present in ${RC}"
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
