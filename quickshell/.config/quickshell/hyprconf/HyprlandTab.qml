import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

// Hyprland settings tab. The compositor itself (monitors, look & feel, input,
// animations, autostart) is hand-edited in ~/.config/hypr/hyprland.lua — the
// panel only edits the side configs it can round-trip losslessly:
// wallpaper.conf / hyprlock.conf (via WallpaperSection) and hypridle.conf
// (via IdleSection).
ColumnLayout {
    id: root

    property var panel: null
    property bool applyWallpaperAfterSave: true
    property bool restartIdleAfterSave: true
    property string status: ""

    readonly property bool dirty:
        wallpaperSection.dirty
        || idleSection.dirty

    readonly property bool busy:
        wallpaperSection.busy
        || idleSection.busy

    spacing: 10

    function reload() {
        wallpaperSection.reload();
        idleSection.reload();
        root.status = "";
    }

    function syncGalleryPicked() {
        wallpaperSection.syncGalleryPicked();
    }

    function applyGalleryPick(p) {
        wallpaperSection.applyGalleryPick(p);
    }

    function saveAll() {
        if (!root.dirty) return;

        const savedParts = [];

        if (wallpaperSection.dirty) {
            const parts = wallpaperSection.save(root.applyWallpaperAfterSave);
            if (parts !== "") savedParts.push(parts);
        }

        if (idleSection.dirty) {
            idleSection.save(root.restartIdleAfterSave);
            savedParts.push(root.restartIdleAfterSave ? "hypridle.conf (restarting)" : "hypridle.conf");
        }

        root.status = savedParts.length ? "Saved " + savedParts.join(", ") : "";
    }

    ScrollView {
        id: scroll
        Layout.fillWidth: true
        Layout.fillHeight: true

        ColumnLayout {
            width: scroll.availableWidth
            spacing: 12

            // 1. Wallpaper (monitors + lock screen)
            WallpaperSection {
                id: wallpaperSection
                Layout.fillWidth: true
                panel: root.panel
            }

            // 2. Idle
            IdleSection {
                id: idleSection
                Layout.fillWidth: true
            }
        }
    }

    Row {
        Layout.fillWidth: true
        spacing: 10

        CheckRow {
            label: "Apply wallpaper"
            checked: root.applyWallpaperAfterSave
            onToggled: c => root.applyWallpaperAfterSave = c
        }

        CheckRow {
            label: "Restart hypridle"
            checked: root.restartIdleAfterSave
            onToggled: c => root.restartIdleAfterSave = c
        }

        TextButton {
            label: "\uf0c7 save"
            accent: true
            dot: root.dirty
            tooltip: "Save dirty sections (Ctrl+S)"
            onClicked: root.saveAll()
        }

        StatusLine {
            text: root.status
            busy: root.busy
            labelWidth: 210
        }
    }
}
