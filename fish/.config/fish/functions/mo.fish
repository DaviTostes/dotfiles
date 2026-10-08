function mo --description "Interactive disk cleanup / system maintenance menu"
    # ── palette (matches the quickshell Theme) ──────────────────────────────
    set -l fg (set_color d3d9e0) # accent
    set -l dim (set_color 5c6470) # muted
    set -l mid (set_color 8b95a3) # secondary
    set -l ok (set_color 7fb069) # green
    set -l warn (set_color d9b061) # yellow
    set -l err (set_color d16b6b) # red
    set -l b (set_color -o)
    set -l n (set_color normal)

    # fzf is used when we actually have a terminal to draw in
    set -g __mo_use_fzf false
    if command -q fzf; and test -t 1
        set -g __mo_use_fzf true
    end

    # ── main loop ───────────────────────────────────────────────────────────
    while true
        # live stats for the menu (kept cheap; docker is probed with a timeout)
        set -l cache_size (du -sh ~/.cache 2>/dev/null | cut -f1)
        test -z "$cache_size"; and set cache_size "?"
        set -l journal_size (journalctl --disk-usage 2>/dev/null | string match -r 'up ([0-9.]+[A-Za-z]*)' | tail -1)
        test -z "$journal_size"; and set journal_size "?"
        set -l orphan_count (pacman -Qtdq 2>/dev/null | count)
        set -l disk (df -h / 2>/dev/null | awk 'NR==2 {print $3" / "$2"  ("$5")"}')
        set -l docker_state down
        if command -q docker; and timeout 1 docker info >/dev/null 2>&1
            set docker_state up
        end
        if not command -q docker
            set docker_state "not installed"
        end

        set -l orphan_word orphans
        if test "$orphan_count" = 1
            set orphan_word orphan
        end

        set -l header (string join \n \
            "Disk: $disk" \
            "Cache: ~/.cache $cache_size    Journal: $journal_size" \
            "System: $orphan_count $orphan_word    Docker: $docker_state")

        set -l entries \
            "1|  1)  Clean package cache         (keep the 3 newest versions)" \
            "2|  2)  Remove orphan packages       ($orphan_count found)" \
            "3|  3)  Clean user cache             (~/.cache, $cache_size)" \
            "4|  4)  Clean journal logs           (> 30 days, $journal_size)" \
            "5|  5)  Find large files             (top dirs + files > 1 GiB)" \
            "6|  6)  Analyze disk                 (ncdu)" \
            "7|  7)  Clean Docker                 (unused images/containers/volumes)" \
            "0|  0)  Clean dev caches             (go, npm, bun, cargo, yay)" \
            "8|  8)  Clean everything             (all except dev caches)" \
            "9|  9)  System update                (yay -Syu)" \
            "r|  r)  Refresh" \
            "q|  q)  Quit"

        command clear

        set -l sel (__mo_menu "$header" $entries)
        set -l menu_status $status
        if test $menu_status -ne 0
            command clear
            return 0
        end
        test (count $sel) -eq 0; and continue

        set -l acted false
        set -l quit false

        for tok in $sel
            switch $tok
                case 1
                    command clear
                    echo "  $b$fg== Package cache ==$n"
                    echo
                    set -l before (__mo_root du -sh /var/cache/pacman/pkg 2>/dev/null | cut -f1)
                    echo "  Current pacman cache: $before"
                    echo

                    # stale partial downloads block pacman/yay cleaning
                    __mo_root find /var/cache/pacman/pkg -maxdepth 1 -name 'download-*' -exec rm -rf {} + 2>/dev/null

                    if command -q paccache
                        __mo_root paccache -r # keep the 3 newest of installed
                        __mo_root paccache -ruk0 # drop everything for uninstalled
                    else
                        __mo_root pacman -Sc --noconfirm
                    end

                    if test -d ~/.cache/yay
                        rm -rf ~/.cache/yay
                        echo "  Removed yay build cache."
                    end

                    set -l after (__mo_root du -sh /var/cache/pacman/pkg 2>/dev/null | cut -f1)
                    echo
                    echo "  $ok✓$n Cache: $before -> $after"
                    set acted true

                case 2
                    command clear
                    echo "  $b$fg== Orphan packages ==$n"
                    echo

                    set -l orphans (pacman -Qtdq 2>/dev/null)
                    if test (count $orphans) -gt 0
                        pacman -Qdt
                        echo
                        if __mo_confirm "Remove these packages?"
                            if command -q yay
                                yay -Rns --noconfirm $orphans # yay must not run as root
                            else
                                __mo_root pacman -Rns --noconfirm $orphans
                            end
                            set acted true
                        else
                            echo "  Skipped."
                        end
                    else
                        echo "  $dim No orphan packages.$n"
                    end

                case 3
                    command clear
                    echo "  $b$fg== User cache ==$n"
                    echo
                    echo "  Current cache size: $cache_size"
                    echo
                    if __mo_confirm "Clean ~/.cache?"
                        find ~/.cache -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
                        echo "  $ok✓$n User cache cleaned."
                        set acted true
                    else
                        echo "  Skipped."
                    end

                case 4
                    command clear
                    echo "  $b$fg== Journal logs ==$n"
                    echo
                    journalctl --disk-usage
                    echo
                    if __mo_confirm "Remove logs older than 30 days?"
                        __mo_root journalctl --vacuum-time=30d
                        set acted true
                    else
                        echo "  Skipped."
                    end

                case 5
                    command clear
                    echo "  $b$fg== Largest directories and files ==$n"
                    echo "  $dim Scanning...$n"
                    echo
                    echo "  $fg Top directories under /$n"
                    __mo_root du -xh -d 1 / 2>/dev/null | sort -rh | head -15
                    echo
                    echo "  $fg Files larger than 1 GiB$n"
                    __mo_root find / -xdev -type f -size +1G -printf '%s\t%p\n' 2>/dev/null \
                        | sort -rn | head -15 | while read -l size path
                        printf '  %8s  %s\n' (__mo_human $size) $path
                    end
                    set acted true

                case 6
                    if command -q ncdu
                        ncdu /
                    else
                        command clear
                        echo "  ncdu is not installed."
                        echo
                        if __mo_confirm "Install ncdu?"
                            yay -S --noconfirm ncdu
                        end
                    end
                    set acted true

                case 7
                    command clear
                    echo "  $b$fg== Docker ==$n"
                    echo
                    if not command -q docker
                        echo "  Docker is not installed."
                    else if not timeout 1 docker info >/dev/null 2>&1
                        echo "  $warn The Docker daemon is not running.$n"
                    else
                        docker system df
                        echo
                        if __mo_confirm "Run 'docker system prune'?"
                            docker system prune -f
                            if __mo_confirm "Also remove ALL unused images and volumes (-a --volumes)?"
                                docker system prune -af --volumes
                            end
                            set acted true
                        else
                            echo "  Skipped."
                        end
                    end
                    set acted true

                case 0
                    __mo_dev_caches
                    set acted true

                case 8
                    command clear
                    echo "  $b$fg== Full cleanup ==$n"
                    echo
                    if __mo_confirm "Run full cleanup (cache, orphans, ~/.cache, journals)?"
                        echo
                        echo "  $b== Package cache ==$n"
                        __mo_root find /var/cache/pacman/pkg -maxdepth 1 -name 'download-*' -exec rm -rf {} + 2>/dev/null
                        if command -q paccache
                            __mo_root paccache -r
                            __mo_root paccache -ruk0
                        else
                            __mo_root pacman -Sc --noconfirm
                        end
                        test -d ~/.cache/yay; and rm -rf ~/.cache/yay

                        echo
                        echo "  $b== Orphan packages ==$n"
                        set -l orphans (pacman -Qtdq 2>/dev/null)
                        if test (count $orphans) -gt 0
                            pacman -Qdt
                            if command -q yay
                                yay -Rns --noconfirm $orphans
                            else
                                __mo_root pacman -Rns --noconfirm $orphans
                            end
                        else
                            echo "  No orphan packages."
                        end

                        echo
                        echo "  $b== User cache ==$n"
                        find ~/.cache -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
                        echo "  User cache cleaned."

                        echo
                        echo "  $b== Journal logs ==$n"
                        __mo_root journalctl --vacuum-time=30d

                        if command -q docker; and timeout 1 docker info >/dev/null 2>&1
                            echo
                            if __mo_confirm "Also prune Docker?"
                                docker system prune -f
                                if __mo_confirm "Remove ALL unused images and volumes too?"
                                    docker system prune -af --volumes
                                end
                            end
                        end

                        echo
                        echo "  $ok✓$n Cleanup complete."
                        set acted true
                    else
                        echo "  Skipped."
                    end

                case 9
                    command clear
                    echo "  $b$fg== System update ==$n"
                    echo
                    if command -q yay
                        yay -Syu
                    else
                        __mo_root pacman -Syu
                    end
                    set acted true

                case q Q
                    command clear
                    set quit true

                case r R ''
                    # just redraw

                case '*'
                    echo
                    echo "  $err Invalid option: '$tok'$n"
                    sleep 1
            end

            if $quit
                break
            end
        end

        if $quit
            return 0
        end

        if $acted
            __mo_pause
        end
    end
end

# ── actions ─────────────────────────────────────────────────────────────────

function __mo_dev_caches --description "mo: clean language/package-manager build caches"
    set -l gocache (go env GOCACHE 2>/dev/null); or set gocache ~/.cache/go-build
    set -l gomodcache (go env GOMODCACHE 2>/dev/null); or set gomodcache ~/go/pkg/mod
    set -l bun_cache ~/.bun/install/cache

    set -l entries
    test -d "$gocache"; and set -a entries "gobuild|  go build cache        "(__mo_size "$gocache")"    (safe, rebuilds)"
    test -d "$gomodcache"; and set -a entries "gomod|  go module cache       "(__mo_size "$gomodcache")"    (re-downloads modules!)"
    test -d ~/.npm; and set -a entries "npm|  npm cache             "(__mo_size ~/.npm)
    test -d "$bun_cache"; and set -a entries "bun|  bun cache             "(__mo_size "$bun_cache")
    test -d ~/.cargo/registry; and set -a entries "cargo|  cargo registry        "(__mo_size ~/.cargo/registry)
    test -d ~/.cache/yay; and set -a entries "yay|  yay build cache       "(__mo_size ~/.cache/yay)

    command clear
    echo "  $b$fg== Dev caches ==$n"
    echo

    if test (count $entries) -eq 0
        echo "  $dim Nothing to clean.$n"
        return 0
    end

    set -l sel (__mo_menu "Select caches to clean (Tab = multi-select)" $entries)
    set -l st $status
    if test $st -ne 0; or test (count $sel) -eq 0
        echo "  Skipped."
        return 0
    end

    echo
    if not __mo_confirm "Clean the selected "(__mo_count_label $sel)"?"
        echo "  Skipped."
        return 0
    end

    echo
    for id in $sel
        switch $id
            case gobuild
                if command -q go
                    go clean -cache
                else
                    rm -rf "$gocache"
                end
            case gomod
                if command -q go
                    go clean -modcache
                else
                    rm -rf "$gomodcache"
                end
            case npm
                if command -q npm
                    npm cache clean --force >/dev/null 2>&1
                else
                    rm -rf ~/.npm
                end
            case bun
                if command -q bun
                    bun pm cache rm >/dev/null 2>&1
                else
                    rm -rf "$bun_cache"
                end
            case cargo
                rm -rf ~/.cargo/registry/cache ~/.cargo/registry/src
            case yay
                rm -rf ~/.cache/yay
        end
        echo "  $ok✓$n cleaned $id"
    end
end

# ── helpers ─────────────────────────────────────────────────────────────────

function __mo_menu --description "mo: pick one or more entries (fzf, numbered fallback)" --argument-names header
    # remaining arguments are "id|display" lines
    set -l lines $argv[2..-1]
    test (count $lines) -eq 0; and return 0

    if test "$__mo_use_fzf" = true
        set -l out (printf '%s\n' $lines | fzf \
            --multi --cycle \
            --delimiter='|' --with-nth=2.. \
            --reverse --height=~90% --border=rounded --info=inline \
            --prompt='  mo > ' --pointer='▶' --marker='✓' \
            --header="$header" --header-first \
            --color='fg:#a9afb8,bg:#161719,hl:#d3d9e0,fg+:#d3d9e0,bg+:#282c33,hl+:#d3d9e0,info:#5c6470,prompt:#8b95a3,pointer:#d3d9e0,marker:#d3d9e0,spinner:#8b95a3,header:#5c6470,border:#282a2e')
        set -l st $status
        for line in $out
            set -l parts (string split -m1 '|' -- $line)
            test (count $parts) -ge 1; and echo $parts[1]
        end
        return $st
    end

    # numbered fallback (no fzf / not a tty)
    set -l n (count $lines)
    echo >&2
    test -n "$header"; and printf '  %s\n' "$header" >&2
    echo >&2
    for i in (seq $n)
        set -l parts (string split -m1 '|' -- $lines[$i])
        printf '  %2d) %s\n' $i "$parts[2]" >&2
    end
    echo >&2
    read -P "  Select: " pick
    or return 130

    for t in (string split -n ' ' -- (string replace -a ',' ' ' -- $pick))
        if string match -qr '^[0-9]+$' -- $t; and test $t -ge 1 -a $t -le $n
            set -l parts (string split -m1 '|' -- $lines[$t])
            echo $parts[1]
        else
            for line in $lines
                set -l parts (string split -m1 '|' -- $line)
                if test "$parts[1]" = "$t"
                    echo $t
                    break
                end
            end
        end
    end
end

function __mo_pause --description "mo: wait for Enter"
    echo
    read -P "  Press Enter to continue..." -l _mo_ignore
    or true
end

function __mo_confirm --description "mo: yes/no prompt" --argument-names prompt
    read -P "  $prompt [y/N] " -l _mo_ans
    or return 1
    string match -qi y -- $_mo_ans
end

function __mo_root --description "mo: run a command with root privileges when needed"
    if test (id -u) -eq 0
        command $argv
    else
        sudo $argv
    end
end

function __mo_human --description "mo: format a byte count for humans" --argument-names bytes
    if command -q numfmt
        numfmt --to=iec-i --suffix=B $bytes
    else
        echo $bytes"B"
    end
end

function __mo_size --description "mo: human-readable size of a path" --argument-names path
    du -sh "$path" 2>/dev/null | cut -f1
end

function __mo_count_label --description "mo: 'N cache(s)' label" --argument-names sel
    set -l c (count $sel)
    if test $c -eq 1
        echo "1 cache"
    else
        echo "$c caches"
    end
end
