#!/bin/bash
# phpvm Uninstaller

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

success() { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}!${NC} $*"; }
info()    { echo -e "  ${BLUE}→${NC} $*"; }

echo ""
echo -e "${BOLD}${BLUE}┌─────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${BLUE}│            phpvm Uninstaller            │${NC}"
echo -e "${BOLD}${BLUE}└─────────────────────────────────────────┘${NC}"
echo ""

# Detect install location
if [[ -f "/usr/local/bin/phpvm" ]]; then
    BIN_DIR="/usr/local/bin"
    HOOK_DIR="/etc/phpvm"
    SUDOERS="/etc/sudoers.d/phpvm"
    DESKTOP_SYS="/usr/share/applications/phpvm-gui.desktop"
else
    BIN_DIR="$HOME/.local/bin"
    HOOK_DIR="$HOME/.phpvm"
    SUDOERS=""
    DESKTOP_SYS=""
fi

# Remove binaries
for bin in phpvm phpvm-gui; do
    f="${BIN_DIR}/${bin}"
    if [[ -f "$f" ]]; then
        rm -f "$f"
        success "Removed ${f}"
    fi
done

# Remove hook dir
if [[ -d "$HOOK_DIR" ]]; then
    rm -rf "$HOOK_DIR"
    success "Removed ${HOOK_DIR}"
fi

# Remove sudoers
if [[ -n "$SUDOERS" && -f "$SUDOERS" ]]; then
    if [[ $EUID -eq 0 ]]; then
        rm -f "$SUDOERS"
    else
        sudo rm -f "$SUDOERS"
    fi
    success "Removed ${SUDOERS}"
fi

# Remove desktop entries
for desktop in \
    "$DESKTOP_SYS" \
    "$HOME/.local/share/applications/phpvm-gui.desktop"
do
    [[ -n "$desktop" && -f "$desktop" ]] || continue
    rm -f "$desktop"
    success "Removed ${desktop}"
done

# Remove shell hook lines
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.config/fish/config.fish"; do
    [[ -f "$rc" ]] || continue
    if grep -q "phpvm" "$rc"; then
        sed -i '/# phpvm auto-switch/d' "$rc"
        sed -i '/phpvm/d' "$rc"
        success "Cleaned hook from ${rc}"
    fi
done

echo ""
echo -e "${GREEN}${BOLD}Uninstall complete.${NC}"
echo ""