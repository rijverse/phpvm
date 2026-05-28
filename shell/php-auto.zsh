# zsh hook: phpvm shell integration + auto-switch on cd
# Add to ~/.zshrc:
#   source /etc/phpvm/php-auto.zsh    (system install)
#   source ~/.phpvm/php-auto.zsh      (user install)

# locate this hook's own directory so we can find the shim dir next to it.
# ${(%):-%x} expands to the absolute path of the file currently being sourced
# (zsh prompt-expansion: %x is the source-file name). :A canonicalises and :h
# strips the basename, leaving the directory.
_PHPVM_HOOK_DIR="${${(%):-%x}:A:h}"

# put the shim dir at the FRONT of PATH so `php` hits our shim. Some setups
# (login shells that re-prepend /bin via /etc/environment, snap profile.d
# scripts, IDE-injected PATH) demote the shim if we only check "is it anywhere
# in PATH". Force position 0, stripping any stale copies first so PATH does
# not grow on re-source.
if [ -d "${_PHPVM_HOOK_DIR}/shims" ]; then
    case ":${PATH}:" in
        ":${_PHPVM_HOOK_DIR}/shims:"*) ;;
        *)
            _phpvm_p=":${PATH}:"
            _phpvm_p="${_phpvm_p//:${_PHPVM_HOOK_DIR}\/shims:/:}"
            _phpvm_p="${_phpvm_p#:}"
            _phpvm_p="${_phpvm_p%:}"
            export PATH="${_PHPVM_HOOK_DIR}/shims${_phpvm_p:+:${_phpvm_p}}"
            unset _phpvm_p
            ;;
    esac
fi

# wrapper: `phpvm shell` and the bare TUI must change the current shell, so they
# run through eval; everything else goes straight to the binary.
phpvm() {
    case "${1:-}" in
        shell)
            shift
            eval "$(command phpvm sh-shell "$@")"
            ;;
        "")
            eval "$(command phpvm)"
            ;;
        *)
            command phpvm "$@"
            ;;
    esac
}

# cd-hook: reflect the project's PHP into PHPVM_AUTO_VERSION (the shim reads it).
# No sudo, no global switch. An explicit `phpvm shell` pin wins, so skip then.
_php_switcher_auto() {
    command -v phpvm >/dev/null 2>&1 || return
    [ -n "${PHPVM_SHELL_VERSION:-}" ] && return
    local v
    v="$(command phpvm --auto --print 2>/dev/null)"
    if [ -n "$v" ]; then
        export PHPVM_AUTO_VERSION="$v"
    else
        unset PHPVM_AUTO_VERSION
    fi
}

# zsh runs chpwd_functions whenever PWD changes. Register idempotently so
# re-sourcing the hook does not add duplicates.
autoload -Uz add-zsh-hook 2>/dev/null
if typeset -f add-zsh-hook >/dev/null 2>&1; then
    add-zsh-hook -d chpwd _php_switcher_auto 2>/dev/null
    add-zsh-hook chpwd _php_switcher_auto
else
    # fallback for older zsh without add-zsh-hook
    typeset -ga chpwd_functions
    if [[ -z "${chpwd_functions[(r)_php_switcher_auto]}" ]]; then
        chpwd_functions+=(_php_switcher_auto)
    fi
fi

_php_switcher_auto
