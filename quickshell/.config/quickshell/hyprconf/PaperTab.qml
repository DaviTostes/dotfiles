import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Conf.js" as Conf

ColumnLayout {
    id: root

    // awww transition used when a save is applied (see wallpaper-apply)
    property string transition: "simple"
    property bool applyAfterSave: true
    property string status: ""
    property var monitors: []

    // unsaved-changes marker; cleared on save; reload is silent
    property bool dirty: false
    property bool silent: false

    // owning HyprConfig panel (for the gallery popup state)
    property var panel: null

    spacing: 10

    function rowPath(i) {
        if (i < 0 || i >= rows.count) return "";
        return rows.get(i).path;
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
        // Sensible default when the file is empty: one row per connected monitor.
        if (rows.count === 0) {
            for (const m of root.monitors) rows.append({ monitor: m, path: "", fit: "crop" });
        }
        root.status = "";
        root.dirty = false;
        root.silent = false;
        root.syncGalleryPicked();
    }

    // mirror the picked path into the gallery popup (only when this
    // panel is the one that opened it)
    function syncGalleryPicked() {
        if (root.panel === null || HyprSettings.galleryHost !== root.panel
                || HyprSettings.galleryTab !== 0)
            return;
        if (HyprSettings.galleryRow >= 0) {
            HyprSettings.galleryPicked = rowPath(HyprSettings.galleryRow);
            return;
        }
        // "all monitors" picker (row -1): highlight the path only if every
        // row already shares it, otherwise leave nothing highlighted
        let common = rows.count > 0 ? rows.get(0).path : "";
        for (let i = 1; i < rows.count; i++) {
            if (rows.get(i).path !== common) { common = ""; break; }
        }
        HyprSettings.galleryPicked = common;
    }

    // gallery popup picked an image: row -1 means "every monitor"
    function applyGalleryPick(p) {
        const i = HyprSettings.galleryRow;
        if (i < 0) {
            for (let j = 0; j < rows.count; j++) rows.setProperty(j, "path", p);
            HyprSettings.galleryPicked = p;
            return;
        }
        if (i >= rows.count) return;
        rows.setProperty(i, "path", p);
        HyprSettings.galleryPicked = p;
    }

    function save() {
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
        root.dirty = false;
        root.status = "Saved wallpaper.conf";
        if (root.applyAfterSave) {
            // the file write may not have hit disk yet; give it a beat
            applyProc.command = ["sh", "-c",
                "sleep 0.2; exec \"$HOME/.config/hypr/scripts/wallpaper-apply\""];
            applyProc.running = true;
            root.status += ", applying…";
        }
    }

    ListModel {
        id: rows
        onDataChanged: {
            if (!root.silent) root.dirty = true;
            root.syncGalleryPicked();
        }
        onCountChanged: {
            if (!root.silent) root.dirty = true;
            root.syncGalleryPicked();
        }
    }

    FileView {
        id: fileView
        path: HyprSettings.confDir + "/wallpaper.conf"
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

        // collapse + fade while being removed, grow + fade on entry
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
                    onClicked: if (root.panel) root.panel.toggleGallery(0, wrow.index)
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
                animate: root.panel === null || (root.panel.panelOpen && root.panel.tab === 0)
            }
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
                title: "Transition"

                SegRow {
                    options: ["none", "simple", "wipe", "grow", "random"]
                    value: root.transition
                    onPicked: v => { root.transition = v; root.dirty = true; }
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
                        label: "\uf03e set all"
                        tooltip: "Pick one wallpaper for every monitor"
                        onClicked: if (root.panel) root.panel.toggleGallery(0, -1)
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

            // gallery lives in its own popup below the panel
            // (WallpaperGallery in HyprConfig.qml)
        }
    }

    Row {
        Layout.fillWidth: true
        spacing: 12

        CheckRow {
            label: "Apply after saving"
            checked: root.applyAfterSave
            onToggled: c => root.applyAfterSave = c
        }

        TextButton {
            label: "\uf0c7 save"
            accent: true
            dot: root.dirty
            tooltip: "Save (Ctrl+S)"
            onClicked: root.save()
        }

        StatusLine {
            text: root.status
            busy: applyProc.running
            labelWidth: 220
        }
    }
}
