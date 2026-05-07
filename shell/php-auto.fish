# PHP Switcher - Fish auto-switch hook
# Copy to ~/.config/fish/conf.d/phpvm.fish
# or add to ~/.config/fish/config.fish:
#   source /etc/phpvm/php-auto.fish

function _php_switcher_auto --on-variable PWD
    command -q phpvm || return
    phpvm --auto --quiet 2>/dev/null
end

_php_switcher_auto