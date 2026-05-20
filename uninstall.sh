#!/bin/bash
# phpvm Uninstaller

set -e

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
echo -e "${BOLD}${BLUE}╭─────────────────────────────────────────╮${NC}"
echo -e "${BOLD}${BLUE}│            phpvm Uninstaller            │${NC}"
echo -e "${BOLD}${BLUE}╰─────────────────────────────────────────╯${NC}"
echo ""

# remove from both system and user locations if present.
BIN_DIRS=("/usr/local/bin" "$HOME/.local/bin")
HOOK_DIRS=("/etc/phpvm" "$HOME/.phpvm")
SUDOERS="/etc/sudoers.d/phpvm"
DESKTOPS=(
    "/usr/share/applications/phpvm-gui.desktop"
    "$HOME/.local/share/applications/phpvm-gui.desktop"
)
AUTOSTARTS=(
    "$HOME/.config/autostart/phpvm-gui.desktop"
)
ICONS=(
    "/usr/share/icons/hicolor/scalable/apps/phpvm.svg"
    "/usr/local/share/icons/hicolor/scalable/apps/phpvm.svg"
    "$HOME/.local/share/icons/hicolor/scalable/apps/phpvm.svg"
)
# honor sudo invocation — also clean caller's home if running as root
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    SUDO_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    if [[ -n "$SUDO_HOME" && "$SUDO_HOME" != "$HOME" ]]; then
        BIN_DIRS+=("${SUDO_HOME}/.local/bin")
        HOOK_DIRS+=("${SUDO_HOME}/.phpvm")
        AUTOSTARTS+=("${SUDO_HOME}/.config/autostart/phpvm-gui.desktop")
        DESKTOPS+=("${SUDO_HOME}/.local/share/applications/phpvm-gui.desktop")
        ICONS+=("${SUDO_HOME}/.local/share/icons/hicolor/scalable/apps/phpvm.svg")
    fi
fi

# quit running phpvm-gui
if pgrep -x phpvm-gui &>/dev/null; then
    pkill -x phpvm-gui 2>/dev/null && success "Stopped phpvm-gui" || warn "Could not stop phpvm-gui"
fi

# remove binaries
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

# remove sudoers
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

# remove autostart entries
for a in "${AUTOSTARTS[@]}"; do
    [[ -f "$a" ]] || continue
    if [[ -w "$a" || $EUID -eq 0 ]]; then
        rm -f "$a"
    else
        sudo rm -f "$a"
    fi
    success "Removed ${a}"
done

# remove icons + refresh cache
ICON_DIRS_TO_REFRESH=()
for ic in "${ICONS[@]}"; do
    [[ -f "$ic" ]] || continue
    if [[ -w "$ic" || $EUID -eq 0 ]]; then
        rm -f "$ic"
    else
        sudo rm -f "$ic"
    fi
    success "Removed ${ic}"
    # icon path is .../hicolor/scalable/apps/phpvm.svg — strip 3 levels to get the hicolor theme root for gtk-update-icon-cache
    ICON_DIRS_TO_REFRESH+=("$(dirname "$(dirname "$(dirname "$ic")")")")
done
if command -v gtk-update-icon-cache &>/dev/null; then
    for d in "${ICON_DIRS_TO_REFRESH[@]}"; do
        gtk-update-icon-cache -f -t "$d" 2>/dev/null || true
    done
fi

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

RC_HOMES=("$HOME")
if [[ $EUID -eq 0 && -n "${SUDO_HOME:-}" && "$SUDO_HOME" != "$HOME" ]]; then
    RC_HOMES+=("$SUDO_HOME")
fi
for h in "${RC_HOMES[@]}"; do
    for rc in "$h/.bashrc" "$h/.zshrc" "$h/.config/fish/config.fish"; do
        clean_rc "$rc"
    done
done

echo ""
echo -e "${GREEN}${BOLD}Uninstall complete.${NC}"
echo ""