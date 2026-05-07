# PHP Switcher - Bash auto-switch hook
# Add to ~/.bashrc:
#   source /etc/phpvm/php-auto.bash

_php_switcher_auto() {
    command -v phpvm &>/dev/null || return
    phpvm --auto --quiet 2>/dev/null
}

cd() {
    builtin cd "$@" && _php_switcher_auto
}

_php_switcher_auto
