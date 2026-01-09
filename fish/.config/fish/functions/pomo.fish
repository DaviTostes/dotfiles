function pomo
    argparse 'h/help' 'l/loop' 's/sound' -- $argv
    or return 1

    if set -q _flag_help
        echo "Usage: pomo [options] <minutes> <message>"
        echo "Options:"
        echo "  -h, --help   Show this help"
        echo "  -l, --loop   Repeat timer indefinitely"
        echo "  -s, --sound  Play sound on completion"
        echo "Example: pomo 25 Focus time"
        return 0
    end

    if test (count $argv) -lt 2
        echo "Error: missing arguments. Use -h for help."
        return 1
    end

    if not string match -qr '^\d+$' $argv[1]
        echo "Error: '$argv[1]' is not a valid number"
        return 1
    end

    set -l min $argv[1]
    set -l msg $argv[2..-1]
    set -l sec (math "$min * 60")

    while true
        set -l end_time (math (date +%s) + $sec)
        echo "⏱  Timer: $min min — $msg"
        echo "   Ends at: "(date -d @$end_time +%H:%M:%S)

        for i in (seq $sec -1 1)
            set -l mins (math "floor($i / 60)")
            set -l secs (math "$i % 60")
            printf "\r   Remaining: %02d:%02d " $mins $secs
            sleep 1
        end

        printf "\r   ✓ Completed!        \n"
        notify-send -u critical -t 0 "🍅 $msg"

        if set -q _flag_sound
            paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null
            or aplay /usr/share/sounds/alsa/Front_Center.wav 2>/dev/null
        end

        if not set -q _flag_loop
            break
        end
        echo ""
    end
end
