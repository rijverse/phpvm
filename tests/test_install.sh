#!/bin/bash
# install.sh + uninstall.sh tests. Covers the rc-resolution regression
# (the prior $HOME-under-sudo bug) and the hook write/cleanup round trip.
# Usage: bash tests/test_install.sh [path/to/install.sh]

set -uo pipefail

INSTALLER="${1:-$(dirname "$0")/../install.sh}"
INSTALLER="$(realpath "$INSTALLER")"
ROOT="$(dirname "$INSTALLER")"
UNINSTALLER="${ROOT}/uninstall.sh"

pass=0
fail=0

ok()    { echo "  PASS  $1"; pass=$(( pass + 1 )); }
fail()  { echo "  FAIL  $1"; fail=$(( fail + 1 )); }
sep()   { echo ""; echo "--- $1 ---"; }

sep "environment"
echo "  installer    ${INSTALLER}"
echo "  uninstaller  ${UNINSTALLER}"
echo "  bash         ${BASH_VERSION}"

sep "static: no bare \$HOME rc-file references in install.sh"
# the prior bug appended to \$HOME/.bashrc directly, which under sudo points at
# /root. all per-user rc paths must go through USER_HOME.
offenders=$(grep -nE 'RC="\$HOME/\.(bashrc|zshrc)|RC="\$HOME/\.config/fish' "$INSTALLER" || true)
if [[ -z "$offenders" ]]; then
    ok "no bare \$HOME rc-file assignments"
else
    fail "found bare \$HOME rc-file references (sudo regression):"$'\n'"${offenders}"
fi

sep "static: USER_HOME / USER_SHELL defined"
if grep -q '^USER_HOME=' "$INSTALLER" \
        || grep -q 'USER_HOME=$(getent' "$INSTALLER"; then
    ok "USER_HOME resolution present"
else
    fail "USER_HOME not defined in install.sh"
fi
if grep -q 'USER_SHELL=' "$INSTALLER"; then
    ok "USER_SHELL resolution present"
else
    fail "USER_SHELL not defined in install.sh"
fi

sep "static: upgrade mode recovers a missing hook"
# previously, --upgrade silently skipped writing the hook even if it was
# absent. that path now writes the hook so users who missed it on first
# install (e.g. the prior \$HOME bug) recover automatically.
if grep -q 'Hook missing' "$INSTALLER"; then
    ok "upgrade-mode hook recovery branch present"
else
    fail "upgrade mode does not write the hook when missing"
fi

# behavioral: run install.sh in a fake \$HOME and verify the hook lands there.
# setsid drops the controlling terminal so INTERACTIVE auto-detects to 0; the
# script then defaults to "install both", skips sudoers, skips autostart.
run_install() {
    local home="$1"
    shift
    env -i HOME="$home" SHELL=/bin/bash USER="${USER:-tester}" \
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        setsid bash "$INSTALLER" "$@" < /dev/null
}

run_uninstall() {
    local home="$1"
    env -i HOME="$home" SHELL=/bin/bash USER="${USER:-tester}" \
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        setsid bash "$UNINSTALLER" < /dev/null
}

sep "behavioral: user install writes hook to \$HOME/.bashrc"
tmpd=$(mktemp -d)
log="${tmpd}/install.log"
if ! run_install "$tmpd" >"$log" 2>&1; then
    fail "install.sh exited non-zero (last lines):"$'\n'"$(tail -8 "$log")"
elif grep -qF "source ${tmpd}/.phpvm/php-auto.bash" "${tmpd}/.bashrc" 2>/dev/null; then
    ok "hook source line written to fake-HOME bashrc"
else
    fail "hook line missing in ${tmpd}/.bashrc"$'\n'"  log tail: $(tail -8 "$log")"$'\n'"  bashrc: $(cat "${tmpd}/.bashrc" 2>/dev/null || echo MISSING)"
fi

sep "behavioral: hook is written to invoking \$HOME only (no leakage)"
# install.sh ran with HOME=$tmpd. Nothing should have been written outside it
# at user-rc paths. We can only check the obvious siblings.
leaked=0
for p in /root/.bashrc "$HOME/.bashrc.phpvm-test-leak"; do
    [[ "$p" == "$tmpd/.bashrc" ]] && continue
    if [[ -f "$p" ]] && grep -qF "${tmpd}/.phpvm/php-auto.bash" "$p" 2>/dev/null; then
        leaked=1
        fail "hook line leaked into ${p}"
    fi
done
(( leaked )) || ok "no leakage to other rc files"

sep "behavioral: re-running install.sh does not duplicate the hook line"
run_install "$tmpd" >>"$log" 2>&1 || true
count=$(grep -cF "source ${tmpd}/.phpvm/php-auto.bash" "${tmpd}/.bashrc" 2>/dev/null || echo 0)
[[ "$count" -eq 1 ]] \
    && ok "hook source line appears exactly once after re-run" \
    || fail "hook source line appears ${count} times after re-run"

sep "behavioral: --upgrade rewrites the hook when missing"
# wipe the hook line, run --upgrade, expect it back.
sed -i \
    -e '/^# phpvm auto-switch$/d' \
    -e "\#source ${tmpd}/.phpvm/php-auto\\.bash#d" \
    "${tmpd}/.bashrc"
if grep -qF "source ${tmpd}/.phpvm/php-auto.bash" "${tmpd}/.bashrc" 2>/dev/null; then
    fail "test setup failed: hook line still present after wipe"
else
    run_install "$tmpd" --upgrade >>"$log" 2>&1 || true
    if grep -qF "source ${tmpd}/.phpvm/php-auto.bash" "${tmpd}/.bashrc" 2>/dev/null; then
        ok "--upgrade restored a missing hook line"
    else
        fail "--upgrade did not restore the missing hook line"
    fi
fi

sep "behavioral: uninstall removes the hook + leaves a backup"
ulog="${tmpd}/uninstall.log"
run_uninstall "$tmpd" >"$ulog" 2>&1 || true
if grep -qF "source ${tmpd}/.phpvm/php-auto.bash" "${tmpd}/.bashrc" 2>/dev/null; then
    fail "uninstall did not remove the hook line"
else
    ok "uninstall removed the hook line"
fi
[[ -f "${tmpd}/.bashrc.phpvm-backup" ]] \
    && ok "uninstall left a .phpvm-backup of bashrc" \
    || fail "uninstall did not leave a backup file"
[[ -d "${tmpd}/.phpvm" ]] \
    && fail "uninstall left ${tmpd}/.phpvm behind" \
    || ok "uninstall removed the per-user hook dir"

rm -rf "$tmpd"

# zsh hook checks. zsh-native syntax is hard to validate without running zsh,
# so we do a focused source-level check that the file is NOT a bash copy, plus
# a runtime smoke test if zsh is available.
sep "static: zsh hook is not a bash copy"
ZSH_HOOK="${ROOT}/shell/php-auto.zsh"
if [[ ! -f "$ZSH_HOOK" ]]; then
    fail "zsh hook missing at ${ZSH_HOOK}"
else
    if grep -q 'BASH_SOURCE' "$ZSH_HOOK"; then
        fail "zsh hook still references BASH_SOURCE (bash-only, broken in zsh)"
    else
        ok "no BASH_SOURCE in zsh hook"
    fi
    if grep -q 'PROMPT_COMMAND' "$ZSH_HOOK"; then
        fail "zsh hook still uses PROMPT_COMMAND (bash-only; zsh wants chpwd_functions)"
    else
        ok "no PROMPT_COMMAND in zsh hook"
    fi
    # any of the three zsh-native cd hooks is acceptable
    if grep -qE 'chpwd_functions|add-zsh-hook|precmd_functions' "$ZSH_HOOK"; then
        ok "zsh hook uses a zsh-native cd hook"
    else
        fail "zsh hook does not register a chpwd / precmd / add-zsh-hook callback"
    fi
    # zsh-native script-self-path. Either ${(%):-%x} or %N, or $0 inside a sourced file.
    if grep -qE '\$\{\(%\):-%[xN]\}|\$\{0:A:h\}' "$ZSH_HOOK"; then
        ok "zsh hook uses a zsh-native self-path expansion"
    else
        fail "zsh hook does not derive its directory via zsh-native expansion"
    fi
fi

sep "runtime: zsh hook smoke test"
if ! command -v zsh >/dev/null 2>&1; then
    echo "  SKIP  zsh not installed (apt install zsh to enable this test)"
else
    hook_tmpd=$(mktemp -d)
    mkdir -p "${hook_tmpd}/shims"
    cp "$ZSH_HOOK" "${hook_tmpd}/php-auto.zsh"
    : > "${hook_tmpd}/shims/php"; chmod +x "${hook_tmpd}/shims/php"

    out=$(zsh -c "
        export PATH='/usr/bin:/bin'
        source '${hook_tmpd}/php-auto.zsh'
        echo PATH=\$PATH
        echo HOOKS=\${chpwd_functions[@]:-none}
        echo PHPVM_FUNC=\$(typeset -f phpvm >/dev/null && echo yes || echo no)
    " 2>&1)
    if [[ "$out" == *"PATH=${hook_tmpd}/shims:"* ]]; then
        ok "zsh hook prepends shim dir to PATH"
    else
        fail "zsh hook did not prepend shim dir: ${out}"
    fi
    if [[ "$out" == *"HOOKS="*"_php_switcher_auto"* ]]; then
        ok "zsh hook registers _php_switcher_auto on chpwd"
    else
        fail "zsh hook did not register chpwd handler: ${out}"
    fi
    if [[ "$out" == *"PHPVM_FUNC=yes"* ]]; then
        ok "zsh hook defines phpvm() wrapper function"
    else
        fail "zsh hook did not define phpvm() function: ${out}"
    fi
    rm -rf "$hook_tmpd"
fi

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]
