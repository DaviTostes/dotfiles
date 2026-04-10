function dlvid
    set -l url $argv[1]
    set -l download_dir "$HOME/Downloads"
    
    if test -z "$url"
        echo "Usage: dlvid <url>"
        return 1
    end

    if not command -v yt-dlp >/dev/null
        echo "Error: yt-dlp not installed"
        return 1
    end
    if not command -v wl-copy >/dev/null
        echo "Error: wl-copy not installed (install wl-clipboard)"
        return 1
    end

    mkdir -p $download_dir

    set -l filepath (yt-dlp -f "best[ext=mp4]/best" \
           -o "$download_dir/%(title)s.%(ext)s" \
           --no-playlist \
           --quiet \
           --print after_move:filepath \
           "$url")
    
    if test $status -eq 0 -a -n "$filepath" -a -f "$filepath"
        echo "file://$filepath" | wl-copy --type text/uri-list
        echo "✓ Downloaded: $filepath"
        echo "✓ Copied to clipboard"
    else
        echo "✗ Download failed"
        return 1
    end
end
