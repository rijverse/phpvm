# zsh hook: phpvm shell integration + auto-switch on cd
# Add to ~/.zshrc:
#   source /etc/phpvm/php-auto.zsh     (system install)
#   source ~/.phpvm/php-auto.zsh       (user install)

# locate this hook's own directory so we can find the shim dir next to it
_PHPVM_HOOK_DIR="${${(%):-%x}:A:h}"

# put the shim dir on PATH once, ahead of /usr/bin, so `php` hits our shim
case ":${PATH}:" in
    *":${_PHPVM_HOOK_DIR}/shims:"*) ;;
    *) [ -d "${_PHPVM_HOOK_DIR}/shims" ] && export PATH="${_PHPVM_HOOK_DIR}/shims:${PATH}" ;;
esac

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

autoload -U add-zsh-hook

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

add-zsh-hook chpwd _php_switcher_auto

_php_switcher_auto
