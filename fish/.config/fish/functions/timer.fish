function timer --description "CLI Timer with countdown, stopwatch, and pomodoro modes"
    # Colors
    set -l cyan (set_color cyan)
    set -l yellow (set_color yellow)
    set -l green (set_color green)
    set -l red (set_color red)
    set -l normal (set_color normal)
    set -l bold (set_color -o)
    
    # Help message
    if test (count $argv) -eq 0; or contains -- --help $argv; or contains -- -h $argv
        echo $bold"Usage:"$normal
        echo "  timer <duration>        Countdown timer (e.g., 'timer 5m', 'timer 30s', 'timer 1h30m')"
        echo "  timer stopwatch         Stopwatch mode (count up)"
        echo "  timer pomodoro          25min work + 5min break timer"
        echo "  timer --help            Show this help"
        echo ""
        echo $bold"Examples:"$normal
        echo "  timer 10m               10 minute countdown"
        echo "  timer 90s               90 second countdown"
        echo "  timer 1h30m             1 hour 30 minutes"
        return 0
    end
    
    # Parse duration string (e.g., "1h30m", "90s", "5m")
    function _parse_duration --argument str
        set -l total_seconds 0
        set -l current_num ""
        
        for char in (string split "" $str)
            if string match -qr '^[0-9]$' $char
                set current_num "$current_num$char"
            else if test "$char" = "h"
                set total_seconds (math $total_seconds + $current_num \* 3600)
                set current_num ""
            else if test "$char" = "m"
                set total_seconds (math $total_seconds + $current_num \* 60)
                set current_num ""
            else if test "$char" = "s"
                set total_seconds (math $total_seconds + $current_num)
                set current_num ""
            end
        end
        
        # If no unit specified and just a number, assume minutes
        if test -n "$current_num"
            set total_seconds (math $total_seconds + $current_num \* 60)
        end
        
        echo $total_seconds
    end
    
    # Format seconds into HH:MM:SS
    function _format_time --argument total_seconds
        set -l hours (math -s 0 $total_seconds / 3600)
        set -l minutes (math -s 0 (math $total_seconds % 3600) / 60)
        set -l seconds (math $total_seconds % 60)
        printf "%02d:%02d:%02d" $hours $minutes $seconds
    end
    
    # Progress bar
    function _progress_bar --argument current total width
        set -l filled (math -s 0 $current \* $width / $total)
        set -l empty (math $width - $filled)
        
        set -l bar (string repeat -n $filled "█")
        set -l space (string repeat -n $empty "░")
        
        set -l percent (math -s 1 $current / $total \* 100)
        printf "%s%% [%s%s]" $percent $bar $space
    end
    
    # Notification helper
    function _notify --argument title message urgency
        if type -q notify-send
            notify-send -u $urgency -t 5000 "$title" "$message"
        else if type -q dunstify
            dunstify -u $urgency -t 5000 "$title" "$message"
        end
        echo -e "\a"  # Bell
    end
    
    # Stopwatch mode
    if test "$argv[1]" = "stopwatch"
        echo $bold$green"▶ Stopwatch started (Ctrl+C to stop)"$normal
        set -l start_time (date +%s)
        
        while true
            set -l current (date +%s)
            set -l elapsed (math $current - $start_time)
            echo -ne "\r$bold"$cyan(_format_time $elapsed)$normal" elapsed    "
            sleep 1
        end
    end
    
    # Pomodoro mode
    if test "$argv[1]" = "pomodoro"
        echo $bold$yellow"🍅 Pomodoro: 25min work + 5min break"$normal
        _notify "Pomodoro" "Work session started" normal
        
        # Work session
        set -l work 1500  # 25*60
        for i in (seq $work -1 1)
            set -l elapsed (math 1500 - $i)
            set -l bar (_progress_bar $elapsed 1500 20)
            echo -ne "\r$cyan"Work:"$normal $(_format_time $i) $bar"
            sleep 1
        end
        
        _notify "Pomodoro" "Work done! Take a 5min break" critical
        echo -e "\n"$green"✓ Work complete! Starting 5min break..."$normal
        
        # Break session
        set -l break 300  # 5*60
        for i in (seq $break -1 1)
            set -l elapsed (math 300 - $i)
            set -l bar (_progress_bar $elapsed 300 20)
            echo -ne "\r$yellow"Break:"$normal $(_format_time $i) $bar"
            sleep 1
        end
        
        _notify "Pomodoro" "Break over! Back to work" critical
        echo -e "\n"$green"✓ Pomodoro complete!"$normal
        return 0
    end
    
    # Countdown mode
    set -l duration (_parse_duration $argv[1])
    
    if test $duration -le 0
        echo $red"Error: Invalid duration"$normal
        return 1
    end
    
    set -l human_time (_format_time $duration)
    echo $bold"⏱ Countdown: $human_time"$normal
    _notify "Timer" "Started $human_time countdown" low
    
    for i in (seq $duration -1 1)
        set -l elapsed (math $duration - $i)
        set -l bar (_progress_bar $elapsed $duration 25)
        set -l remaining (_format_time $i)
        
        # Color change based on time left
        if test $i -le 10
            set_color red
            echo -ne "\r⏰ $remaining $bar"
        else if test $i -le 60
            set_color yellow
            echo -ne "\r⏱ $remaining $bar"
        else
            set_color cyan
            echo -ne "\r⏱ $remaining $bar"
        end
        set_color normal
        
        sleep 1
    end
    
    echo -e "\n"$bold$green"✓ Timer complete!"$normal
    _notify "Timer" "Countdown finished!" critical
    
    # Optional: play sound if available
    if test -f /usr/share/sounds/freedesktop/stereo/complete.oga
        paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null &
    end
end
