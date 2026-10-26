import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Conf.js" as Conf

ColumnLayout {
    id: root

    property string transition: "simple"
    property string lockPath: ""
    property var lockCfg: null
    property string status: ""
    property var monitors: []
    property bool rowDirty: false
    property bool lockDirty: false
    readonly property bool dirty: rowDirty || lockDirty
    property bool silent: false
    property var panel: null
    readonly property bool busy: applyProc.running

    spacing: 10

    function rowPath(i) {
        if (i < 0 || i >= rows.count) return "";
        return rows.get(i).path;
    }

    // Gallery targets: 0..n = one monitor row, -1 = every monitor + the lock
    // screen, -2 = the lock screen only.
    function setLockPath(p) {
        if (p === root.lockPath) {
            root.syncGalleryPicked();
            return;
        }
        root.lockPath = p;
        root.lockDirty = true;
        root.syncGalleryPicked();
    }

    function reload() {
        root.silent = true;
        const cfg = Conf.parse(fileView.text());
        root.transition = Conf.get(cfg, "", "transition", "simple");
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
            rows.append({ monitor: monitor, path: path, fit: fit || "crop" });
        }
        if (rows.count === 0) {
            for (const m of root.monitors) rows.append({ monitor: m, path: "", fit: "crop" });
        }

        const lcfg = Conf.parse(lockFileView.text());
        root.lockCfg = lcfg;
        root.lockPath = Conf.get(lcfg, "background", "path", "");

        root.status = "";
        root.rowDirty = false;
        root.lockDirty = false;
        root.silent = false;
        root.syncGalleryPicked();
    }

    function syncGalleryPicked() {
        if (root.panel === null || HyprSettings.galleryHost !== root.panel)
            return;
        const i = HyprSettings.galleryRow;
        if (i === -2) {
            HyprSettings.galleryPicked = root.lockPath;
            return;
        }
        if (i >= 0) {
            HyprSettings.galleryPicked = rowPath(i);
            return;
        }
        // "set all": only highlight when every monitor and the lock screen
        // already share the same image
        let common = rows.count > 0 ? rows.get(0).path : "";
        for (let j = 1; j < rows.count; j++) {
            if (rows.get(j).path !== common) { common = ""; break; }
        }
        if (common !== root.lockPath) common = "";
        HyprSettings.galleryPicked = common;
    }

    function applyGalleryPick(p) {
        const i = HyprSettings.galleryRow;
        if (i === -2) {
            setLockPath(p);
            HyprSettings.galleryPicked = p;
            return;
        }
        if (i < 0) {
            for (let j = 0; j < rows.count; j++) rows.setProperty(j, "path", p);
            setLockPath(p);
            HyprSettings.galleryPicked = p;
            return;
        }
        if (i >= rows.count) return;
        rows.setProperty(i, "path", p);
        HyprSettings.galleryPicked = p;
    }

    // Writes whichever of wallpaper.conf / hyprlock.conf is dirty and
    // returns a human-readable list of what was saved.
    function save(applyAfterSave) {
        const parts = [];

        if (root.rowDirty) {
            const cfg = { items: [], vars: {} };
            cfg.items.push(Conf.item(Conf.KV, "", "transition", root.transition));
            for (let i = 0; i < rows.count; i++) {
                const r = rows.get(i);
                cfg.items.push(Conf.item(Conf.SECTION_START, "wallpaper"));
                cfg.items.push(Conf.item(Conf.KV, "", "monitor", r.monitor));
                cfg.items.push(Conf.item(Conf.KV, "", "path", r.path));
                cfg.items.push(Conf.item(Conf.KV, "", "fit_mode", r.fit));
                cfg.items.push(Conf.item(Conf.SECTION_END, "}"));
            }
            fileView.setText(Conf.serialize(cfg));
            root.rowDirty = false;

            if (applyAfterSave === undefined || applyAfterSave) {
                applyProc.command = ["sh", "-c",
                    "sleep 0.2; exec \"$HOME/.config/hypr/scripts/wallpaper-apply\""];
                applyProc.running = true;
                parts.push("wallpaper.conf (applying)");
            } else {
                parts.push("wallpaper.conf");
            }
        }

        if (root.lockDirty) {
            const lcfg = root.lockCfg || Conf.parse(lockFileView.text());
            Conf.set(lcfg, "background", "path", root.lockPath);
            lockFileView.setText(Conf.serialize(lcfg));
            root.lockCfg = lcfg;
            root.lockDirty = false;
            parts.push("hyprlock.conf");
        }

        root.status = parts.length ? "Saved " + parts.join(", ") : "";
        return parts.join(", ");
    }

    ListModel {
        id: rows
        onDataChanged: {
            if (!root.silent) root.rowDirty = true;
            root.syncGalleryPicked();
        }
        onCountChanged: {
            if (!root.silent) root.rowDirty = true;
            root.syncGalleryPicked();
        }
    }

    FileView {
        id: fileView
        path: HyprSettings.confDir + "/wallpaper.conf"
        blockAllReads: true
        preload: true
    }

    FileView {
        id: lockFileView
        path: HyprSettings.confDir + "/hyprlock.conf"
        blockAllReads: true
        preload: true
    }

    Process { id: applyProc }

    component WallpaperRow: Item {
        id: wrow
        required property int index
        required property string monitor
        required property string path
        required property string fit

        property bool dying: false
        property bool entered: false

        width: parent.width
        implicitHeight: col.implicitHeight
        height: entered && !dying ? col.implicitHeight : 0
        opacity: entered && !dying ? 1 : 0
        clip: true
        Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        Component.onCompleted: wrow.entered = true

        Timer {
            running: wrow.dying
            interval: 220
            onTriggered: rows.remove(wrow.index)
        }

        Column {
            id: col
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 6

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
                    options: ["crop", "fit", "stretch"]
                    value: wrow.fit
                    onPicked: v => rows.setProperty(wrow.index, "fit", v)
                }

                TextButton {
                    label: "\uf03e"
                    textSize: 13
                    tooltip: "Pick from gallery"
                    onClicked: if (root.panel) root.panel.toggleGallery(wrow.index)
                }

                TextButton {
                    label: "\uf1f8"
                    textSize: 13
                    tooltip: "Remove monitor"
                    onClicked: wrow.dying = true
                }
            }

            PathRow {
                path: wrow.path
                onPicked: p => rows.setProperty(wrow.index, "path", p)
            }

            PreviewBox {
                width: parent.width - 4
                path: wrow.path
                animate: root.panel === null || (root.panel.visible && root.panel.tab === 0)
            }
        }
    }

    SectionCard {
        Layout.fillWidth: true
        title: "Wallpaper — Transition"

        SegRow {
            options: ["none", "simple", "wipe", "grow", "random"]
            value: root.transition
            onPicked: v => { root.transition = v; root.rowDirty = true; }
        }
    }

    SectionCard {
        Layout.fillWidth: true
        title: "Wallpaper — Monitors & Lock Screen"

        Repeater {
            model: rows
            delegate: WallpaperRow {}
        }

        Rectangle {
            width: parent.width - 4
            height: 1
            color: Theme.border
        }

        Row {
            spacing: 8

            Text {
                height: 26
                verticalAlignment: Text.AlignVCenter
                text: "\uf023 lock screen"
                color: Theme.accent2
                font.family: Theme.font
                font.bold: true
                font.pixelSize: 11
            }

            TextButton {
                label: "\uf03e"
                textSize: 13
                tooltip: "Pick the lock screen wallpaper from gallery"
                onClicked: if (root.panel) root.panel.toggleGallery(-2)
            }
        }

        PathRow {
            path: root.lockPath
            onPicked: p => root.setLockPath(p)
        }

        PreviewBox {
            width: parent.width - 4
            path: root.lockPath
            animate: root.panel === null || (root.panel.visible && root.panel.tab === 0)
        }

        Row {
            spacing: 10

            TextButton {
                label: "\uf03e set all"
                tooltip: "Pick one wallpaper for every monitor and the lock screen"
                onClicked: if (root.panel) root.panel.toggleGallery(-1)
            }

            TextButton {
                label: "\uf067 add monitor"
                tooltip: "Add monitor"
                onClicked: rows.append({ monitor: root.monitors[0] || "", path: "", fit: "crop" })
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
            }
        }
    }
}
