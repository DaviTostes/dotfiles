import Quickshell
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

// Settings panel for wallpaper / hyprlock / hypridle.
// Opens as a dropdown to the left of the bar's settings pill, on whichever
// monitor that pill lives on.
PopupWindow {
    id: root

    required property var barWindow   // the bar PanelWindow to anchor to
    required property Item pill       // the settings pill to drop below
    required property bool panelOpen  // owned by the bar (per monitor!)

    property int tab: 0

    // Tab names, in the same order as the StackLayout below. The bar's
    // `settingsTab` lets the IPC (SUPER+SHIFT+B / SUPER+SHIFT+W /
    // SUPER+SHIFT+V) open the dropdown directly on a tab.
    readonly property var tabs: ["Hyprland", "Bluetooth", "Wi-Fi", "VPN"]

    // Accepts "hyprland", "hypr", "wallpaper", "lock", "lockscreen", "idle",
    // "wifi", "wi-fi", "Wi-Fi", …
    function tabIndex(name) {
        const norm = s => (s || "").toLowerCase().replace(/[^a-z0-9]/g, "");
        const n = norm(name);
        if (n === "hypr" || n === "hyprland" || n === "wallpaper"
                || n === "lock" || n === "lockscreen" || n === "idle")
            return 0;
        for (let i = 0; i < root.tabs.length; i++) {
            if (norm(root.tabs[i]) === n) return i;
        }
        return -1;
    }

    // stays mapped briefly while closing so the fade can play
    visible: root.panelOpen || hideTimer.running
    color: "transparent"

    Timer { id: hideTimer; interval: 220 }

    // screen bounds of the bar this panel belongs to (a Window's own screen
    // may be unset; the bar always has one)
    readonly property int screenW:
        root.barWindow && root.barWindow.screen ? root.barWindow.screen.width : 1920
    readonly property int screenH:
        root.barWindow && root.barWindow.screen ? root.barWindow.screen.height : 1080

    implicitWidth: Math.min(580, Math.max(320, root.screenW - 16))
    // keep the whole panel on screen even on a short display (the tab body
    // scrolls, so a smaller height is safe)
    implicitHeight: Math.min(560, Math.max(320, root.screenH - 16))

    anchor {
        window: root.barWindow
        edges: Edges.Right
        gravity: Edges.Left
        onAnchoring: {
            // The anchor rect is in the BAR WINDOW's local coordinates, so
            // the vertical clamp must use the window's own height, not the
            // screen's (the bar starts below the top bar). Horizontally the
            // pill sits at the window's left edge; open left of it with a
            // clear gap and only fall back toward the screen edge when the
            // display is too narrow to fit the panel otherwise.
            const p = root.pill.mapToItem(null, 0, 0);
            const minRight = root.barWindow.width - root.screenW
                           + root.implicitWidth + 8;
            const rightEdge = Math.max(p.x - 14, minRight);
            const top = Math.max(8, Math.min(p.y,
                                root.barWindow.height - root.implicitHeight - 8));
            anchor.rect.x = rightEdge - 1;
            anchor.rect.y = top;
            anchor.rect.width = 1;
            anchor.rect.height = root.implicitHeight;
        }
    }

    // The Wi-Fi and VPN tabs shell out to external tools (several
    // processes per load). Only load them when their tab is actually shown,
    // instead of on every dropdown open regardless of the tab the user is
    // looking at.
    function loadWifiIfVisible() {
        if (root.tab === 2) wifiTab.reload();
    }

    function loadVpnIfVisible() {
        if (root.tab === 3) vpnTab.reload();
    }

    function loadLazyTabsIfVisible() {
        root.loadWifiIfVisible();
        root.loadVpnIfVisible();
    }

    onVisibleChanged: {
        if (!visible) return;
        anchor.updateAnchor();
        hyprlandTab.reload();
        bluetoothTab.reload();
        // the bar stores which tab was requested (0 unless the IPC opened
        // the panel on a specific one)
        const want = Math.max(0, Math.min(root.barWindow.settingsTab,
                                          root.tabs.length - 1));
        const changed = want !== root.tab;
        root.tab = want;
        // onTabChanged only fires on an actual change; cover the reopen-on-
        // the-same-tab case explicitly
        if (!changed) root.loadLazyTabsIfVisible();
        HyprSettings.galleryOpen = false;
    }

    onTabChanged: root.loadLazyTabsIfVisible()

    // re-opening on another tab while the dropdown is already visible does
    // not go through onVisibleChanged, so follow the bar's request too
    Connections {
        target: root.barWindow
        function onSettingsTabChanged() {
            if (root.panelOpen) root.tab = root.barWindow.settingsTab;
        }
    }

    // gallery popup is owned by this panel; row buttons route through here
    // Gallery targets: >= 0 is a wallpaper row, -1 is every monitor plus the
    // lock screen ("set all") and -2 is the lock screen alone.
    function toggleGallery(row) {
        if (HyprSettings.galleryOpen && HyprSettings.galleryHost === root
                && HyprSettings.galleryRow === row) {
            HyprSettings.galleryOpen = false;
            return;
        }
        HyprSettings.galleryHost = root;
        HyprSettings.galleryRow = row;
        HyprSettings.galleryOpen = true;
        // retargeting while the grid is already up must repaint the highlight
        hyprlandTab.syncGalleryPicked();
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
                        onClicked: {
                            root.tab = index;
                            // remember the tab on the bar: reopening the
                            // dropdown (pill or IPC) should not snap back to
                            // whichever tab an old keybind asked for
                            if (root.barWindow && root.barWindow.setSettingsTab)
                                root.barWindow.setSettingsTab(index);
                        }
                    }
                }
            }

            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: root.tab

                HyprlandTab { id: hyprlandTab; panel: root }
                BluetoothTab { id: bluetoothTab }
                WifiTab { id: wifiTab }
                VpnTab { id: vpnTab }
            }
        }

        Shortcut {
            sequence: "Escape"
            context: Qt.ApplicationShortcut
            // the gallery sits on top and owns Escape while it is open
            enabled: root.panelOpen && !galleryWin.open
            onActivated: root.panelOpen = false
        }

        Shortcut {
            sequence: "Ctrl+S"
            context: Qt.ApplicationShortcut
            enabled: root.panelOpen && root.tab === 0 && !galleryWin.open
            onActivated: hyprlandTab.saveAll()
        }
    }

    // Wallpaper gallery — its own popup on the same monitor, opening to the
    // left of the settings panel with the same open/close fade.
    PopupWindow {
        id: galleryWin

        readonly property bool open:
            HyprSettings.galleryOpen && HyprSettings.galleryHost === root

        // stays mapped briefly while closing so the fade can play
        visible: galleryWin.open || gHideTimer.running
        color: "transparent"

        implicitWidth: Math.min(560, Math.max(320, root.screenW - 16))
        implicitHeight: Math.min(520, Math.max(240, root.screenH - 16))

        Timer { id: gHideTimer; interval: 220 }

        onOpenChanged: {
            if (open) {
                gHideTimer.stop();
                anchor.updateAnchor();
                hyprlandTab.syncGalleryPicked();
            } else {
                gHideTimer.restart();
            }
        }

        anchor {
            window: root.barWindow
            edges: Edges.Right
            gravity: Edges.Left
            onAnchoring: {
                // to the LEFT of the settings panel, top-aligned with it, in
                // the bar window's local coordinates (same rules as the panel
                // above): keep a gap between the two panels, stay above the
                // screen's bottom bar, and only fall back toward the screen
                // edge when the display is too narrow for both.
                const p = root.pill.mapToItem(null, 0, 0);
                const desiredRight = p.x - 14 - root.implicitWidth - 14;
                const minRight = root.barWindow.width - root.screenW
                               + galleryWin.implicitWidth + 8;
                const right = Math.max(desiredRight, minRight);
                const top = Math.max(8, Math.min(p.y,
                                    root.barWindow.height - galleryWin.implicitHeight - 8));
                anchor.rect.x = right - 1;
                anchor.rect.y = top;
                anchor.rect.width = 1;
                anchor.rect.height = galleryWin.implicitHeight;
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
                // stay loaded through the close fade (visible outlives open)
                animate: galleryWin.visible
                picked: HyprSettings.galleryPicked
                onChosen: p => hyprlandTab.applyGalleryPick(p)
            }

            Shortcut {
                sequence: "Escape"
                context: Qt.ApplicationShortcut
                enabled: galleryWin.open
                onActivated: HyprSettings.galleryOpen = false
            }
        }
    }
}
