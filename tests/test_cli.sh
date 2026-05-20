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
