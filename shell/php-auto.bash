# bash auto switch hook
# Add to ~/.bashrc:
#   source /etc/phpvm/php-auto.bash    (system install)
#   source ~/.phpvm/php-auto.bash      (user install)

_php_switcher_auto() {
    command -v phpvm &>/dev/null || return
    phpvm --auto --quiet 2>/dev/null
}

_php_switcher_prompt() {
    if [[ "$PWD" != "$_PHPVM_LAST_PWD" ]]; then
        _PHPVM_LAST_PWD="$PWD"
        _php_switcher_auto
    fi
}

case ";${PROMPT_COMMAND:-};" in
    *";_php_switcher_prompt;"*) ;;
    *) PROMPT_COMMAND="_php_switcher_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac

_php_switcher_auto
_PHPVM_LAST_PWD="$PWD"
