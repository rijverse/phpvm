#!/bin/bash
# phpvm - PHP Version Manager v2.3.3

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "phpvm requires bash 4.3+. Current: ${BASH_VERSION}" >&2
    exit 1
fi

VERSION="2.3.3"

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

# normalize raw version string (e.g. "php8.2", "8.2.0", " 8.2\n") → "8.2"
normalize_version() {
    local raw="$1"
    raw="${raw//[[:space:]]/}"
    raw="${raw#php}"
    if [[ "$raw" =~ ^([0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
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

find_composer_json() {
    local dir="${1:-$PWD}"
    while :; do
        if [[ -f "$dir/composer.json" ]]; then
            echo "$dir/composer.json"
            return 0
        fi
        [[ "$dir" == "/" ]] && break
        dir=$(dirname "$dir")
    done
    return 1
}

detect_from_composer() {
    local dir="${1:-$PWD}"
    local composer
    composer=$(find_composer_json "$dir") || return 1

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
        local raw
        raw=$(< "$vfile")
        local norm
        if norm=$(normalize_version "$raw"); then
            echo "$norm"
            return 0
        fi
        return 1
    fi

    local cver
    cver=$(detect_from_composer "$dir")
    if [[ -n "$cver" ]]; then
        normalize_version "$cver" || echo "$cver"
        return 0
    fi

    return 1
}

# switching

do_switch() {
    local target="$1"
    local quiet="${2:-false}"

    local err
    err=$(sudo -p "[phpvm] switching PHP — password for %u: " update-alternatives --set php "$target" 2>&1 >/dev/null)
    local code=$?

    if [[ "$quiet" != "true" ]]; then
        if [[ "$code" -eq 0 ]]; then
            echo -e "${GREEN}✓${NC} Switched to ${BOLD}$(basename "$target")${NC}  ${DIM}($(php --version 2>/dev/null | head -1))${NC}"
        else
            echo -e "${RED}✗${NC} Failed to switch." >&2
            [[ -n "$err" ]] && echo -e "${DIM}${err}${NC}" >&2
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
    local quiet="${1:-false}"
    local print_only="${2:-false}"
    local dir="${3:-$PWD}"

    if [[ "$print_only" != "true" ]]; then
        require_update_alternatives
    fi

    local ver
    ver=$(detect_project_php "$dir")
    if [[ -z "$ver" ]]; then
        [[ "$quiet" != "true" && "$print_only" != "true" ]] && echo -e "${DIM}No .php-version or composer.json found.${NC}"
        return 1
    fi

    if [[ "$print_only" == "true" ]]; then
        echo "$ver"
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

    if [[ "$quiet" == "true" ]]; then
        if [[ "$rc" -eq 0 ]]; then
            echo -e "${GREEN}phpvm:${NC} switched to PHP ${BOLD}${ver}${NC}"
        elif [[ "$rc" -ne 0 ]]; then
            echo -e "${RED}phpvm:${NC} failed to switch to PHP ${ver}" >&2
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

    local norm
    norm=$(normalize_version "$ver") || {
        echo -e "${RED}Invalid version: ${ver}${NC}" >&2
        echo -e "${DIM}Expected format: X.Y (e.g. 8.2)${NC}" >&2
        exit 1
    }
    ver="$norm"

    if ! find_version_by_query "$ver" >/dev/null; then
        echo -e "${YELLOW}!${NC} PHP ${ver} not installed locally. Writing anyway." >&2
    fi

    if [[ -f .php-version ]] && [[ -t 0 ]]; then
        local existing
        existing=$(< .php-version)
        existing="${existing//[[:space:]]/}"
        if [[ "$existing" != "$ver" ]]; then
            read -rp "  .php-version already says '${existing}'. Overwrite? [y/N] " ans
            [[ "$ans" =~ ^[Yy]$ ]] || { echo -e "${DIM}Cancelled.${NC}"; exit 0; }
        fi
    fi

    echo "$ver" > .php-version
    echo -e "${GREEN}✓${NC} Created ${BOLD}.php-version${NC} → ${CYAN}${ver}${NC}"
}

detect_hook_dir() {
    if [[ -d /etc/phpvm ]]; then
        echo /etc/phpvm
    elif [[ -d "$HOME/.phpvm" ]]; then
        echo "$HOME/.phpvm"
    else
        return 1
    fi
}

resolve_shell() {
    local shell="$1"
    [[ -z "$shell" ]] && shell=$(basename "${SHELL:-bash}")
    case "$shell" in
        bash|zsh|fish) echo "$shell"; return 0 ;;
        *) return 1 ;;
    esac
}

shell_rc_path() {
    case "$1" in
        bash) echo "$HOME/.bashrc" ;;
        zsh)  echo "$HOME/.zshrc"  ;;
        fish) echo "$HOME/.config/fish/config.fish" ;;
    esac
}

cmd_enable_hook() {
    local shell
    shell=$(resolve_shell "${1:-}") || {
        echo -e "${RED}Unsupported shell: ${1:-unknown}${NC}" >&2
        echo -e "${DIM}Use bash, zsh, or fish.${NC}" >&2
        exit 1
    }

    local hook_dir
    hook_dir=$(detect_hook_dir) || {
        echo -e "${RED}Hook directory not found.${NC}" >&2
        echo -e "${DIM}Expected /etc/phpvm or ~/.phpvm — re-run install.sh.${NC}" >&2
        exit 1
    }

    local hook_file="${hook_dir}/php-auto.${shell}"
    if [[ ! -f "$hook_file" ]]; then
        echo -e "${RED}Hook file missing: ${hook_file}${NC}" >&2
        exit 1
    fi

    local rc
    rc=$(shell_rc_path "$shell")
    local line="source ${hook_file}"

    if [[ -f "$rc" ]] && grep -qF "$line" "$rc"; then
        echo -e "${YELLOW}!${NC} Already enabled in ${BOLD}${rc}${NC}"
        return 0
    fi

    mkdir -p "$(dirname "$rc")"
    {
        echo ""
        echo "# phpvm auto-switch"
        echo "$line"
    } >> "$rc"

    echo -e "${GREEN}✓${NC} Hook enabled for ${BOLD}${shell}${NC} → ${rc}"
    echo -e "  ${DIM}Reload: source ${rc}${NC}"
}

cmd_disable_hook() {
    local shell
    shell=$(resolve_shell "${1:-}") || {
        echo -e "${RED}Unsupported shell: ${1:-unknown}${NC}" >&2
        exit 1
    }

    local rc
    rc=$(shell_rc_path "$shell")

    if [[ ! -f "$rc" ]]; then
        echo -e "${DIM}No ${rc}.${NC}"
        return 0
    fi

    if ! grep -qE 'php-auto\.(bash|zsh|fish)|# phpvm auto-switch' "$rc"; then
        echo -e "${DIM}Hook not present in ${rc}.${NC}"
        return 0
    fi

    cp -- "$rc" "${rc}.phpvm-backup"
    sed -i \
        -e '/^# phpvm auto-switch$/d' \
        -e '\#source .*/php-auto\.\(bash\|zsh\|fish\)#d' \
        "$rc"

    echo -e "${GREEN}✓${NC} Hook disabled for ${BOLD}${shell}${NC} → ${rc}"
    echo -e "  ${DIM}Backup: ${rc}.phpvm-backup${NC}"
    echo -e "  ${DIM}Reload: source ${rc}${NC}"
}

cmd_self_update() {
    local repo_arg="${1:-}"
    local ref="${2:-main}"

    if ! command -v git &>/dev/null; then
        echo -e "${RED}git not found.${NC}" >&2
        exit 1
    fi

    local hook_dir
    if [[ -d /etc/phpvm ]]; then
        hook_dir=/etc/phpvm
    elif [[ -d "$HOME/.phpvm" ]]; then
        hook_dir="$HOME/.phpvm"
    fi

    local meta_repo=""
    if [[ -n "$hook_dir" && -f "${hook_dir}/install.meta" ]]; then
        # shellcheck disable=SC1090,SC1091
        meta_repo=$(grep -E '^REPO_URL=' "${hook_dir}/install.meta" | cut -d= -f2-)
    fi

    local repo="${repo_arg:-${PHPVM_REPO:-$meta_repo}}"
    if [[ -z "$repo" ]]; then
        echo -e "${RED}No repo URL.${NC}" >&2
        echo -e "${DIM}Usage: phpvm --self-update [URL] [REF]${NC}" >&2
        echo -e "${DIM}Or set PHPVM_REPO env var, or re-install from a git clone.${NC}" >&2
        exit 1
    fi

    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    echo -e "  ${BLUE}→${NC} Fetching ${BOLD}${repo}${NC} @ ${ref}"
    if [[ -d "$repo" ]]; then
        cp -r "$repo/." "$tmp/"
    elif ! git clone --depth 1 --branch "$ref" "$repo" "$tmp" >/dev/null 2>&1; then
        if ! git clone --depth 1 "$repo" "$tmp" >/dev/null 2>&1; then
            echo -e "${RED}✗${NC} Clone failed." >&2
            exit 1
        fi
        if [[ "$ref" != "main" && "$ref" != "master" ]]; then
            (cd "$tmp" && git fetch origin "$ref" --depth 1 && git checkout FETCH_HEAD) >/dev/null 2>&1 \
                || { echo -e "${RED}✗${NC} Checkout of ${ref} failed." >&2; exit 1; }
        fi
    fi

    if [[ ! -f "$tmp/install.sh" || ! -f "$tmp/phpvm.sh" ]]; then
        echo -e "${RED}✗${NC} Source missing install.sh or phpvm.sh." >&2
        exit 1
    fi

    local new_ver
    new_ver=$(grep -E '^VERSION="' "$tmp/phpvm.sh" | head -1 | cut -d'"' -f2)
    echo -e "  ${BLUE}→${NC} Current: ${BOLD}${VERSION}${NC}   New: ${BOLD}${new_ver}${NC}"

    if [[ "$VERSION" == "$new_ver" ]]; then
        if [[ -t 0 ]]; then
            read -rp "  Already on ${VERSION}. Reinstall anyway? [y/N] " ans
            [[ "$ans" =~ ^[Yy]$ ]] || { echo -e "${DIM}Cancelled.${NC}"; exit 0; }
        else
            echo -e "${DIM}Already on ${VERSION}; non-interactive — skipping.${NC}"
            exit 0
        fi
    fi

    local is_system=0
    [[ -f /usr/local/bin/phpvm || -f /usr/local/bin/phpvm-gui || -d /etc/phpvm ]] && is_system=1

    if (( is_system )) && [[ $EUID -ne 0 ]]; then
        sudo bash "$tmp/install.sh" --upgrade
    else
        bash "$tmp/install.sh" --upgrade
    fi

    echo -e "  ${GREEN}✓${NC} Updated to ${BOLD}${new_ver}${NC}"
}

# doctor counters live at script scope so the _doc_* helpers can increment them
# (bash arithmetic in a function body can't easily mutate caller-locals)
_doc_pass=0
_doc_fail=0
_doc_warn=0

_doc_ok()   { echo -e "  ${GREEN}✓${NC} $*"; (( _doc_pass++ )); }
_doc_bad()  { echo -e "  ${RED}✗${NC} $*"; (( _doc_fail++ )); }
_doc_warn() { echo -e "  ${YELLOW}!${NC} $*"; (( _doc_warn++ )); }
_doc_info() { echo -e "    ${DIM}$*${NC}"; }
_doc_skip() { echo -e "  ${DIM}—${NC}  $*"; }
_doc_section() {
    echo ""
    echo -e "${BOLD}${BLUE}▸ $*${NC}"
}

cmd_doctor() {
    _doc_pass=0; _doc_fail=0; _doc_warn=0

    echo ""
    echo -e "${BOLD}${BLUE}phpvm --doctor${NC}  v${VERSION}"
    echo -e "${DIM}  user=${USER}  shell=$(basename "${SHELL:-?}")  pwd=${PWD}${NC}"

    # cli install
    _doc_section "CLI install"

    local installed_bin
    installed_bin=$(command -v phpvm 2>/dev/null || echo "")
    if [[ -n "$installed_bin" ]]; then
        local installed_ver
        installed_ver=$(grep -E '^VERSION="' "$installed_bin" 2>/dev/null | head -1 | cut -d'"' -f2)
        if [[ "$installed_ver" == "$VERSION" ]]; then
            _doc_ok "Binary: ${BOLD}${installed_bin}${NC}  v${installed_ver}"
        else
            _doc_warn "Binary ${BOLD}${installed_bin}${NC} v${installed_ver:-?} but source v${VERSION}"
            _doc_info "Fix: sudo bash install.sh --upgrade"
        fi
    else
        _doc_bad "phpvm not found in PATH"
    fi

    # path shadow — multiple phpvm binaries
    # `command -v -a` lists every match in PATH; awk dedupes symlink chains pointing to the same file
    local all_phpvm
    all_phpvm=$(command -v -a phpvm 2>/dev/null | awk '!seen[$0]++')
    local count
    count=$(echo "$all_phpvm" | grep -c .)
    if (( count > 1 )); then
        _doc_warn "Multiple phpvm in PATH — first wins:"
        while IFS= read -r p; do
            [[ -n "$p" ]] && _doc_info "$p"
        done <<< "$all_phpvm"
        _doc_info "Remove stale copies or fix PATH order."
    fi

    # bin_dir writable
    local bin_dir
    bin_dir="$(dirname "$installed_bin")"
    if [[ -n "$installed_bin" ]]; then
        if [[ -w "$bin_dir" ]]; then
            _doc_ok "BIN_DIR ${BOLD}${bin_dir}${NC} writable by ${USER}"
        else
            _doc_warn "BIN_DIR ${BOLD}${bin_dir}${NC} not writable — self-update needs sudo"
        fi
    fi

    # bash version
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
        _doc_bad "bash ${BASH_VERSION} — need 4.3+"
    else
        _doc_ok "bash ${BASH_VERSION}"
    fi

    # php runtimes
    _doc_section "PHP runtimes"

    if ! command -v update-alternatives &>/dev/null; then
        _doc_bad "update-alternatives missing — Debian/Ubuntu only"
        _doc_info "Fix: sudo apt install dpkg"
    else
        _doc_ok "update-alternatives: $(command -v update-alternatives)"

        local versions
        versions=$(get_php_versions)
        local vcount
        vcount=$(echo "$versions" | grep -c .)
        if (( vcount == 0 )); then
            _doc_bad "No PHP versions registered in update-alternatives"
            _doc_info "Fix: sudo apt install php8.2 php8.2-cli  (or any phpX.Y)"
        else
            _doc_ok "${vcount} PHP runtime(s) registered"
            while IFS= read -r v; do
                [[ -z "$v" ]] && continue
                local label
                label=$(basename "$v")
                if [[ -x "$v" ]]; then
                    local ver
                    ver=$("$v" -r 'echo PHP_VERSION;' 2>/dev/null || echo "?")
                    _doc_info "${label} → ${ver}"
                else
                    _doc_info "${label} → ${RED}missing binary${NC}"
                fi
            done <<< "$versions"
        fi

        local current_alt
        current_alt=$(readlink /etc/alternatives/php 2>/dev/null || echo "")
        if [[ -n "$current_alt" ]]; then
            _doc_ok "Active: ${BOLD}$(basename "$current_alt")${NC}  (${current_alt})"
        else
            _doc_warn "No active /etc/alternatives/php symlink"
        fi
    fi

    # composer
    if command -v composer &>/dev/null; then
        local comp_ver
        comp_ver=$(composer --version 2>/dev/null | head -1)
        _doc_ok "composer: ${comp_ver}"
    else
        _doc_warn "composer not installed — composer.json detection works but install is up to you"
        _doc_info "Install: https://getcomposer.org/download/"
    fi

    # php-fpm
    _doc_section "PHP-FPM"

    if command -v systemctl &>/dev/null; then
        local fpm_units
        fpm_units=$(systemctl list-unit-files 'php*-fpm.service' --no-legend --no-pager 2>/dev/null | awk '{print $1}')
        if [[ -z "$fpm_units" ]]; then
            _doc_skip "No php*-fpm.service units (FPM not installed)"
        else
            while IFS= read -r unit; do
                [[ -z "$unit" ]] && continue
                local active
                active=$(systemctl is-active "$unit" 2>/dev/null || echo "?")
                local enabled
                enabled=$(systemctl is-enabled "$unit" 2>/dev/null || echo "?")
                if [[ "$active" == "active" ]]; then
                    _doc_ok "${unit}  active=${GREEN}${active}${NC}  enabled=${enabled}"
                else
                    _doc_info "${unit}  active=${active}  enabled=${enabled}"
                fi
            done <<< "$fpm_units"
        fi
    else
        _doc_skip "systemctl not available — skipping FPM check"
    fi

    # sudo
    _doc_section "Sudo (auto-switch)"

    local sudoers="/etc/sudoers.d/phpvm"
    if [[ -f "$sudoers" ]]; then
        local rule
        rule=$(cat "$sudoers" 2>/dev/null)
        _doc_ok "Sudoers: ${BOLD}${sudoers}${NC}"
        _doc_info "${rule}"
        if [[ "$rule" == *"php*"* ]]; then
            _doc_warn "Rule uses old glob ${BOLD}php*${NC} — re-run install.sh to tighten"
        fi
    else
        _doc_warn "No sudoers rule at ${BOLD}${sudoers}${NC}"
        _doc_info "Auto-switch will prompt for password or silently fail."
        _doc_info "Fix: sudo bash install.sh (answer Y to sudoers prompt)"
    fi

    current_alt=$(readlink /etc/alternatives/php 2>/dev/null || echo "")
    if [[ -n "$current_alt" ]]; then
        local test_out test_rc
        # set to the already-active alt: no-op switch, but exercises the exact sudoers rule
        test_out=$(sudo -n update-alternatives --set php "$current_alt" 2>&1)
        test_rc=$?
        if [[ "$test_rc" -eq 0 ]]; then
            _doc_ok "sudo -n update-alternatives --set php ${BOLD}$(basename "$current_alt")${NC}  → ok"
        else
            _doc_bad "sudo -n update-alternatives failed (rc=${test_rc})"
            [[ -n "$test_out" ]] && _doc_info "${test_out}"
            _doc_info "Auto-switch will silently no-op without passwordless sudo."
        fi
    else
        _doc_warn "No active PHP alternative — cannot test sudo -n"
    fi

    # shell hook
    _doc_section "Shell hook (auto-switch on cd)"

    local hook_dir
    hook_dir=$(detect_hook_dir 2>/dev/null || echo "")
    if [[ -z "$hook_dir" ]]; then
        _doc_bad "Hook dir not found (looked in /etc/phpvm and ~/.phpvm)"
        _doc_info "Fix: re-run install.sh"
    else
        _doc_ok "Hook dir: ${BOLD}${hook_dir}${NC}"
        local missing=0
        for h in php-auto.bash php-auto.zsh php-auto.fish; do
            if [[ -f "${hook_dir}/${h}" ]]; then
                _doc_info "✓ ${h}"
            else
                _doc_info "✗ ${h} ${RED}missing${NC}"
                (( missing++ ))
            fi
        done
        (( missing > 0 )) && _doc_warn "${missing} hook file(s) missing — re-run install.sh"
    fi

    local shell_name rc
    shell_name=$(basename "${SHELL:-bash}")
    rc=$(shell_rc_path "$shell_name")
    if [[ -n "$hook_dir" && -n "$rc" ]]; then
        local hook_file="${hook_dir}/php-auto.${shell_name}"
        if grep -qF "source ${hook_file}" "$rc" 2>/dev/null; then
            _doc_ok "Hook sourced in ${BOLD}${rc}${NC}"
        else
            _doc_warn "Hook NOT in ${BOLD}${rc}${NC}"
            _doc_info "Fix: phpvm --enable-hook"
        fi
    else
        _doc_warn "Cannot locate shell rc (shell=${shell_name})"
    fi

    # gui (optional)
    _doc_section "GUI / tray (optional)"

    local gui_bin
    gui_bin=$(command -v phpvm-gui 2>/dev/null || echo "")
    if [[ -z "$gui_bin" ]]; then
        _doc_skip "phpvm-gui not installed (CLI-only install)"
    else
        _doc_ok "GUI binary: ${BOLD}${gui_bin}${NC}"

        if ! command -v python3 &>/dev/null; then
            _doc_bad "python3 missing — GUI will not start"
            _doc_info "Fix: sudo apt install python3"
        else
            local py_ver
            py_ver=$(python3 --version 2>&1)
            _doc_ok "${py_ver}"

            if python3 -c "import gi" &>/dev/null; then
                _doc_ok "python3-gi present"
            else
                _doc_bad "python3-gi missing"
                _doc_info "Fix: sudo apt install python3-gi gir1.2-gtk-3.0"
            fi

            if python3 -c "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk" &>/dev/null; then
                _doc_ok "GTK 3 typelib available"
            else
                _doc_bad "GTK 3 typelib missing"
                _doc_info "Fix: sudo apt install gir1.2-gtk-3.0"
            fi

            # ubuntu 20.04+ ships Ayatana fork; older distros still have the legacy AppIndicator3 — accept either
            if python3 -c "import gi; gi.require_version('AyatanaAppIndicator3','0.1'); from gi.repository import AyatanaAppIndicator3" &>/dev/null; then
                _doc_ok "Ayatana AppIndicator3 available (tray will work)"
            elif python3 -c "import gi; gi.require_version('AppIndicator3','0.1'); from gi.repository import AppIndicator3" &>/dev/null; then
                _doc_ok "AppIndicator3 available (legacy, tray will work)"
            else
                _doc_warn "No AppIndicator typelib — tray icon will not appear"
                _doc_info "Fix: sudo apt install gir1.2-ayatana-appindicator3-0.1"
            fi
        fi

        # icon
        local icon_found=""
        for p in /usr/share/icons/hicolor/scalable/apps/phpvm.svg \
                 "$HOME/.local/share/icons/hicolor/scalable/apps/phpvm.svg" \
                 /usr/local/share/icons/hicolor/scalable/apps/phpvm.svg; do
            [[ -f "$p" ]] && icon_found="$p" && break
        done
        if [[ -n "$icon_found" ]]; then
            _doc_ok "Icon: ${icon_found}"
        else
            _doc_warn "phpvm.svg icon not installed — GUI uses fallback"
            _doc_info "Fix: re-run install.sh"
        fi

        # desktop entry
        local desk_found=""
        for d in /usr/share/applications/phpvm-gui.desktop \
                 "$HOME/.local/share/applications/phpvm-gui.desktop"; do
            [[ -f "$d" ]] && desk_found="$d" && break
        done
        if [[ -n "$desk_found" ]]; then
            _doc_ok "Desktop entry: ${desk_found}"
        else
            _doc_warn "No .desktop entry — app menu launch unavailable"
        fi

        # autostart
        local autostart="$HOME/.config/autostart/phpvm-gui.desktop"
        if [[ -f "$autostart" ]]; then
            _doc_ok "Autostart enabled: ${autostart}"
        else
            _doc_skip "Autostart not configured (tray won't launch on login)"
            _doc_info "Enable: re-run install.sh and answer Y to autostart prompt"
        fi

        # running?
        if pgrep -x phpvm-gui &>/dev/null; then
            _doc_ok "phpvm-gui process running (pid: $(pgrep -x phpvm-gui | tr '\n' ' '))"
        else
            _doc_skip "phpvm-gui not currently running"
        fi
    fi

    # project
    _doc_section "Project (cwd)"

    local proj_ver
    proj_ver=$(detect_project_php 2>/dev/null || echo "")
    if [[ -n "$proj_ver" ]]; then
        _doc_ok "Project PHP: ${CYAN}${proj_ver}${NC}"
        local pv_file
        pv_file=$(find_php_version_file 2>/dev/null || echo "")
        local cj_file
        cj_file=$(find_composer_json 2>/dev/null || echo "")
        [[ -n "$pv_file" ]] && _doc_info ".php-version → ${pv_file}"
        [[ -n "$cj_file" ]] && _doc_info "composer.json → ${cj_file}"

        # is requested version installed?
        local norm
        norm=$(normalize_version "$proj_ver" 2>/dev/null || echo "")
        if [[ -n "$norm" ]] && find_version_by_query "$proj_ver" &>/dev/null; then
            _doc_ok "Requested version ${proj_ver} → installed"
        else
            _doc_warn "Requested version ${proj_ver} not installed"
            _doc_info "Fix: sudo apt install php${proj_ver}"
        fi
    else
        _doc_skip "No .php-version / composer.json found in ${PWD} or parents"
    fi

    # summary
    echo ""
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    local total=$(( _doc_pass + _doc_warn + _doc_fail ))
    if (( _doc_fail > 0 )); then
        echo -e "  ${BOLD}${_doc_pass} ok${NC} / ${YELLOW}${_doc_warn} warn${NC} / ${RED}${_doc_fail} fail${NC}  (of ${total})"
    elif (( _doc_warn > 0 )); then
        echo -e "  ${BOLD}${_doc_pass} ok${NC} / ${YELLOW}${_doc_warn} warn${NC}  (of ${total})"
    else
        echo -e "  ${BOLD}${GREEN}All ${total} checks passed${NC}"
    fi
    echo ""
    (( _doc_fail > 0 )) && return 1
    return 0
}

cmd_window() {
    if ! command -v phpvm-gui &>/dev/null; then
        echo -e "${RED}phpvm-gui not installed.${NC}" >&2
        echo -e "${DIM}Install with: sudo bash install.sh (choose GUI or both)${NC}" >&2
        exit 1
    fi
    if ! python3 -c "import gi; gi.require_version('Gtk', '3.0'); from gi.repository import Gtk" &>/dev/null; then
        echo -e "${RED}python3-gi / GTK3 missing.${NC}" >&2
        echo -e "${DIM}Fix: sudo apt install python3-gi gir1.2-gtk-3.0${NC}" >&2
        exit 1
    fi
    # phpvm-gui daemonizes itself; the setsid + & is belt-and-suspenders
    # in case fork() is unavailable (some sandboxes).
    setsid phpvm-gui --window </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
    echo -e "${GREEN}✓${NC} Window launched."
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
    echo -e "  phpvm --auto --print [dir]   Print resolved project PHP version (no switch)"
    echo -e "  phpvm --set-project <ver>    Write .php-version in current dir"
    echo -e "  phpvm --enable-hook [shell]  Add auto-switch hook to shell rc (bash/zsh/fish)"
    echo -e "  phpvm --disable-hook [shell] Remove auto-switch hook from shell rc"
    echo -e "  phpvm --window               Open detached GTK picker window (needs phpvm-gui)"
    echo -e "  phpvm --self-update [URL] [REF]  Pull latest from git and re-run installer"
    echo -e "  phpvm --doctor               Full diagnostic: CLI, PHP runtimes, FPM, sudo, hooks, GUI"
    echo -e "  phpvm --version              Show tool version"
    echo -e "  phpvm --help                 This help"
    echo ""
    echo -e "${BOLD}GUI (separate binary, optional):${NC}"
    echo -e "  phpvm-gui                    Tray applet"
    echo -e "  phpvm-gui --window           Standalone GTK picker window (no tray)"
    echo ""
    echo -e "${BOLD}Shell hook (auto-switch on cd):${NC}"
    echo -e "  ${DIM}System install (/etc/phpvm):${NC}"
    echo -e "    Bash: ${DIM}echo 'source /etc/phpvm/php-auto.bash' >> ~/.bashrc${NC}"
    echo -e "    Zsh:  ${DIM}echo 'source /etc/phpvm/php-auto.zsh'  >> ~/.zshrc${NC}"
    echo -e "    Fish: ${DIM}cp /etc/phpvm/php-auto.fish ~/.config/fish/conf.d/${NC}"
    echo -e "  ${DIM}User install (~/.phpvm):${NC}"
    echo -e "    Bash: ${DIM}echo 'source ~/.phpvm/php-auto.bash' >> ~/.bashrc${NC}"
    echo -e "    Zsh:  ${DIM}echo 'source ~/.phpvm/php-auto.zsh'  >> ~/.zshrc${NC}"
    echo -e "    Fish: ${DIM}cp ~/.phpvm/php-auto.fish ~/.config/fish/conf.d/${NC}"
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

    echo -e "${BOLD}${BLUE}╭─────────────────────────────────────────╮${NC}"
    echo -e "${BOLD}${BLUE}│                  phpvm                  │${NC}"
    echo -e "${BOLD}${BLUE}╰─────────────────────────────────────────╯${NC}"
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

    echo -e "${BOLD}${BLUE}╭─────────────────────────────────────────╮${NC}"
    echo -e "${BOLD}${BLUE}│                  phpvm                  │${NC}"
    echo -e "${BOLD}${BLUE}╰─────────────────────────────────────────╯${NC}"
    echo ""
    echo -e "  Switching to ${BOLD}${CYAN}${label}${NC} ..."
    echo ""

    sudo -p "[phpvm] switching PHP — password for %u: " update-alternatives --set php "$target"
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
    local raw="${label#php}"
    local ver
    if ! ver=$(normalize_version "$raw"); then
        ver="$raw"
    fi

    tput cnorm
    clear

    echo -e "${BOLD}${BLUE}╭─────────────────────────────────────────╮${NC}"
    echo -e "${BOLD}${BLUE}│                  phpvm                  │${NC}"
    echo -e "${BOLD}${BLUE}╰─────────────────────────────────────────╯${NC}"
    echo ""
    echo -e "  Set ${BOLD}${CYAN}${ver}${NC} as project PHP?"
    echo -e "  ${DIM}Writes .php-version in current directory${NC}"
    echo ""

    if [[ -f .php-version ]]; then
        local existing
        existing=$(< .php-version)
        existing="${existing//[[:space:]]/}"
        if [[ -n "$existing" && "$existing" != "$ver" ]]; then
            echo -e "  ${YELLOW}!${NC} .php-version already says ${BOLD}${existing}${NC} — overwrite?"
            echo ""
        fi
    fi

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
        PRINT_ONLY=false
        DIR="$PWD"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -q | --quiet) QUIET=true ;;
                --print) PRINT_ONLY=true ;;
                *) DIR="$1" ;;
            esac
            shift
        done
        cmd_auto "$QUIET" "$PRINT_ONLY" "$DIR"
        ;;
    -p | --set-project)
        cmd_set_project "${1:-}"
        ;;
    --enable-hook)
        cmd_enable_hook "${1:-}"
        ;;
    --disable-hook)
        cmd_disable_hook "${1:-}"
        ;;
    -w | --window)
        cmd_window
        ;;
    --self-update)
        cmd_self_update "${1:-}" "${2:-main}"
        ;;
    --doctor)
        cmd_doctor
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
