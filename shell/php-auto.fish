# fish hook: phpvm shell integration + auto-switch on cd
# Copy to ~/.config/fish/conf.d/phpvm.fish
# or add to ~/.config/fish/config.fish:
#   source /etc/phpvm/php-auto.fish    (system install)
#   source ~/.phpvm/php-auto.fish      (user install)

# locate this hook's own directory so we can find the shim dir next to it
set -l _phpvm_hook_dir (dirname (status -f))

# put the shim dir on PATH once, ahead of /usr/bin, so `php` hits our shim
if test -d "$_phpvm_hook_dir/shims"
    if not contains -- "$_phpvm_hook_dir/shims" $PATH
        set -gx PATH "$_phpvm_hook_dir/shims" $PATH
    end
end

# wrapper: `phpvm shell` and the bare TUI must change the current shell, so they
# pipe shell code to `source`; everything else goes straight to the binary.
# `command -s` resolves the real binary, bypassing this function.
function phpvm
    set -l phpvm_bin (command -s phpvm)
    if test -z "$phpvm_bin"
        echo "phpvm: binary not found in PATH" >&2
        return 1
    end
    if test (count $argv) -eq 0
        env PHPVM_SHELL_SYNTAX=fish $phpvm_bin | source
        return
    end
    switch $argv[1]
        case shell
            $phpvm_bin sh-shell $argv[2..-1] --fish | source
        case '*'
            $phpvm_bin $argv
    end
end

# cd-hook: reflect the project's PHP into PHPVM_AUTO_VERSION (the shim reads it).
# No sudo, no global switch. An explicit `phpvm shell` pin wins, so skip then.
function _php_switcher_auto --on-variable PWD
    set -l phpvm_bin (command -s phpvm)
    test -z "$phpvm_bin"; and return
    set -q PHPVM_SHELL_VERSION; and return
    set -l v ($phpvm_bin --auto --print 2>/dev/null)
    if test -n "$v"
        set -gx PHPVM_AUTO_VERSION "$v"
    else
        set -e PHPVM_AUTO_VERSION
    end
end

_php_switcher_auto
