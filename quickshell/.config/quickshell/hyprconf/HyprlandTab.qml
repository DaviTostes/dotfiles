import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "HyprPanel.js" as HyprPanel

ColumnLayout {
    id: root

    property var panel: null
    property bool applyWallpaperAfterSave: true
    property bool restartIdleAfterSave: true
    property string status: ""
    property bool compositorParseError: false
    property bool missingRequireWarn: false
    property var compositorModel: null

    readonly property bool compositorDirty:
        lookFeelSection.dirty
        || inputSection.dirty
        || animationsSection.dirty
        || monitorsSection.dirty
        || autostartSection.dirty

    readonly property bool dirty:
        root.compositorDirty
        || wallpaperSection.dirty
        || lockSection.dirty
        || idleSection.dirty

    readonly property bool busy:
        reloadProc.running
        || wallpaperSection.busy
        || idleSection.busy

    spacing: 10

    function reload() {
        const mons = [];
        const ms = Hyprland.monitors ? Hyprland.monitors.values : [];
        for (let i = 0; i < ms.length; i++) {
            if (ms[i].name) mons.push(ms[i].name);
        }

        const rawPanel = panelFileView.text();
        const parsed = HyprPanel.parse(rawPanel);
        root.compositorParseError = (parsed === null);
        const model = parsed !== null ? parsed : HyprPanel.defaultModel();
        root.compositorModel = model;

        const mainTxt = mainLuaFileView.text();
        root.missingRequireWarn = mainTxt.trim() !== ""
            && !/require\s*\(\s*["']hyprpanel["']\s*\)/.test(mainTxt);

        lookFeelSection.loadFrom(model);
        inputSection.loadFrom(model);
        animationsSection.loadFrom(model);
        monitorsSection.loadFrom(model, mons);
        autostartSection.loadFrom(model);

        wallpaperSection.reload();
        lockSection.reload();
        idleSection.reload();

        if (root.compositorParseError) {
            root.status = "hyprpanel.lua could not be parsed; compositor save disabled";
        } else if (root.missingRequireWarn) {
            root.status = "Warning: hyprland.lua is missing require(\"hyprpanel\")";
        } else {
            root.status = "";
        }
    }

    function syncGalleryPicked() {
        wallpaperSection.syncGalleryPicked();
        lockSection.syncGalleryPicked();
    }

    function applyGalleryPick(p) {
        if (HyprSettings.galleryTab === 0) wallpaperSection.applyGalleryPick(p);
        else lockSection.applyGalleryPick(p);
    }

    function saveAll() {
        if (!root.dirty) {
            if (root.compositorParseError) {
                root.status = "Error: hyprpanel.lua could not be parsed; not saving";
            }
            return;
        }

        const savedParts = [];

        if (root.compositorDirty) {
            if (root.compositorParseError) {
                savedParts.push("hyprpanel.lua skipped (parse error)");
            } else {
                const m = root.compositorModel || HyprPanel.defaultModel();
                lookFeelSection.writeTo(m);
                inputSection.writeTo(m);
                animationsSection.writeTo(m);
                monitorsSection.writeTo(m);
                autostartSection.writeTo(m);

                panelFileView.setText(HyprPanel.render(m));
                lookFeelSection.dirty = false;
                inputSection.dirty = false;
                animationsSection.dirty = false;
                monitorsSection.dirty = false;
                autostartSection.dirty = false;

                reloadProc.command = ["sh", "-c", "sleep 0.15; hyprctl reload >/dev/null 2>&1"];
                reloadProc.running = true;
                savedParts.push("hyprpanel.lua (reloading)");
            }
        }

        if (wallpaperSection.dirty) {
            wallpaperSection.save(root.applyWallpaperAfterSave);
            savedParts.push(root.applyWallpaperAfterSave ? "wallpaper.conf (applying)" : "wallpaper.conf");
        }

        if (lockSection.dirty) {
            lockSection.save();
            savedParts.push("hyprlock.conf");
        }

        if (idleSection.dirty) {
            idleSection.save(root.restartIdleAfterSave);
            savedParts.push(root.restartIdleAfterSave ? "hypridle.conf (restarting)" : "hypridle.conf");
        }

        root.status = savedParts.length ? "Saved " + savedParts.join(", ") : "";
    }

    FileView {
        id: panelFileView
        path: HyprSettings.confDir + "/hyprpanel.lua"
        blockAllReads: true
        preload: true
    }

    FileView {
        id: mainLuaFileView
        path: HyprSettings.confDir + "/hyprland.lua"
        blockAllReads: true
        preload: true
    }

    Process { id: reloadProc }

    ScrollView {
        id: scroll
        Layout.fillWidth: true
        Layout.fillHeight: true

        ColumnLayout {
            width: scroll.availableWidth
            spacing: 12

            // 1. Look & Feel
            LookFeelSection {
                id: lookFeelSection
                Layout.fillWidth: true
            }

            // 2. Input
            InputSection {
                id: inputSection
                Layout.fillWidth: true
            }

            // 3. Animations
            AnimationsSection {
                id: animationsSection
                Layout.fillWidth: true
            }

            // 4. Wallpaper
            WallpaperSection {
                id: wallpaperSection
                Layout.fillWidth: true
                panel: root.panel
            }

            // 5. Lock Screen
            LockSection {
                id: lockSection
                Layout.fillWidth: true
                panel: root.panel
            }

            // 6. Idle
            IdleSection {
                id: idleSection
                Layout.fillWidth: true
            }

            // 7. Monitors
            MonitorsSection {
                id: monitorsSection
                Layout.fillWidth: true
            }

            // 8. Autostart
            AutostartSection {
                id: autostartSection
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
