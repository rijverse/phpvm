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

# remove from both system and user locations if present.
BIN_DIRS=("/usr/local/bin" "$HOME/.local/bin")
HOOK_DIRS=("/etc/phpvm" "$HOME/.phpvm")
SUDOERS="/etc/sudoers.d/phpvm"
DESKTOPS=(
    "/usr/share/applications/phpvm-gui.desktop"
    "$HOME/.local/share/applications/phpvm-gui.desktop"
)

# Quit running phpvm-gui
if pgrep -x phpvm-gui &>/dev/null; then
    pkill -x phpvm-gui 2>/dev/null && success "Stopped phpvm-gui" || warn "Could not stop phpvm-gui"
fi

# Remove binaries
for dir in "${BIN_DIRS[@]}"; do
    for bin in phpvm phpvm-gui; do
        f="${dir}/${bin}"
        if [[ -f "$f" ]]; then
            if [[ -w "$dir" || $EUID -eq 0 ]]; then
                rm -f "$f"
            else
                sudo rm -f "$f"
            fi
            success "Removed ${f}"
        fi
    done
done

# remove hook dirs
for d in "${HOOK_DIRS[@]}"; do
    if [[ -d "$d" ]]; then
        if [[ -w "$(dirname "$d")" || $EUID -eq 0 ]]; then
            rm -rf "$d"
        else
            sudo rm -rf "$d"
        fi
        success "Removed ${d}"
    fi
done

# Remove sudoers
if [[ -f "$SUDOERS" ]]; then
    if [[ $EUID -eq 0 ]]; then
        rm -f "$SUDOERS"
    else
        sudo rm -f "$SUDOERS"
    fi
    success "Removed ${SUDOERS}"
fi

# remove desktop entries
for desktop in "${DESKTOPS[@]}"; do
    [[ -f "$desktop" ]] || continue
    if [[ -w "$desktop" || $EUID -eq 0 ]]; then
        rm -f "$desktop"
    else
        sudo rm -f "$desktop"
    fi
    success "Removed ${desktop}"
done

# remove shell hook lines (only our exact lines, never a blanket /phpvm/ wipe)
clean_rc() {
    local rc="$1"
    [[ -f "$rc" ]] || return 0
    grep -qE 'php-auto\.(bash|zsh|fish)|# phpvm auto-switch' "$rc" || return 0
    cp -- "$rc" "${rc}.phpvm-backup"
    # delete our marker comment + any source line pointing at our hook files
    sed -i \
        -e '/^# phpvm auto-switch$/d' \
        -e '\#source .*/php-auto\.\(bash\|zsh\|fish\)#d' \
        "$rc"
    success "Cleaned hook from ${rc}  ${DIM}(backup: ${rc}.phpvm-backup)${NC}"
}

for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.config/fish/config.fish"; do
    clean_rc "$rc"
done

echo ""
echo -e "${GREEN}${BOLD}Uninstall complete.${NC}"
echo ""