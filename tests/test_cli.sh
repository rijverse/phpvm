#!/bin/bash
# CLI compatibility tests — run inside a container or directly on host.
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
# exits 1 when no PHP installed — that's expected, not a crash
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

sep "--set (no version arg — expect usage error, not crash)"
out=$(bash "$PHPVM" --set 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"Usage"* ]] \
    && ok "--set without arg exits non-zero with usage message" || fail "--set without arg behaved unexpectedly (rc=${rc}): ${out}"

sep "unknown subcommand (regression — bare positional must fail)"
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
