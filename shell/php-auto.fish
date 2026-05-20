# fish auto switch hook
# Copy to ~/.config/fish/conf.d/phpvm.fish
# or add to ~/.config/fish/config.fish:
#   source /etc/phpvm/php-auto.fish    (system install)
#   source ~/.phpvm/php-auto.fish      (user install)

function _php_switcher_auto --on-variable PWD
    command -q phpvm || return
    if set -q PHPVM_DEBUG
        phpvm --auto --quiet
    else
        phpvm --auto --quiet 2>/dev/null
    end
end

_php_switcher_auto