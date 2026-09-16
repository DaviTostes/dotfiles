import Quickshell
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

// Settings panel for hyprpaper / hyprlock / hypridle.
// Opens as a Pomodoro-style dropdown anchored under the bar's
// settings pill, on whichever monitor that pill lives on.
PopupWindow {
    id: root

    required property var barWindow   // the bar PanelWindow to anchor to
    required property Item pill       // the settings pill to drop below
    required property bool panelOpen  // owned by the bar (per monitor!)

    property int tab: 0

    // Tab names, in the same order as the StackLayout below. The bar's
    // `settingsTab` lets the IPC (SUPER+SHIFT+B / SUPER+SHIFT+W) open the
    // dropdown directly on a tab.
    readonly property var tabs: ["Wallpaper", "Lock Screen", "Idle", "Bluetooth", "Wi-Fi"]

    // Accepts "wifi", "wi-fi", "Wi-Fi", "lock screen", "lockscreen", …
    function tabIndex(name) {
        const norm = s => (s || "").toLowerCase().replace(/[^a-z0-9]/g, "");
        const n = norm(name);
        for (let i = 0; i < root.tabs.length; i++) {
            if (norm(root.tabs[i]) === n) return i;
        }
        return -1;
    }

    // stays mapped briefly while closing so the fade can play
    visible: root.panelOpen || hideTimer.running
    color: "transparent"

    Timer { id: hideTimer; interval: 220 }

    implicitWidth: 580
    implicitHeight: 560

    anchor {
        window: root.barWindow
        edges: Edges.Top
        gravity: Edges.Bottom
        onAnchoring: {
            // pill coords are relative to the bar window; hang the
            // popup below the pill, right-aligned with its right edge
            const p = root.pill.mapToItem(null, 0, 0);
            anchor.rect.x = p.x + root.pill.width - root.implicitWidth;
            anchor.rect.y = p.y + root.pill.height + 6;
            anchor.rect.width = root.implicitWidth;
            anchor.rect.height = 1;
        }
    }

    onVisibleChanged: {
        if (visible) {
            anchor.updateAnchor();
            paperTab.reload();
            lockTab.reload();
            idleTab.reload();
            bluetoothTab.reload();
            wifiTab.reload();
            // the bar stores which tab was requested (0 unless the IPC
            // opened the panel on a specific one)
            root.tab = Math.max(0, Math.min(root.barWindow.settingsTab, root.tabs.length - 1));
            HyprSettings.galleryOpen = false;
        }
    }

    // re-opening on another tab while the dropdown is already visible does
    // not go through onVisibleChanged, so follow the bar's request too
    Connections {
        target: root.barWindow
        function onSettingsTabChanged() {
            if (root.panelOpen) root.tab = root.barWindow.settingsTab;
        }
    }

    // gallery popup is owned by this panel; row buttons route through here
    function toggleGallery(tab, row) {
        if (HyprSettings.galleryOpen && HyprSettings.galleryHost === root
                && HyprSettings.galleryTab === tab && HyprSettings.galleryRow === row) {
            HyprSettings.galleryOpen = false;
            return;
        }
        HyprSettings.galleryHost = root;
        HyprSettings.galleryTab = tab;
        HyprSettings.galleryRow = row;
        HyprSettings.galleryOpen = true;
    }

    // fade driver + dialog-suspension cleanup (owner-driven, not
    // visible-driven: the popup stays mapped 220ms for the fade)
    onPanelOpenChanged: {
        if (panelOpen) {
            hideTimer.stop();
            HyprSettings.galleryOpen = false;
        } else {
            hideTimer.restart();
            HyprSettings.modalDialogOpen = false;
            HyprSettings.galleryOpen = false;
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: 6
        color: Theme.bg
        border.color: Theme.border
        opacity: root.panelOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        transform: Translate {
            y: root.panelOpen ? 0 : -8
            Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                ColumnLayout {
                    spacing: 0
                    Layout.fillWidth: true

                    Text {
                        text: "Hypr Config"
                        color: Theme.text
                        font.family: Theme.font
                        font.bold: true
                        font.pixelSize: 14
                    }
                    Text {
                        text: HyprSettings.confDir
                        color: Theme.muted
                        font.family: Theme.font
                        font.pixelSize: 10
                    }
                }

                TextButton {
                    label: "\uf00d"
                    tooltip: "Close (Esc)"
                    onClicked: root.panelOpen = false
                }
            }

            Row {
                spacing: 6

                Repeater {
                    model: root.tabs

                    TextButton {
                        required property string modelData
                        required property int index

                        label: modelData
                        accent: root.tab === index
                        tooltip: ""
                        onClicked: root.tab = index
                    }
                }
            }

            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: root.tab

                PaperTab { id: paperTab; panel: root }
                LockTab { id: lockTab; panel: root }
                IdleTab { id: idleTab }
                BluetoothTab { id: bluetoothTab }
                WifiTab { id: wifiTab }
            }
        }

        Shortcut {
            sequence: "Escape"
            onActivated: root.panelOpen = false
        }

        Shortcut {
            sequence: "Ctrl+S"
            onActivated: {
                // only the conf-file tabs have something to save
                if (root.tab === 0) paperTab.save();
                else if (root.tab === 1) lockTab.save();
                else if (root.tab === 2) idleTab.save();
            }
        }
    }

    // Wallpaper gallery — its own popup on the same monitor, hanging
    // right below the settings panel (same Pomodoro open/close fade).
    PopupWindow {
        id: galleryWin

        readonly property bool open:
            HyprSettings.galleryOpen && HyprSettings.galleryHost === root

        // stays mapped briefly while closing so the fade can play
        visible: galleryWin.open || gHideTimer.running
        color: "transparent"

        implicitWidth: 560
        implicitHeight: 280

        Timer { id: gHideTimer; interval: 220 }

        onOpenChanged: {
            if (open) {
                gHideTimer.stop();
                anchor.updateAnchor();
                paperTab.syncGalleryPicked();
                lockTab.syncGalleryPicked();
            } else {
                gHideTimer.restart();
            }
        }

        anchor {
            window: root.barWindow
            edges: Edges.Top
            gravity: Edges.Bottom
            onAnchoring: {
                // below the panel, right-aligned with the panel's right edge
                const p = root.pill.mapToItem(null, 0, 0);
                anchor.rect.x = p.x + root.pill.width - galleryWin.implicitWidth;
                anchor.rect.y = p.y + root.pill.height + 6 + root.implicitHeight + 6;
                anchor.rect.width = galleryWin.implicitWidth;
                anchor.rect.height = 1;
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: 6
            color: Theme.bg
            border.color: Theme.border
            opacity: galleryWin.open ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            transform: Translate {
                y: galleryWin.open ? 0 : -8
                Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            }

            WallpaperGrid {
                anchors.fill: parent
                anchors.margins: 10
                picked: HyprSettings.galleryPicked
                onChosen: p => {
                    if (HyprSettings.galleryTab === 0) paperTab.applyGalleryPick(p);
                    else lockTab.applyGalleryPick(p);
                }
            }

            Shortcut {
                sequence: "Escape"
                onActivated: HyprSettings.galleryOpen = false
            }
        }
    }
}
