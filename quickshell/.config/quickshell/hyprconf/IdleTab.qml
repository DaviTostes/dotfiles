import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "Conf.js" as Conf

ColumnLayout {
    id: root

    property var cfg: null
    property real lockTO: 300
    property real dpmsTO: 330
    property string lockCmd: "pidof hyprlock || hyprlock"
    property string beforeSleep: "loginctl lock-session"
    property string afterSleep: "hyprctl dispatch dpms on"
    property bool restartAfterSave: true
    property string status: ""

    spacing: 10

    function reload() {
        let cfg = Conf.parse(fileView.text());
        if (cfg.items.length === 0) seed(cfg);
        root.cfg = cfg;

        root.lockTO = Conf.toInt(Conf.getVar(cfg, "$lock_timeout", "300"), 300);
        root.dpmsTO = Conf.toInt(Conf.getVar(cfg, "$dpms_timeout", "330"), 330);
        // Commands are read raw so $var references are not flattened to
        // literals just by opening and saving the panel.
        root.lockCmd = Conf.getRaw(cfg, "general", "lock_cmd", "pidof hyprlock || hyprlock");
        root.beforeSleep = Conf.getRaw(cfg, "general", "before_sleep_cmd", "$lock");
        root.afterSleep = Conf.getRaw(cfg, "general", "after_sleep_cmd", "$dpms_on");
        root.status = "";
    }

    function save() {
        const cfg = root.cfg;
        Conf.setVar(cfg, "$lock_timeout", Conf.fmtInt(root.lockTO));
        Conf.setVar(cfg, "$dpms_timeout", Conf.fmtInt(root.dpmsTO));
        Conf.set(cfg, "general", "lock_cmd", root.lockCmd);
        Conf.set(cfg, "general", "before_sleep_cmd", root.beforeSleep);
        Conf.set(cfg, "general", "after_sleep_cmd", root.afterSleep);

        fileView.setText(Conf.serialize(cfg));
        root.status = "Saved hypridle.conf";
        if (root.restartAfterSave) {
            restartProc.command = ["sh", "-c",
                "pkill -x hypridle >/dev/null 2>&1; sleep 0.3; nohup hypridle >/dev/null 2>&1 &"];
            restartProc.running = true;
            root.status += ", restarting hypridle…";
        }
    }

    // Minimal starter config for an empty/missing hypridle.conf.
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

    ScrollView {
        id: scroll
        Layout.fillWidth: true
        Layout.fillHeight: true

        ColumnLayout {
            width: scroll.availableWidth
            spacing: 10

            SectionCard {
                Layout.fillWidth: true
                title: "Timers"

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
                        onValueEdited: v => root.lockTO = v
                    }

                    Text { text: "Screen off after (seconds)"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    NumField {
                        from: 0
                        to: 86400
                        step: 30
                        value: root.dpmsTO
                        onValueEdited: v => root.dpmsTO = v
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

            SectionCard {
                Layout.fillWidth: true
                title: "Commands (general)"

                Grid {
                    columns: 2
                    columnSpacing: 14
                    rowSpacing: 8

                    Text { text: "Lock command"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    TextEntry {
                        width: 320
                        text: root.lockCmd
                        onEditingFinished: root.lockCmd = text
                    }

                    Text { text: "Before sleep"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    TextEntry {
                        width: 320
                        text: root.beforeSleep
                        onEditingFinished: root.beforeSleep = text
                    }

                    Text { text: "After sleep"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    TextEntry {
                        width: 320
                        text: root.afterSleep
                        onEditingFinished: root.afterSleep = text
                    }
                }
            }
        }
    }

    Row {
        Layout.fillWidth: true
        spacing: 12

        CheckRow {
            label: "Restart hypridle after saving"
            checked: root.restartAfterSave
            onToggled: c => root.restartAfterSave = c
        }

        TextButton {
            label: "\uf0c7 save"
            accent: true
            onClicked: root.save()
        }

        Text {
            height: 26
            verticalAlignment: Text.AlignVCenter
            text: root.status
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: 11
            elide: Text.ElideRight
            width: 200
        }
    }
}
