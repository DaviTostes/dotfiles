import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Conf.js" as Conf

ColumnLayout {
    id: root

    property bool splash: false
    property bool ipc: false
    property bool restartAfterSave: true
    property string status: ""
    property var monitors: []

    spacing: 10

    function reload() {
        const cfg = Conf.parse(fileView.text());
        root.splash = Conf.get(cfg, "", "splash", "false") === "true";
        root.ipc = Conf.get(cfg, "", "ipc", "false") === "true";
        root.monitors = [];
        const ms = Hyprland.monitors ? Hyprland.monitors.values : [];
        for (let i = 0; i < ms.length; i++) if (ms[i].name) root.monitors.push(ms[i].name);
        rows.clear();
        const blocks = Conf.sectionBlocks(cfg, "wallpaper");
        for (const b of blocks) {
            let monitor = "", path = "", fit = "";
            for (const kv of b) {
                if (kv.key === "monitor") monitor = kv.val;
                else if (kv.key === "path") path = kv.val;
                else if (kv.key === "fit_mode") fit = kv.val;
            }
            rows.append({ monitor: monitor, path: path, fit: fit || "cover" });
        }
        // Sensible default when the file is empty: one row per connected monitor.
        if (rows.count === 0) {
            for (const m of root.monitors) rows.append({ monitor: m, path: "", fit: "cover" });
        }
        root.status = "";
    }

    function save() {
        const cfg = { items: [], vars: {} };
        cfg.items.push(Conf.item(Conf.KV, "", "splash", root.splash ? "true" : "false"));
        cfg.items.push(Conf.item(Conf.KV, "", "ipc", root.ipc ? "true" : "false"));
        for (let i = 0; i < rows.count; i++) {
            const r = rows.get(i);
            cfg.items.push(Conf.item(Conf.SECTION_START, "wallpaper"));
            cfg.items.push(Conf.item(Conf.KV, "", "monitor", r.monitor));
            cfg.items.push(Conf.item(Conf.KV, "", "path", r.path));
            cfg.items.push(Conf.item(Conf.KV, "", "fit_mode", r.fit));
            cfg.items.push(Conf.item(Conf.SECTION_END, "}"));
        }
        fileView.setText(Conf.serialize(cfg));
        root.status = "Saved hyprpaper.conf";
        if (root.restartAfterSave) {
            restartProc.command = ["sh", "-c",
                "pkill -x hyprpaper >/dev/null 2>&1; sleep 0.3; nohup hyprpaper >/dev/null 2>&1 &"];
            restartProc.running = true;
            root.status += ", restarting hyprpaper…";
        }
    }

    ListModel { id: rows }

    FileView {
        id: fileView
        path: HyprSettings.confDir + "/hyprpaper.conf"
        blockAllReads: true
        preload: true
    }

    Process { id: restartProc }

    component WallpaperRow: Column {
        id: wrow
        required property int index
        required property string monitor
        required property string path
        required property string fit

        spacing: 6
        width: parent.width

        Row {
            spacing: 6

            MonCombo {
                model: {
                    const names = root.monitors.slice();
                    if (wrow.monitor && names.indexOf(wrow.monitor) < 0)
                        names.unshift(wrow.monitor);
                    return names.length ? names : [wrow.monitor || "eDP-1"];
                }
                Component.onCompleted: currentIndex = find(wrow.monitor)
                onActivated: rows.setProperty(wrow.index, "monitor", currentText)
            }

            SegRow {
                options: ["cover", "contain", "tile"]
                value: wrow.fit
                onPicked: v => rows.setProperty(wrow.index, "fit", v)
            }

            TextButton {
                label: "\uf1f8"
                onClicked: rows.remove(wrow.index)
            }
        }

        PathRow {
            path: wrow.path
            onPicked: p => rows.setProperty(wrow.index, "path", p)
        }

        PreviewBox {
            width: parent.width - 4
            path: wrow.path
        }
    }

    ScrollView {
        id: scroll
        Layout.fillWidth: true
        Layout.fillHeight: true

        ColumnLayout {
            width: scroll.availableWidth
            spacing: 10

            SectionCard {
                Layout.fillWidth: true
                title: "General"

                CheckRow {
                    label: "Show splash logo on startup"
                    checked: root.splash
                    onToggled: c => root.splash = c
                }
                CheckRow {
                    label: "Enable IPC socket (hyprctl hyprpaper)"
                    checked: root.ipc
                    onToggled: c => root.ipc = c
                }
            }

            SectionCard {
                Layout.fillWidth: true
                title: "Monitors"

                Repeater {
                    model: rows
                    delegate: WallpaperRow {}
                }

                Row {
                    spacing: 10

                    TextButton {
                        label: "\uf067 add monitor"
                        onClicked: rows.append({ monitor: root.monitors[0] || "", path: "", fit: "cover" })
                    }

                    Text {
                        height: 26
                        verticalAlignment: Text.AlignVCenter
                        text: root.monitors.length ? "detected: " + root.monitors.join(", ")
                                                   : "hyprland monitors unavailable, pick manually"
                        color: Theme.muted
                        font.family: Theme.font
                        font.pixelSize: 11
                        elide: Text.ElideRight
                        width: 300
                    }                }
            }
        }
    }

    Row {
        Layout.fillWidth: true
        spacing: 12

        CheckRow {
            label: "Restart hyprpaper after saving"
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
            width: 220
        }
    }
}
