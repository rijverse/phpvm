#!/bin/bash
# CLI compatibility tests, run inside a container or directly on host.
# Usage: bash tests/test_cli.sh [path/to/phpvm.sh]

set -uo pipefail

PHPVM="${1:-$(dirname "$0")/../phpvm.sh}"
PHPVM="$(realpath "$PHPVM")"

pass=0
fail=0

ok()   { echo "  PASS  $1"; pass=$(( pass + 1 )); }
fail() { echo "  FAIL  $1"; fail=$(( fail + 1 )); }
sep()  { echo ""; echo "--- $1 ---"; }

sep "environment"
echo "  bash    ${BASH_VERSION}"
echo "  os      $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -s)"
echo "  phpvm   ${PHPVM}"

sep "--version"
out=$(bash "$PHPVM" --version 2>&1) && [[ "$out" == *"phpvm"* ]] \
    && ok "--version prints 'phpvm'" || fail "--version"

sep "--help"
bash "$PHPVM" --help >/dev/null 2>&1 \
    && ok "--help exits 0" || fail "--help exits non-zero"

sep "--list"
# exits 1 when no PHP installed; that's expected, not a crash
out=$(bash "$PHPVM" --list 2>&1); rc=$?
if [[ $rc -eq 0 ]] || [[ "$out" == *"No PHP"* || "$out" == *"php"* ]]; then
    ok "--list runs without crash (rc=${rc})"
else
    fail "--list crashed unexpectedly (rc=${rc}): ${out}"
fi

sep "--current"
out=$(bash "$PHPVM" --current 2>&1); rc=$?
[[ $rc -eq 0 || "$out" == *"No active"* || "$out" == *"none"* || "$out" == *"php"* ]] \
    && ok "--current runs without crash" || fail "--current crashed (rc=${rc}): ${out}"

sep "--current three-layer breakdown"
out=$(bash "$PHPVM" --current 2>&1)
[[ "$out" == *"shell:"* && "$out" == *"project:"* && "$out" == *"global:"* ]] \
    && ok "--current shows shell/project/global labels" \
    || fail "--current missing layer labels: ${out}"

sep "--set (no version arg, expect usage error, not crash)"
out=$(bash "$PHPVM" --set 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"Usage"* ]] \
    && ok "--set without arg exits non-zero with usage message" || fail "--set without arg behaved unexpectedly (rc=${rc}): ${out}"

sep "unknown subcommand (regression: bare positional must fail)"
out=$(bash "$PHPVM" use 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"Unknown option"* ]] \
    && ok "unknown 'use' is rejected" || fail "unknown 'use' was not rejected as expected (rc=${rc}): ${out}"

sep "install (no version arg, expect usage error, not crash)"
out=$(bash "$PHPVM" install 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"Usage"* ]] \
    && ok "install without arg exits non-zero with usage message" || fail "install without arg behaved unexpectedly (rc=${rc}): ${out}"

sep "install (patch-level rejected)"
out=$(bash "$PHPVM" install 8.2.13 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"patch"* ]] \
    && ok "install 8.2.13 rejected (X.Y only)" || fail "install patch-level not rejected (rc=${rc}): ${out}"

# os-release fixtures let the distro paths run deterministically without real apt
OSR_DIR=$(mktemp -d)
trap 'rm -rf "$OSR_DIR"' EXIT
printf 'ID=arch\nID_LIKE=archlinux\n'                          > "$OSR_DIR/arch"
printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_CODENAME=jammy\n'   > "$OSR_DIR/ubuntu"
printf 'ID=debian\nVERSION_CODENAME=bookworm\n'                > "$OSR_DIR/debian"

sep "install (unsupported distro guard)"
out=$(PHPVM_OS_RELEASE="$OSR_DIR/arch" bash "$PHPVM" install 8.3 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"Debian and Ubuntu"* ]] \
    && ok "unsupported distro rejected with clean error" || fail "unsupported distro not guarded (rc=${rc}): ${out}"

sep "install --print (Ubuntu PPA, no real apt)"
out=$(PHPVM_OS_RELEASE="$OSR_DIR/ubuntu" bash "$PHPVM" install 8.3 --print 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"ppa:ondrej/php"* && "$out" == *"php8.3-cli"* && "$out" == *"php8.3-fpm"* ]] \
    && ok "ubuntu --print shows PPA + default packages" || fail "ubuntu --print wrong (rc=${rc}): ${out}"

sep "install --print --minimal --with (Ubuntu)"
out=$(PHPVM_OS_RELEASE="$OSR_DIR/ubuntu" bash "$PHPVM" install 8.3 --minimal --with curl,mbstring --print 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"php8.3-curl"* && "$out" == *"php8.3-mbstring"* && "$out" != *"php8.3-fpm"* ]] \
    && ok "--minimal drops fpm, --with appends extensions" || fail "--minimal/--with wrong (rc=${rc}): ${out}"

sep "install --print (Debian deb.sury.org, no real apt)"
out=$(PHPVM_OS_RELEASE="$OSR_DIR/debian" bash "$PHPVM" install 8.2 --print 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"packages.sury.org"* && "$out" == *"bookworm"* && "$out" == *"php8.2-cli"* ]] \
    && ok "debian --print shows sury repo pinned to codename" || fail "debian --print wrong (rc=${rc}): ${out}"

sep "sh-shell --unset (POSIX)"
out=$(bash "$PHPVM" sh-shell --unset 2>&1)
[[ "$out" == "unset PHPVM_SHELL_VERSION" ]] \
    && ok "sh-shell --unset emits POSIX unset" || fail "sh-shell --unset wrong: ${out}"

sep "sh-shell --unset --fish"
out=$(bash "$PHPVM" sh-shell --unset --fish 2>&1)
[[ "$out" == "set -e PHPVM_SHELL_VERSION" ]] \
    && ok "sh-shell --unset --fish emits fish syntax" || fail "sh-shell --unset --fish wrong: ${out}"

sep "sh-shell (no version, emits a failing snippet not a crash)"
out=$(bash "$PHPVM" sh-shell 2>&1)
[[ "$out" == *"false"* && "$out" == *"usage"* ]] \
    && ok "sh-shell with no version emits usage + false" || fail "sh-shell no-arg wrong: ${out}"

sep "sh-shell (uninstalled version, emits a failing snippet)"
out=$(bash "$PHPVM" sh-shell 9.99 2>&1)
[[ "$out" == *"not installed"* && "$out" == *"false"* ]] \
    && ok "sh-shell rejects an uninstalled version via the eval'd snippet" || fail "sh-shell 9.99 wrong: ${out}"

sep "sh-shell (installed version, emits export)"
inst=$(update-alternatives --list php 2>/dev/null | grep -oE 'php[0-9]+\.[0-9]+' | head -1 | sed 's/php//')
if [[ -n "$inst" ]]; then
    out=$(bash "$PHPVM" sh-shell "$inst" 2>&1)
    [[ "$out" == "export PHPVM_SHELL_VERSION=${inst}" ]] \
        && ok "sh-shell ${inst} emits POSIX export" || fail "sh-shell ${inst} wrong: ${out}"
    out=$(bash "$PHPVM" sh-shell "$inst" --fish 2>&1)
    [[ "$out" == "set -gx PHPVM_SHELL_VERSION ${inst}" ]] \
        && ok "sh-shell ${inst} --fish emits fish set -gx" || fail "sh-shell ${inst} --fish wrong: ${out}"
else
    ok "sh-shell success path skipped (no PHP registered in update-alternatives)"
fi

sep "global (no version arg, expect usage error)"
out=$(bash "$PHPVM" global 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"Usage"* ]] \
    && ok "global without arg exits non-zero with usage" || fail "global no-arg wrong (rc=${rc}): ${out}"

sep "local (no version arg, expect usage error)"
out=$(bash "$PHPVM" local 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"Usage"* ]] \
    && ok "local without arg exits non-zero with usage" || fail "local no-arg wrong (rc=${rc}): ${out}"

sep "local writes .php-version (alias of --set-project)"
tmpd=$(mktemp -d)
( cd "$tmpd" && bash "$PHPVM" local 8.1 >/dev/null 2>&1 && [[ "$(cat .php-version)" == "8.1" ]] )
rc=$?
rm -rf "$tmpd"
[[ $rc -eq 0 ]] && ok "local 8.1 writes .php-version" || fail "local did not write .php-version (rc=${rc})"

sep "local normalizes version input"
tmpd2=$(mktemp -d)
( cd "$tmpd2" && bash "$PHPVM" local php8.1 >/dev/null 2>&1 && [[ "$(cat .php-version)" == "8.1" ]] )
[[ $? -eq 0 ]] && ok "local php8.1 normalizes to 8.1" || fail "local php8.1 did not normalize"
rm -rf "$tmpd2"
tmpd3=$(mktemp -d)
( cd "$tmpd3" && bash "$PHPVM" local 8.2.0 >/dev/null 2>&1 && [[ "$(cat .php-version)" == "8.2" ]] )
[[ $? -eq 0 ]] && ok "local 8.2.0 normalizes to 8.2" || fail "local 8.2.0 did not normalize"
rm -rf "$tmpd3"

sep "shell (direct invoke without wrapper, guides to --enable-hook)"
out=$(bash "$PHPVM" shell 8.3 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"enable-hook"* ]] \
    && ok "direct shell invoke points at --enable-hook" || fail "shell direct invoke wrong (rc=${rc}): ${out}"

sep "shim (shell/shim-php)"
SHIM="$(dirname "$PHPVM")/shell/shim-php"
if [[ ! -x "$SHIM" ]]; then
    fail "shim not executable: $SHIM"
else
    ok "shim exists and is executable"

    # no env set: falls back to /usr/bin/php
    out=$(PHPVM_SHELL_VERSION="" PHPVM_AUTO_VERSION="" sh "$SHIM" --version 2>&1); rc=$?
    [[ $rc -eq 0 && "$out" == *"PHP"* ]] \
        && ok "shim with no env falls back to /usr/bin/php" \
        || fail "shim fallback failed (rc=${rc}): ${out}"

    # unknown version: /usr/bin/php9.99 doesn't exist, falls back to /usr/bin/php
    out=$(PHPVM_SHELL_VERSION=9.99 sh "$SHIM" --version 2>&1); rc=$?
    [[ $rc -eq 0 && "$out" == *"PHP"* ]] \
        && ok "shim with unknown version falls back to /usr/bin/php" \
        || fail "shim unknown-version fallback failed (rc=${rc}): ${out}"

    # installed version: shim should exec /usr/bin/phpX.Y directly
    inst_shim=$(update-alternatives --list php 2>/dev/null | grep -oE 'php[0-9]+\.[0-9]+' | head -1 | sed 's/php//')
    if [[ -n "$inst_shim" && -x "/usr/bin/php${inst_shim}" ]]; then
        out=$(PHPVM_SHELL_VERSION="$inst_shim" sh "$SHIM" --version 2>&1); rc=$?
        [[ $rc -eq 0 && "$out" == *"$inst_shim"* ]] \
            && ok "shim pins to installed version ${inst_shim}" \
            || fail "shim version pin failed (rc=${rc}): ${out}"
    else
        ok "shim version-pin test skipped (no versioned binary found)"
    fi
fi

sep "hook prepends shim dir to PATH at position 0"
HOOK_BASH="$(dirname "$PHPVM")/shell/php-auto.bash"
if [[ ! -f "$HOOK_BASH" ]]; then
    fail "bash hook not found: $HOOK_BASH"
else
    # simulate a hostile PATH: shim is present but demoted by /bin in front.
    # use a tmp dir as the hook dir so the test does not depend on /etc/phpvm.
    hook_tmpd=$(mktemp -d)
    mkdir -p "$hook_tmpd/shims"
    cp "$HOOK_BASH" "$hook_tmpd/php-auto.bash"
    : > "$hook_tmpd/shims/php"; chmod +x "$hook_tmpd/shims/php"
    out=$(bash -c "
        export PATH=\"/bin:${hook_tmpd}/shims:/usr/local/bin:/usr/bin:/bin\"
        source \"${hook_tmpd}/php-auto.bash\"
        echo \"\$PATH\"
    ")
    case "$out" in
        "${hook_tmpd}/shims:"*)
            ok "hook forces shim dir to PATH position 0 even when already present later" ;;
        *)
            fail "hook did not move shim to position 0: ${out}" ;;
    esac

    # idempotence: sourcing twice must not duplicate the shim entry
    out=$(bash -c "
        export PATH=\"/bin:/usr/bin\"
        source \"${hook_tmpd}/php-auto.bash\"
        source \"${hook_tmpd}/php-auto.bash\"
        source \"${hook_tmpd}/php-auto.bash\"
        echo \"\$PATH\"
    ")
    count=$(echo "$out" | tr ':' '\n' | grep -c "^${hook_tmpd}/shims$")
    [[ "$count" -eq 1 ]] \
        && ok "hook is idempotent on re-source (shim dir appears once)" \
        || fail "hook duplicated shim dir on re-source (count=${count}): ${out}"

    rm -rf "$hook_tmpd"
fi

sep "bash version guard"
guard=$(grep -c "BASH_VERSINFO" "$PHPVM") 2>/dev/null || guard=0
[[ "$guard" -ge 1 ]] \
    && ok "bash version guard present" || fail "bash version guard missing"

sep "mapfile present"
grep -q "mapfile" "$PHPVM" \
    && ok "mapfile used (bash 4.0+)" || ok "mapfile not used"

sep "local -n present"
grep -q "local -n" "$PHPVM" \
    && ok "local -n used (bash 4.3+ required)" || ok "local -n not used"

sep "update-alternatives available"
command -v update-alternatives &>/dev/null \
    && ok "update-alternatives found" || fail "update-alternatives missing"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]
