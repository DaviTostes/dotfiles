function f --description "Recursively search files for a pattern"
    if test (count $argv) -eq 0; or contains -- -h $argv; or contains -- --help $argv
        echo "Usage: f <pattern> [path]"
        echo "  Recursively search PATH (default: .) for PATTERN."
        echo "  Uses ripgrep when available, otherwise grep."
        return 0
    end

    set -l pattern $argv[1]
    set -l path .
    if test (count $argv) -ge 2
        set path $argv[2]
    end

    if command -q rg
        # ripgrep respects .gitignore and skips binaries; --hidden also searches dotfiles
        rg --color=always --line-number --no-heading --hidden --no-messages -- $pattern $path
        set -l st $status
        if test $st -eq 1
            echo "f: no matches for '$pattern' in $path"
        end
        return $st
    end

    grep -rnI --color=always \
        --exclude-dir=.git --exclude-dir=node_modules \
        -- $pattern $path 2>/dev/null
    set -l st $status
    if test $st -eq 1
        echo "f: no matches for '$pattern' in $path"
    end
    return $st
end
