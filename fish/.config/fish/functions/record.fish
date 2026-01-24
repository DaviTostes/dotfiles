function record
    set -l pidfile /tmp/wf-recorder.pid
    
    if test -f $pidfile
        set -l pid (cat $pidfile)
        if ps -p $pid > /dev/null 2>&1
            notify-send "Stopping recording..."
            kill -INT $pid
            wait $pid 2>/dev/null
            rm $pidfile
            notify-send "Recording stopped and saved"
        else
            rm $pidfile
            notify-send "No active recording found"
        end
    else
        set -l timestamp (date +%Y%m%d_%H%M%S)
        set -l output_file ~/Videos/recording_$timestamp.mkv
        
        wf-recorder -o HDMI-A-1 -c h264_vaapi -f $output_file &
        echo $last_pid > $pidfile
        notify-send "Recording started" "Output: $output_file"
    end
end
