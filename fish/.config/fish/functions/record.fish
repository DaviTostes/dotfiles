function record
    set -l pidfile /tmp/wf-recorder.pid
    
    if test -f $pidfile
        set -l pid (cat $pidfile)
        if ps -p $pid > /dev/null 2>&1
            kill -INT $pid
            rm $pidfile
            notify-send "Recording stopped"
        else
            rm $pidfile
            notify-send "No active recording found"
        end
    else
        set -l timestamp (date +%Y%m%d_%H%M%S)
        set -l output_file ~/Videos/recording_$timestamp.mp4
        
        wf-recorder -o HDMI-A-1 -f $output_file &
        echo $last_pid > $pidfile
        notify-send "Recording started: $output_file \nRun 'rec' again to stop"
    end
end

