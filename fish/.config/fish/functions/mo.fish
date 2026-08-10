function mo
    while true
        command clear

        echo "╭──────────────────────────────╮"
        echo "│        Mole for Linux        │"
        echo "╰──────────────────────────────╯"
        echo
        echo "  1) Clean package cache"
        echo "  2) Remove orphan packages"
        echo "  3) Clean user cache"
        echo "  4) Clean journal logs"
        echo "  5) Find large files"
        echo "  6) Analyze disk"
        echo "  7) Clean Docker"
        echo "  8) Clean everything"
        echo "  9) System update"
        echo "  q) Quit"
        echo

        read -P "Select: " choice
        or break # ctrl-d

        switch $choice
            case 1
                command clear
                echo "== Package cache =="
                echo

                # stale partial downloads: pacman -Sc errors on each
                sudo find /var/cache/pacman/pkg -maxdepth 1 -name 'download-*' -exec rm -rf {} +
                yay -Sc

                echo
                read -P "Press Enter to continue..." dummy

            case 2
                command clear
                echo "== Orphan packages =="
                echo

                set -l orphans (pacman -Qtdq 2>/dev/null)

                if test (count $orphans) -gt 0
                    echo "The following packages are orphaned:"
                    echo
                    pacman -Qdt
                    echo

                    read -P "Remove these packages? [y/N] " confirm

                    if string match -qi y $confirm
                        yay -Rns $orphans
                    end
                else
                    echo "No orphan packages."
                end

                echo
                read -P "Press Enter to continue..." dummy

            case 3
                command clear
                echo "== User cache =="
                echo

                set -l cache_size (du -sh ~/.cache 2>/dev/null | cut -f1)

                echo "Current cache size: $cache_size"
                echo

                read -P "Clean ~/.cache? [y/N] " confirm

                if string match -qi y $confirm
                    rm -rf ~/.cache
                    mkdir -p ~/.cache
                    echo "User cache cleaned."
                else
                    echo "Skipped."
                end

                echo
                read -P "Press Enter to continue..." dummy

            case 4
                command clear
                echo "== Journal logs =="
                echo

                journalctl --disk-usage
                echo

                read -P "Remove logs older than 30 days? [y/N] " confirm

                if string match -qi y $confirm
                    sudo journalctl --vacuum-time=30d
                end

                echo
                read -P "Press Enter to continue..." dummy

            case 5
                command clear
                echo "== Largest files and directories =="
                echo
                echo "Scanning..."
                echo

                sudo du -ahx / 2>/dev/null \
                    | sort -rh \
                    | head -30

                echo
                read -P "Press Enter to continue..." dummy

            case 6
                if command -q ncdu
                    ncdu /
                else
                    command clear
                    echo "ncdu is not installed."
                    echo

                    read -P "Install ncdu? [y/N] " confirm

                    if string match -qi y $confirm
                        yay -S ncdu
                    end

                    echo
                    read -P "Press Enter to continue..." dummy
                end

            case 7
                command clear
                echo "== Docker =="
                echo

                if not command -q docker
                    echo "Docker is not installed."
                    echo
                    read -P "Press Enter to continue..." dummy
                    continue
                end

                docker system df
                echo

                read -P "Run Docker system prune? [y/N] " confirm

                if string match -qi y $confirm
                    docker system prune
                end

                echo
                read -P "Press Enter to continue..." dummy

            case 8
                command clear
                echo "== Full cleanup =="
                echo

                read -P "Run full cleanup? [y/N] " confirm

                if not string match -qi y $confirm
                    continue
                end

                echo
                echo "== Package cache =="
                sudo find /var/cache/pacman/pkg -maxdepth 1 -name 'download-*' -exec rm -rf {} +
                yay -Sc

                echo
                echo "== Orphan packages =="

                set -l orphans (pacman -Qtdq 2>/dev/null)

                if test (count $orphans) -gt 0
                    echo "Removing:"
                    pacman -Qdt
                    echo
                    yay -Rns $orphans
                else
                    echo "No orphan packages."
                end

                echo
                echo "== User cache =="

                rm -rf ~/.cache
                mkdir -p ~/.cache
                echo "User cache cleaned."

                echo
                echo "== Journal logs =="
                sudo journalctl --vacuum-time=30d

                echo
                echo "Cleanup complete."
                echo
                read -P "Press Enter to continue..." dummy

            case 9
                command clear
                echo "== System update =="
                echo

                yay

                echo
                read -P "Press Enter to continue..." dummy

            case q Q
                command clear
                return

            case '*'
                echo
                echo "Invalid option."
                sleep 1
        end
    end
end
