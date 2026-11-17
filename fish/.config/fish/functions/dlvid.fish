function dlvid --description 'Download a video (or its audio) with a live progress bar'
    # Same palette as mo.fish
    set -l fg (set_color d3d9e0)
    set -l dim (set_color 5c6470)
    set -l mid (set_color 8b95a3)
    set -l ok (set_color 7fb069)
    set -l warn (set_color d9b061)
    set -l errc (set_color d16b6b)
    set -l bold (set_color -o)
    set -l n (set_color normal)

    set -l url ""
    set -l mp3 false
    set -l download_dir "$HOME/Downloads"

    # Parse args
    for arg in $argv
        switch $arg
            case -h --help
                printf 'Usage: dlvid [-m|--mp3] <url>\n\n'
                printf '  -m, --mp3   download only the audio and convert it to mp3\n'
                printf '  -h, --help  show this help\n'
                return 0
            case -m --mp3
                set mp3 true
            case '*'
                set url $arg
        end
    end

    if test -z "$url"
        printf '%s✗%s usage: dlvid [-m|--mp3] <url>\n' $errc $n
        return 1
    end

    if not command -q yt-dlp
        printf '%s✗%s yt-dlp not installed\n' $errc $n
        return 1
    end

    if test $mp3 = true; and not command -q ffmpeg
        printf '%s✗%s ffmpeg not installed (required for mp3)\n' $errc $n
        return 1
    end

    # Fancy output only when stdout is a real terminal
    set -l use_color 0
    if test "$TERM" != dumb; and test -t 1
        set use_color 1
    end
    if test $use_color = 0
        set fg ''; set dim ''; set mid ''; set ok ''
        set warn ''; set errc ''; set bold ''; set n ''
    end

    set -l cols 80
    if test $use_color = 1
        set -l c (tput cols 2>/dev/null)
        if string match -qr '^[0-9]+$' -- "$c"
            set cols $c
        else if set -q COLUMNS; and string match -qr '^[0-9]+$' -- "$COLUMNS"
            set cols $COLUMNS
        end
    end
    set -l barw (math "max(14, min(40, $cols - 58))")

    set -l clip 0
    command -q wl-copy; and set clip 1

    mkdir -p "$download_dir"

    set -l tmp (mktemp)
    set -l errfile (mktemp)
    set -l statef (mktemp)
    if test -z "$tmp" -o -z "$errfile" -o -z "$statef"
        rm -f $tmp $errfile $statef
        printf '%s✗%s could not create temporary files\n' $errc $n
        return 1
    end
    printf 'closed\n' > $statef

    set -l format_args
    if test $mp3 = true
        set format_args -f bestaudio/best --extract-audio --audio-format mp3 --audio-quality 0
    else
        set format_args -f 'best[ext=mp4]/best'
    end

    # yt-dlp emits machine-readable lines through the progress template.
    # Fields that are unavailable show up as "NA".
    set -l tmpl 'DLVID|%(progress.status)s|%(progress._percent_str)s|%(progress._downloaded_bytes_str)s|%(progress._total_bytes_str)s|%(progress._total_bytes_estimate_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress._elapsed_str)s|%(progress.filename)s|%(info.resolution)s|%(info.duration_string)s|%(info.title)s'
    set -l pptmpl 'DLVID-PP|%(progress.status)s|%(progress.postprocessor)s'

    set -l blocks '▏' '▎' '▍' '▌' '▋' '▊' '▉' '█'
    set -l t0 (date +%s)
    set -l bar_open 0
    set -l last_file ''
    set -l header_done 0

    # "Fetching info…" is printed without a newline and replaced in place
    # by the title as soon as yt-dlp knows it.
    set -l pending 0
    if test $use_color = 1
        printf '  %s⟳%s %sFetching info…%s' $mid $n $dim $n
        set pending 1
        printf 'pending\n' > $statef
    end

    yt-dlp $format_args \
        --no-playlist \
        --no-colors --no-warnings \
        --progress --newline --progress-delta 0.2 \
        --progress-template "download:$tmpl" \
        --progress-template "postprocess:$pptmpl" \
        --print-to-file "after_move:%(filepath)s" "$tmp" \
        -o "$download_dir/%(title)s.%(ext)s" \
        "$url" 2>"$errfile" | while read -l line
        # ---- post-processing (merge / mp3 conversion / metadata) -----------
        if string match -q 'DLVID-PP|*' -- $line
            set -l pp (string split -m 2 '|' -- $line)
            test "$pp[2]" != started; and continue
            set -l label
            switch "$pp[3]"
                case ExtractAudio
                    set label 'converting audio to mp3'
                case Merger FFmpegMerger VideoRemuxer VideoConvertor
                    set label 'merging streams'
                case Metadata MetadataParser
                    set label 'writing metadata'
                case MoveFiles
                    set label ''
                case '*'
                    set label (string replace -a '_' ' ' -- (string lower -- "$pp[3]"))
            end
            test -z "$label"; and continue

            if test $pending = 1
                printf '\r\e[K'
                set pending 0
                printf 'closed\n' > $statef
            end
            if test $bar_open = 1
                printf '\r\e[K'
                set bar_open 0
                printf 'closed\n' > $statef
            end
            printf '  %s⟳%s %s%s…%s\n' $mid $n $dim $label $n
            continue
        end

        # ---- download progress ---------------------------------------------
        if not string match -q 'DLVID|*' -- $line
            continue
        end
        set -l p (string split -m 12 '|' -- $line)
        for i in 2 3 4 5 6 7 8 9 10 11 12
            set p[$i] (string trim -- "$p[$i]")
        end
        set -l pstate "$p[2]"
        set -l dest "$p[10]"

        # ---- title / metadata (known from the first progress line) ---------
        if test $header_done = 0
            set header_done 1
            if test $pending = 1
                printf '\r\e[K'
                set pending 0
                printf 'closed\n' > $statef
            end

            set -l title "$p[13]"
            string match -qr '^(NA|N/A)?$' -- "$title"; and set title "$url"
            set -l maxw (math "$cols - 6")
            if test (string length -- "$title") -gt $maxw
                set title (string sub -l (math "$maxw - 1") -- "$title")…
            end

            set -l bits
            not string match -qr '^(NA|N/A)?$' -- "$p[12]"; and set -a bits "$p[12]"
            not string match -qr '^(NA|N/A)?$' -- "$p[11]"; and set -a bits "$p[11]"
            test $mp3 = true; and set -a bits mp3
            set -l meta (string join ' · ' $bits)

            printf '  %s▸%s %s%s%s' $fg $n $bold $title $n
            if test -n "$meta"
                printf '  %s· %s%s' $dim $meta $n
            end
            printf '\n'
        end

        set -l fname
        if not string match -qr '^(NA|N/A)?$' -- "$dest"
            set fname (path basename -- $dest)
            set -l maxw (math "$cols - 6")
            if test (string length -- "$fname") -gt $maxw
                set fname (string sub -l (math "$maxw - 1") -- "$fname")…
            end
        end

        # A new file started (single download, or the 2nd half of a merge)
        if test -n "$fname"; and test "$fname" != "$last_file"
            set last_file "$fname"
            if test $pending = 1
                printf '\r\e[K'
                set pending 0
                printf 'closed\n' > $statef
            end
            if test $bar_open = 1
                printf '\r\e[K'
                set bar_open 0
                printf 'closed\n' > $statef
            end
            if test $use_color = 1
                printf '  %s↓%s %s%s%s\n' $mid $n $dim $fname $n
            else
                printf '  → %s\n' $fname
            end
        end

        if test "$pstate" = finished
            if test $bar_open = 1
                printf '\r\e[K'
                set bar_open 0
                printf 'closed\n' > $statef
            end
            if test $use_color = 0
                set -l tot "$p[5]"
                if test "$tot" = NA; or test "$tot" = N/A; or test -z "$tot"
                    set tot "$p[6]"
                end
                if test "$tot" = NA; or test "$tot" = N/A
                    set tot ''
                end
                set -l suffix ''
                test -n "$tot"; and set suffix "  $tot"
                printf '  ✓ %s%s\n' $fname $suffix
            end
            continue
        end

        test "$pstate" != downloading; and continue
        test $use_color = 0; and continue

        if test $pending = 1
            printf '\r\e[K'
            set pending 0
        end
        if test $bar_open = 0
            set bar_open 1
            printf 'open\n' > $statef
        end

        # sizes / speed / eta
        set -l total "$p[5]"
        if test "$total" = NA; or test "$total" = N/A; or test -z "$total"
            set total "$p[6]"
        end
        if test "$total" = NA; or test "$total" = N/A; or test -z "$total"
            set total ''
        end
        set -l got "$p[4]"
        if test "$got" = NA; or test "$got" = N/A
            set got ''
        end
        set -l known 1
        test -z "$total"; and set known 0

        set -l sizeinfo ''
        if test -n "$got"; and test -n "$total"
            set sizeinfo "$got/$total"
        else if test -n "$total"
            set sizeinfo "$total"
        else if test -n "$got"
            set sizeinfo "$got"
        end

        set -l speed ''
        if not string match -qr '^(NA|N/A|Unknown.*)$' -- "$p[7]"
            set speed "$p[7]"
        end
        set -l eta ''
        if not string match -qr '^(NA|N/A|Unknown.*)$' -- "$p[8]"
            set eta "ETA $p[8]"
        end

        set -l suffix ''
        test -n "$sizeinfo"; and set suffix "  $sizeinfo"
        test -n "$speed"; and set suffix "$suffix  $speed"
        test -n "$eta"; and set suffix "$suffix  $eta"

        # percentage
        set -l pct (string trim -- "$p[3]")
        set -l pctnum (string replace -r '%$' '' -- "$pct")
        if test $known = 0; or not string match -qr '^[0-9]+(\.[0-9]+)?$' -- "$pctnum"
            set pctnum 0
            set pct '?'
        end

        set -l barstr ''
        if test $known = 1
            # full blocks + an eighth-block tip for smoothness
            set -l units (math "$pctnum * $barw / 100")
            set -l full (math "floor($units)")
            test $full -gt $barw; and set full $barw
            test $full -lt 0; and set full 0
            set -l frac (math "$units - $full")
            set -l partial ''
            if test $full -lt $barw; and test $frac -gt 0
                set -l idx (math "ceil($frac * 8)")
                test $idx -lt 1; and set idx 1
                test $idx -gt 8; and set idx 8
                set partial $blocks[$idx]
            end
            set -l used $full
            test -n "$partial"; and set used (math "$full + 1")
            set -l empty (math "$barw - $used")
            set -l fill (string repeat -n $full '█')
            set fill "$fill$partial"
            set -l emptybar ''
            test $empty -gt 0; and set emptybar (string repeat -n $empty '░')
            set barstr "$fg$fill$n$dim$emptybar$n"
        else
            # unknown total (live streams): slide a small accent window
            set -l ms (date +%s%3N)
            set -l win (math "max(3, min(6, $barw))")
            set -l span (math "max(1, $barw - $win + 1)")
            set -l pos (math "floor(($ms / 130) % $span)")
            set -l pre (string repeat -n $pos '░')
            set -l postlen (math "$barw - $pos - $win")
            set -l post ''
            test $postlen -gt 0; and set post (string repeat -n $postlen '░')
            set barstr "$dim$pre$n$fg"(string repeat -n $win '█')"$n$dim$post$n"
        end

        printf '\r  %s  %s%5s%s  %s%s%s\e[K' \
            $barstr \
            $bold $pct $n \
            $dim $suffix $n
    end

    set -l st $pipestatus[1]

    # Leave the cursor on a clean line if the fetching line or the bar is
    # still on screen (e.g. no progress tick was ever emitted)
    set -l state (cat $statef 2>/dev/null)
    if test "$state" != closed; and test $use_color = 1
        printf '\r\e[K'
    end

    set -l filepath (cat $tmp 2>/dev/null)

    if test $st -ne 0; or test -z "$filepath"; or not test -f "$filepath"
        printf '  %s✗%s Download failed\n' $errc $n
        if test -s $errfile
            tail -n 6 $errfile | while read -l l
                printf '    %s%s%s\n' $dim $l $n
            end
        end
        rm -f $tmp $errfile $statef
        return 1
    end

    # ---- summary ---------------------------------------------------------
    set -l elapsed (math (date +%s) - $t0)
    set -l dur
    if test $elapsed -ge 3600
        set dur (printf '%dh%02dm' (math "floor($elapsed / 3600)") (math "floor(($elapsed % 3600) / 60)"))
    else if test $elapsed -ge 60
        set dur (printf '%dm%02ds' (math "floor($elapsed / 60)") (math "$elapsed % 60"))
    else
        set dur (printf '%ds' $elapsed)
    end

    set -l bytes (stat -c %s -- $filepath 2>/dev/null)
    set -l size ''
    if test -n "$bytes"
        if command -q numfmt
            set size (numfmt --to=iec-i --suffix=B --format='%.1f' $bytes 2>/dev/null)
        else
            set size (du -h -- $filepath | string split -f1 \t)
        end
    end

    set -l metabits
    test -n "$size"; and set -a metabits $size
    test -n "$dur"; and set -a metabits $dur
    set -l meta (string join ' · ' $metabits)
    set -l base (path basename -- $filepath)
    set -l shown (string replace "$HOME/" '~/' -- "$filepath")

    printf '  %s✓%s %s%s%s' $ok $n $bold $base $n
    if test -n "$meta"
        printf '  %s%s%s' $dim $meta $n
    end
    printf '\n    %s%s%s\n' $mid $shown $n

    if test $clip = 1
        set -l uri (string replace -a '%' '%25' -- "$filepath")
        set uri (string replace -a ' ' '%20' -- "$uri")
        set uri (string replace -a '#' '%23' -- "$uri")
        set uri (string replace -a '?' '%3F' -- "$uri")
        if printf 'file://%s\n' "$uri" | wl-copy --type text/uri-list
            printf '  %s✓%s %sCopied to clipboard%s\n' $ok $n $dim $n
        else
            printf '  %s!%s %scould not copy to clipboard%s\n' $warn $n $dim $n
        end
    else
        printf '  %s!%s %swl-copy not found, skipped clipboard%s\n' $warn $n $dim $n
    end

    rm -f $tmp $errfile $statef
    return 0
end
