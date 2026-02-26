function record
    set -l pidfile /tmp/wf-recorder.pid

    if test -f $pidfile
        set -l pid (cat $pidfile)
        if kill -0 $pid 2>/dev/null
            notify-send "Stopping recording..."
            kill -TERM $pid
            sleep 2
            if kill -0 $pid 2>/dev/null
                kill -9 $pid
                sleep 1
            end
            set -l raw_file (cat /tmp/wf-recorder-file.txt)
            set -l final_file (string replace '.raw.mkv' '.mp4' $raw_file)
            ffmpeg -y -i $raw_file -c copy -movflags +faststart $final_file
            rm -f $raw_file
            rm -f $pidfile /tmp/wf-recorder-file.txt
            notify-send "Recording stopped and saved" "Output: $final_file"
        else
            rm -f $pidfile /tmp/wf-recorder-file.txt
            notify-send "No active recording found (stale pidfile)"
        end
    else
        set -l timestamp (date +%Y%m%d_%H%M%S)
        set -l raw_file ~/Videos/recording_$timestamp.raw.mkv
        echo $raw_file > /tmp/wf-recorder-file.txt

        wf-recorder -o HDMI-A-1 -c libx264 -p pix_fmt=yuv420p -f $raw_file &
        echo $last_pid > $pidfile
        notify-send "Recording started"
    end
end
