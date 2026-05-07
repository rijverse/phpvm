#!/bin/bash
# phpvm - PHP Version Manager v2.0.0

VERSION="2.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'
REVERSE='\033[7m'

selected_index=0

# helpers

get_php_versions() {
    update-alternatives --list php 2>/dev/null | sort -V
}

get_current_php() {
    readlink /etc/alternatives/php 2>/dev/null
}

require_update_alternatives() {
    if ! command -v update-alternatives &>/dev/null; then
        echo -e "${RED}Error: update-alternatives not found.${NC}" >&2
        exit 1
    fi
}

find_version_by_query() {
    local query="$1"
    local versions
    mapfile -t versions < <(get_php_versions)
    for v in "${versions[@]}"; do
        local name
        name=$(basename "$v")
        if [[ "$name" == "$query" ]] || [[ "$name" == "php${query}" ]] || [[ "$v" == "$query" ]]; then
            echo "$v"
            return 0
        fi
    done
    return 1
}

# project detection

find_php_version_file() {
    local dir="${1:-$PWD}"
    while :; do
        if [[ -f "$dir/.php-version" ]]; then
            echo "$dir/.php-version"
            return 0
        fi
        [[ "$dir" == "/" ]] && break
        dir=$(dirname "$dir")
    done
    return 1
}

detect_from_composer() {
    local dir="${1:-$PWD}"
    local composer="$dir/composer.json"
    [[ -f "$composer" ]] || return 1

    # pick highest installed PHP minor that the constraint allows.
    # falls back to first version token if no installed match.
    local installed
    installed=$(get_php_versions | sed -E 's|.*/php([0-9]+\.[0-9]+)$|\1|' | sort -V | tr '\n' ' ')

    if command -v python3 &>/dev/null; then
        python3 - "$composer" "$installed" <<'PYEOF' 2>/dev/null
import json, sys, re
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    req = data.get('require', {}).get('php', '')
    if not req:
        sys.exit(0)

    installed = [v for v in sys.argv[2].split() if v]

    def parse(v):
        return tuple(int(x) for x in v.split('.'))

    def matches(ver, expr):
        ver_t = parse(ver)
        for clause in expr.split('|'):
            clause = clause.strip().lstrip('v')
            if not clause:
                continue
            ok = True
            for part in re.split(r'\s*,\s*|\s+', clause):
                if not part:
                    continue
                m = re.match(r'^(\^|~|>=|<=|>|<|=)?\s*v?(\d+(?:\.\d+){0,2})', part)
                if not m:
                    ok = False
                    break
                op = m.group(1) or '='
                bound = parse(m.group(2))
                while len(bound) < 2:
                    bound = bound + (0,)
                bv = bound[:2]
                vt = ver_t[:2]
                if op == '^':
                    if vt < bv or vt[0] != bv[0]:
                        ok = False
                        break
                elif op == '~':
                    if len(bound) >= 2:
                        if vt < bv or vt[0] != bv[0]:
                            ok = False
                            break
                elif op == '>=':
                    if vt < bv: ok = False; break
                elif op == '<=':
                    if vt > bv: ok = False; break
                elif op == '>':
                    if vt <= bv: ok = False; break
                elif op == '<':
                    if vt >= bv: ok = False; break
                else:
                    if vt != bv: ok = False; break
            if ok:
                return True
        return False

    matched = [v for v in installed if matches(v, req)]
    if matched:
        print(sorted(matched, key=parse)[-1])
    else:
        m = re.search(r'(\d+\.\d+)', req)
        if m:
            print(m.group(1))
except Exception:
    pass
PYEOF
    else
        grep -o '"php"[[:space:]]*:[[:space:]]*"[^"]*"' "$composer" \
            | grep -oE '[0-9]+\.[0-9]+' | head -1
    fi
}

detect_project_php() {
    local dir="${1:-$PWD}"

    local vfile
    vfile=$(find_php_version_file "$dir")
    if [[ -n "$vfile" ]]; then
        tr -d '[:space:]' < "$vfile"
        return 0
    fi

    local cver
    cver=$(detect_from_composer "$dir")
    if [[ -n "$cver" ]]; then
        echo "$cver"
        return 0
    fi

    return 1
}

# switching

do_switch() {
    local target="$1"
    local quiet="${2:-false}"

    sudo update-alternatives --set php "$target" >/dev/null 2>&1
    local code=$?

    if [[ "$quiet" != "true" ]]; then
        if [[ "$code" -eq 0 ]]; then
            echo -e "${GREEN}✓${NC} Switched to ${BOLD}$(basename "$target")${NC}  ${DIM}($(php --version 2>/dev/null | head -1))${NC}"
        else
            echo -e "${RED}✗${NC} Failed to switch. Check sudo permissions." >&2
            return 1
        fi
    fi
    return "$code"
}

# cli commands

cmd_list() {
    require_update_alternatives
    local current
    current=$(get_current_php)
    mapfile -t versions < <(get_php_versions)

    if [[ "${#versions[@]}" -eq 0 ]]; then
        echo -e "${RED}No PHP alternatives registered.${NC}" >&2
        exit 1
    fi

    for v in "${versions[@]}"; do
        local name
        name=$(basename "$v")
        if [[ "$v" == "$current" ]]; then
            echo -e "  ${GREEN}●${NC} ${BOLD}${name}${NC}  ${DIM}(active)${NC}"
        else
            echo -e "    ${DIM}${name}${NC}"
        fi
    done
}

cmd_current() {
    local current
    current=$(get_current_php)
    if [[ -z "$current" ]]; then
        echo -e "${YELLOW}No active PHP version found.${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}$(basename "$current")${NC}  ${DIM}($(php --version 2>/dev/null | head -1))${NC}"
}

cmd_set() {
    require_update_alternatives
    local query="$1"
    if [[ -z "$query" ]]; then
        echo -e "${RED}Usage: phpvm --set <version>${NC}" >&2
        echo -e "${DIM}Example: phpvm --set 8.2${NC}" >&2
        exit 1
    fi

    local target
    target=$(find_version_by_query "$query")
    if [[ -z "$target" ]]; then
        echo -e "${RED}Version not found: ${query}${NC}" >&2
        echo -e "${DIM}Run: phpvm --list${NC}" >&2
        exit 1
    fi

    do_switch "$target"
}

cmd_auto() {
    require_update_alternatives
    local quiet="${1:-false}"
    local dir="${2:-$PWD}"

    local ver
    ver=$(detect_project_php "$dir")
    if [[ -z "$ver" ]]; then
        [[ "$quiet" != "true" ]] && echo -e "${DIM}No .php-version or composer.json found.${NC}"
        return 0
    fi

    local current
    current=$(get_current_php)
    local current_name
    current_name=$(basename "$current")

    if [[ "$current_name" == "php${ver}" ]]; then
        [[ "$quiet" != "true" ]] && echo -e "${DIM}Already on PHP ${ver}.${NC}"
        return 0
    fi

    local target
    target=$(find_version_by_query "$ver")
    if [[ -z "$target" ]]; then
        [[ "$quiet" != "true" ]] && echo -e "${YELLOW}PHP ${ver} required but not installed.${NC}" >&2
        return 1
    fi

    do_switch "$target" "$quiet"
    local rc=$?

    if [[ "$quiet" == "true" ]] && command -v notify-send &>/dev/null; then
        if [[ "$rc" -eq 0 ]]; then
            notify-send "phpvm" "Switched to PHP ${ver}" --icon=dialog-information 2>/dev/null
        else
            notify-send -u critical "phpvm" "Failed to switch to PHP ${ver}" --icon=dialog-error 2>/dev/null
        fi
    fi
    return "$rc"
}

cmd_set_project() {
    local ver="$1"
    if [[ -z "$ver" ]]; then
        echo -e "${RED}Usage: phpvm --set-project <version>${NC}" >&2
        echo -e "${DIM}Example: phpvm --set-project 8.2${NC}" >&2
        exit 1
    fi

    ver="${ver#php}"
    echo "$ver" > .php-version
    echo -e "${GREEN}✓${NC} Created ${BOLD}.php-version${NC} → ${CYAN}${ver}${NC}"
}

cmd_help() {
    echo -e "${BOLD}${BLUE}phpvm${NC} v${VERSION}"
    echo ""
    echo -e "${BOLD}Usage:${NC}"
    echo -e "  phpvm                        Interactive TUI"
    echo -e "  phpvm --list                 List installed PHP versions"
    echo -e "  phpvm --current              Show active PHP version"
    echo -e "  phpvm --set <version>        Switch to version (e.g. 8.2)"
    echo -e "  phpvm --auto [--quiet]       Auto-switch from .php-version / composer.json"
    echo -e "  phpvm --set-project <ver>    Write .php-version in current dir"
    echo -e "  phpvm --version              Show tool version"
    echo -e "  phpvm --help                 This help"
    echo ""
    echo -e "${BOLD}Shell hook (auto-switch on cd):${NC}"
    echo -e "  ${DIM}Hook dir: /etc/phpvm (system install) or ~/.phpvm (user install)${NC}"
    echo -e "  Bash: ${DIM}echo 'source <hook-dir>/php-auto.bash' >> ~/.bashrc${NC}"
    echo -e "  Zsh:  ${DIM}echo 'source <hook-dir>/php-auto.zsh'  >> ~/.zshrc${NC}"
    echo -e "  Fish: ${DIM}cp <hook-dir>/php-auto.fish ~/.config/fish/conf.d/${NC}"
    echo ""
    echo -e "${BOLD}Project config:${NC}"
    echo -e "  .php-version    Plain text file with PHP version (e.g. ${CYAN}8.2${NC})"
    echo -e "  composer.json   Uses ${CYAN}require.php${NC} field if .php-version not found"
    echo ""
}

# tui

draw_menu() {
    local -n _versions=$1
    local current_php
    current_php=$(get_current_php)
    local total=${#_versions[@]}

    tput cup 0 0
    tput ed

    echo -e "${BOLD}${BLUE}┌─────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${BLUE}│                  phpvm                  │${NC}"
    echo -e "${BOLD}${BLUE}└─────────────────────────────────────────┘${NC}"
    echo ""

    local current_name
    if [[ -n "$current_php" ]]; then
        current_name=$(basename "$current_php")
        echo -e "  ${DIM}Active:${NC}  ${GREEN}${BOLD}${current_name}${NC}  ${DIM}($(php --version 2>/dev/null | head -1 | awk '{print $1,$2}'))${NC}"
    else
        echo -e "  ${DIM}Active:${NC}  ${YELLOW}unknown${NC}"
    fi

    local proj_ver
    proj_ver=$(detect_project_php 2>/dev/null)
    if [[ -n "$proj_ver" ]]; then
        echo -e "  ${DIM}Project:${NC} ${CYAN}${proj_ver}${NC}"
    fi

    echo ""
    echo -e "  ${DIM}↑/↓  navigate   Enter  select   p  set-project   q  quit${NC}"
    echo ""
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo ""

    for i in "${!_versions[@]}"; do
        local ver="${_versions[$i]}"
        local label
        label=$(basename "$ver")

        local badge=""
        if [[ "$ver" == "$current_php" ]]; then
            badge="  ${GREEN}● active${NC}"
        fi

        if [[ "$i" -eq "$selected_index" ]]; then
            printf "  ${REVERSE}${BOLD}  %-38s  ${NC}${badge}\n" "$label"
        else
            printf "    ${CYAN}%-38s${NC}${badge}\n" "$label"
        fi
    done

    echo ""
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  ${DIM}${total} version(s) found via update-alternatives${NC}"
    echo ""
}

switch_version_tui() {
    local target="$1"
    local label
    label=$(basename "$target")

    tput cnorm
    clear

    echo -e "${BOLD}${BLUE}┌─────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${BLUE}│                  phpvm                  │${NC}"
    echo -e "${BOLD}${BLUE}└─────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  Switching to ${BOLD}${CYAN}${label}${NC} ..."
    echo ""

    sudo update-alternatives --set php "$target"
    local exit_code=$?

    echo ""
    if [[ "$exit_code" -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}Done!${NC}"
        echo ""
        echo -e "  ${DIM}$(php --version 2>/dev/null | head -1)${NC}"
    else
        echo -e "  ${RED}${BOLD}Failed to switch.${NC} Check sudo permissions."
    fi

    echo ""
    echo -e "  ${DIM}Press any key to return...${NC}"
    IFS= read -rsn1
}

set_project_tui() {
    local version="$1"
    local label
    label=$(basename "$version")
    local ver="${label#php}"

    tput cnorm
    clear

    echo -e "${BOLD}${BLUE}┌─────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${BLUE}│                  phpvm                  │${NC}"
    echo -e "${BOLD}${BLUE}└─────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  Set ${BOLD}${CYAN}${ver}${NC} as project PHP?"
    echo -e "  ${DIM}Writes .php-version in current directory${NC}"
    echo ""
    echo -e "  ${DIM}[y] confirm   [n] cancel${NC}"
    echo ""

    IFS= read -rsn1 confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo "$ver" > .php-version
        echo ""
        echo -e "  ${GREEN}✓${NC} Created ${BOLD}.php-version${NC} → ${CYAN}${ver}${NC}"
    else
        echo ""
        echo -e "  ${DIM}Cancelled.${NC}"
    fi

    echo ""
    echo -e "  ${DIM}Press any key to return...${NC}"
    IFS= read -rsn1
}

tui_main() {
    require_update_alternatives

    mapfile -t versions < <(get_php_versions)

    if [[ "${#versions[@]}" -eq 0 ]]; then
        echo -e "${RED}No PHP alternatives found.${NC}"
        echo ""
        echo -e "${DIM}Register a version with:${NC}"
        echo -e "  sudo update-alternatives --install /usr/bin/php php /usr/bin/php8.x 80"
        exit 1
    fi

    local current_php
    current_php=$(get_current_php)

    for i in "${!versions[@]}"; do
        if [[ "${versions[$i]}" == "$current_php" ]]; then
            selected_index=$i
            break
        fi
    done

    tput civis
    trap 'tput cnorm; tput rmcup; exit 0' EXIT INT TERM

    tput smcup
    clear

    while true; do
        draw_menu versions

        IFS= read -rsn1 key

        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -rsn2 -t 0.1 seq
            key="${key}${seq}"
        fi

        case "$key" in
            $'\x1b[A' | k | K)
                (( selected_index-- ))
                [[ "$selected_index" -lt 0 ]] && selected_index=$(( ${#versions[@]} - 1 ))
                ;;
            $'\x1b[B' | j | J)
                (( selected_index++ ))
                [[ "$selected_index" -ge "${#versions[@]}" ]] && selected_index=0
                ;;
            '')
                switch_version_tui "${versions[$selected_index]}"
                mapfile -t versions < <(get_php_versions)
                current_php=$(get_current_php)
                tput civis
                tput smcup
                clear
                ;;
            p | P)
                set_project_tui "${versions[$selected_index]}"
                tput civis
                tput smcup
                clear
                ;;
            q | Q)
                break
                ;;
        esac
    done

    tput cnorm
    tput rmcup
    echo -e "${DIM}phpvm closed.${NC}"
}

# entry point

CMD="${1:-}"
shift 2>/dev/null || true

case "$CMD" in
    -l | --list)
        cmd_list
        ;;
    -c | --current)
        cmd_current
        ;;
    -s | --set)
        cmd_set "${1:-}"
        ;;
    -a | --auto)
        QUIET=false
        DIR="$PWD"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -q | --quiet) QUIET=true ;;
                *) DIR="$1" ;;
            esac
            shift
        done
        cmd_auto "$QUIET" "$DIR"
        ;;
    -p | --set-project)
        cmd_set_project "${1:-}"
        ;;
    -v | --version)
        echo "phpvm $VERSION"
        ;;
    -h | --help)
        cmd_help
        ;;
    "")
        tui_main
        ;;
    *)
        echo -e "${RED}Unknown option: $CMD${NC}" >&2
        echo -e "${DIM}Run: phpvm --help${NC}" >&2
        exit 1
        ;;
esac
