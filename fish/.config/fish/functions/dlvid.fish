function dlvid
    set -l url ""
    set -l mp3 false
    set -l download_dir "$HOME/Downloads"

    # Parse args
    for arg in $argv
        switch $arg
            case -m --mp3
                set mp3 true
            case '*'
                set url $arg
        end
    end

    if test -z "$url"
        echo "Usage: dlvid [-m|--mp3] <url>"
        return 1
    end

    if not command -q yt-dlp
        echo "Error: yt-dlp not installed"
        return 1
    end
    if not command -q wl-copy
        echo "Error: wl-copy not installed (install wl-clipboard)"
        return 1
    end

    mkdir -p $download_dir

    if test $mp3 = true
        if not command -q ffmpeg
            echo "Error: ffmpeg not installed (required for mp3 conversion)"
            return 1
        end
        set -l format_args -f bestaudio --extract-audio --audio-format mp3 --audio-quality 0
    else
        set -l format_args -f "best[ext=mp4]/best"
    end

    # Unique file to capture the final path, so concurrent downloads don't clash
    set -l tmp (mktemp)

    yt-dlp $format_args \
        -o "$download_dir/%(title)s.%(ext)s" \
        --no-playlist \
        --newline \
        --print after_move:filepath \
        "$url" | awk -v outf="$tmp" '
        /^\[download\].*[0-9]\.[0-9]+%/ {
            # Parse: [download]  42.3% of ~  12.34MiB at  1.23MiB/s ETA 00:05
            line = $0
            pct = line
            sub(/^.*\[download\][[:space:]]*/, "", pct)
            sub(/%.*/, "", pct)

            speed = "--"
            if (match(line, /at[[:space:]]+[^[:space:]]+/)) {
                speed = substr(line, RSTART, RLENGTH)
                sub(/at[[:space:]]+/, "", speed)
            }
            eta = "--"
            if (match(line, /ETA[[:space:]]+[^[:space:]]+/)) {
                eta = substr(line, RSTART, RLENGTH)
                sub(/ETA[[:space:]]+/, "", eta)
            }

            p = int(pct)
            filled = int(p * 40 / 100)
            bar = ""
            for (i = 0; i < filled; i++)   bar = bar "█"
            for (i = filled; i < 40; i++)  bar = bar "░"
            printf "\r  %s %3d%%  %s  ETA %s   ", bar, p, speed, eta
            fflush()
            next
        }
        /^\[download\] 100%/ {
            bar = ""
            for (i = 0; i < 40; i++) bar = bar "█"
            printf "\r  %s 100%%  done             \n", bar
            fflush()
            next
        }
        # Last line printed by --print after_move:filepath
        /^\// { print > outf; next }
        '

    set -l filepath (cat $tmp 2>/dev/null)
    rm -f $tmp

    if test -n "$filepath" -a -f "$filepath"
        echo "file://$filepath" | wl-copy --type text/uri-list
        if test $mp3 = true
            echo "✓ Downloaded (mp3): $filepath"
        else
            echo "✓ Downloaded: $filepath"
        end
        echo "✓ Copied to clipboard"
    else
        echo "✗ Download failed"
        return 1
    end
end
