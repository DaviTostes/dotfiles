function mousecircle --description "Move the mouse pointer in an endless circle until the left button is clicked"
    set -l radius 100
    set -l period 2.0
    set -l fps 60

    set -l usage "Usage: mousecircle [options]
  Spin the mouse pointer in an endless circle around its current position.
  It stops as soon as the left mouse button is pressed (or Ctrl+C is used).

Options:
  -r, --radius <px>    Circle radius in pixels (default: 100)
  -p, --period <sec>   Seconds per full revolution (default: 2)
      --fps <n>        Target frames per second (default: 60)
  -h, --help           Show this help

Examples:
  mousecircle
  mousecircle -r 200 -p 4
  mousecircle --radius 60 --fps 120"

    # ── parse options ───────────────────────────────────────────────────────
    set -l i 1
    while test $i -le (count $argv)
        set -l opt $argv[$i]
        switch $opt
            case -h --help
                printf '%s\n' $usage
                return 0
            case -r --radius
                set i (math $i + 1)
                if test $i -gt (count $argv)
                    echo "mousecircle: $opt requires a value" >&2
                    return 1
                end
                set radius $argv[$i]
            case -p --period
                set i (math $i + 1)
                if test $i -gt (count $argv)
                    echo "mousecircle: $opt requires a value" >&2
                    return 1
                end
                set period $argv[$i]
            case --fps
                set i (math $i + 1)
                if test $i -gt (count $argv)
                    echo "mousecircle: $opt requires a value" >&2
                    return 1
                end
                set fps $argv[$i]
            case '*'
                echo "mousecircle: unknown option '$opt'" >&2
                echo "Try 'mousecircle --help'." >&2
                return 1
        end
        set i (math $i + 1)
    end

    if not string match -qr '^[0-9]+$' -- $radius
        echo "mousecircle: radius must be a positive integer" >&2
        return 1
    end
    if test $radius -lt 1
        echo "mousecircle: radius must be at least 1 pixel" >&2
        return 1
    end
    if not string match -qr '^[0-9]+(\.[0-9]+)?$' -- $period
        echo "mousecircle: period must be a positive number of seconds" >&2
        return 1
    end
    if not string match -qr '^[0-9]+$' -- $fps
        echo "mousecircle: --fps must be a positive integer" >&2
        return 1
    end
    if test $fps -lt 1; or test $fps -gt 240
        echo "mousecircle: --fps must be between 1 and 240" >&2
        return 1
    end

    # ── pick a backend and find the circle center ───────────────────────────
    set -l backend ""
    set -l cx 0
    set -l cy 0

    if command -q hyprctl
        set -l pos (hyprctl cursorpos 2>/dev/null | head -n 1)
        if string match -qr -- '^\s*-?[0-9]+\s*,\s*-?[0-9]+\s*$' "$pos"
            set -l xy (string split ',' -- $pos)
            set cx (string trim -- $xy[1])
            set cy (string trim -- $xy[2])
            set backend hypr
        end
    end

    if test -z "$backend"
        if command -q ydotool
            set backend ydotool
        else
            echo "mousecircle: needs Hyprland (hyprctl) or ydotool" >&2
            return 1
        end
    end

    # Hyprland 0.57+ dispatches through Lua; older releases use plain text.
    set -l hypr_lua false
    if test "$backend" = hypr
        if hyprctl eval 'local _ = hl.dsp.cursor.move' >/dev/null 2>&1
            set hypr_lua true
        end
    end

    # Keep the whole circle on the monitor under the pointer.
    if test "$backend" = hypr; and command -q jq
        set -l mon (hyprctl -j monitors 2>/dev/null \
            | jq -r --argjson cx $cx --argjson cy $cy \
                '.[] | select(.x <= $cx and $cx < (.x + .width) and .y <= $cy and $cy < (.y + .height)) | "\(.x) \(.y) \(.width) \(.height)"' \
            2>/dev/null | head -n 1)
        if test -n "$mon"
            set -l m (string split ' ' -- $mon)
            set -l mx $m[1]
            set -l my $m[2]
            set -l mw $m[3]
            set -l mh $m[4]

            set -l maxr (math -s0 "$mw / 2")
            if test $mh -lt $mw
                set maxr (math -s0 "$mh / 2")
            end
            if test $radius -ge $maxr
                set radius (math "$maxr - 1")
                test $radius -lt 1; and set radius 1
            end

            set -l lo (math -s0 "$mx + $radius")
            set -l hi (math -s0 "$mx + $mw - $radius")
            if test $cx -lt $lo
                set cx $lo
            else if test $cx -gt $hi
                set cx $hi
            end

            set lo (math -s0 "$my + $radius")
            set hi (math -s0 "$my + $mh - $radius")
            if test $cy -lt $lo
                set cy $lo
            else if test $cy -gt $hi
                set cy $hi
            end
        end
    end

    # ── watch the left button of every real mouse ───────────────────────────
    # evtest writes each event as a line, so a tiny append-only file is all we
    # need to know when the user clicks.
    set -l tmpdir (mktemp -d /tmp/mousecircle.XXXXXX 2>/dev/null)
    if test -z "$tmpdir"
        echo "mousecircle: could not create a temporary directory" >&2
        return 1
    end
    set -l clickfile $tmpdir/click
    command touch $clickfile

    set -l devices
    if command -q udevadm
        for dev in /dev/input/event*
            if udevadm info --query=property --name=$dev 2>/dev/null | string match -qr 'ID_INPUT_MOUSE=1'
                set -a devices $dev
            end
        end
    end
    if test (count $devices) -eq 0
        for link in /dev/input/by-id/*-event-mouse
            test -e "$link"; or continue
            set -a devices (readlink -f -- $link)
        end
    end

    set -l monitor_pids
    for dev in $devices
        stdbuf -o0 evtest $dev >>$clickfile 2>/dev/null &
        set -a monitor_pids $last_pid
    end
    if test (count $devices) -gt 0
        sleep 0.15
    else
        echo "mousecircle: no mouse device found, press Ctrl+C to stop" >&2
    end

    # ── spin ────────────────────────────────────────────────────────────────
    function __mousecircle_int --on-signal INT
        set -g __mousecircle_abort true
    end
    function __mousecircle_term --on-signal TERM
        set -g __mousecircle_abort true
    end
    set -g __mousecircle_abort false

    set -l pi 3.141592653589793
    set -l interval (math "1 / $fps")
    set -l start (date +%s.%N)
    set -l lastx $cx
    set -l lasty $cy

    while true
        # stopped by a left click?
        if grep -aq 'BTN_LEFT), value 1' $clickfile 2>/dev/null
            break
        end
        if test "$__mousecircle_abort" = true
            break
        end
        # every click watcher died (device unplugged, etc.)
        if test (count $monitor_pids) -gt 0
            set -l alive 0
            for pid in $monitor_pids
                if kill -0 $pid 2>/dev/null
                    set alive (math $alive + 1)
                end
            end
            if test $alive -eq 0
                break
            end
        end

        set -l now (date +%s.%N)
        set -l elapsed (math "$now - $start")
        set -l angle (math "2 * $pi * $elapsed / $period")

        # ease into the circle so the pointer does not jump on the first frame
        set -l r $radius
        if test $elapsed -lt 0.3
            set r (math "$radius * $elapsed / 0.3")
        end

        set -l x (math -s0 "$cx + $r * cos($angle)")
        set -l y (math -s0 "$cy + $r * sin($angle)")

        if test "$backend" = hypr
            if $hypr_lua
                hyprctl dispatch "hl.dsp.cursor.move({x=$x,y=$y})" >/dev/null 2>&1
            else
                hyprctl dispatch movecursor $x $y >/dev/null 2>&1
            end
        else
            set -l dx (math "$x - $lastx")
            set -l dy (math "$y - $lasty")
            if test $dx -ne 0; or test $dy -ne 0
                ydotool mousemove -x $dx -y $dy >/dev/null 2>&1
                set lastx $x
                set lasty $y
            end
        end

        sleep $interval
    end

    # ── cleanup ─────────────────────────────────────────────────────────────
    for pid in $monitor_pids
        kill $pid >/dev/null 2>&1
    end
    wait $monitor_pids 2>/dev/null
    command rm -rf -- $tmpdir
    functions -e __mousecircle_int __mousecircle_term
    set -e __mousecircle_abort

    echo "mousecircle: stopped"
end
