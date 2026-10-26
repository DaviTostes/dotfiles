import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "Conf.js" as Conf

ColumnLayout {
    id: root

    property var cfg: null
    property real lockTO: 300
    property real dpmsTO: 330
    property string status: ""
    property bool dirty: false
    readonly property bool busy: restartProc.running

    spacing: 10

    function reload() {
        let cfg = Conf.parse(fileView.text());
        if (cfg.items.length === 0) seed(cfg);
        root.cfg = cfg;

        root.lockTO = Conf.toInt(Conf.getVar(cfg, "$lock_timeout", "300"), 300);
        root.dpmsTO = Conf.toInt(Conf.getVar(cfg, "$dpms_timeout", "330"), 330);
        root.dirty = false;
        root.status = "";
    }

    function save(restartAfterSave) {
        const cfg = root.cfg;
        Conf.setVar(cfg, "$lock_timeout", Conf.fmtInt(root.lockTO));
        Conf.setVar(cfg, "$dpms_timeout", Conf.fmtInt(root.dpmsTO));

        fileView.setText(Conf.serialize(cfg));
        root.dirty = false;
        root.status = "Saved hypridle.conf";
        if (restartAfterSave === undefined || restartAfterSave) {
            restartProc.command = ["sh", "-c",
                "pkill -x hypridle >/dev/null 2>&1; sleep 0.3; nohup hypridle >/dev/null 2>&1 &"];
            restartProc.running = true;
            root.status += ", restarting hypridle…";
        }
    }

    function seed(cfg) {
        Conf.setVar(cfg, "$lock", "loginctl lock-session");
        Conf.setVar(cfg, "$dpms_on", "hyprctl dispatch dpms on");
        Conf.setVar(cfg, "$dpms_off", "hyprctl dispatch dpms off");
        Conf.set(cfg, "general", "lock_cmd", "pidof hyprlock || hyprlock");
        Conf.set(cfg, "general", "before_sleep_cmd", "$lock");
        Conf.set(cfg, "general", "after_sleep_cmd", "$dpms_on");
        Conf.set(cfg, "listener", "timeout", "$lock_timeout");
        Conf.set(cfg, "listener", "on-timeout", "$lock");
        Conf.set(cfg, "listener", "timeout", "$dpms_timeout");
        Conf.set(cfg, "listener", "on-timeout", "$dpms_off");
        Conf.set(cfg, "listener", "on-resume", "$dpms_on");
    }

    FileView {
        id: fileView
        path: HyprSettings.confDir + "/hypridle.conf"
        blockAllReads: true
        preload: true
    }

    Process { id: restartProc }

    SectionCard {
        Layout.fillWidth: true
        title: "Idle — Timers"

        Grid {
            columns: 2
            columnSpacing: 14
            rowSpacing: 8

            Text { text: "Lock after (seconds)"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            NumField {
                from: 0
                to: 86400
                step: 30
                value: root.lockTO
                onValueEdited: v => { root.lockTO = v; root.dirty = true }
            }

            Text { text: "Screen off after (seconds)"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            NumField {
                from: 0
                to: 86400
                step: 30
                value: root.dpmsTO
                onValueEdited: v => { root.dpmsTO = v; root.dirty = true }
            }
        }

        Text {
            width: parent.width - 4
            wrapMode: Text.WordWrap
            text: "listeners in hypridle.conf reference $lock_timeout and $dpms_timeout, so these values update them in place"
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: 11
        }
    }
}
