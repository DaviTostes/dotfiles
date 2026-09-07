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

    visible: root.panelOpen
    color: "transparent"

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
            root.tab = 0;
        } else {
            // don't leave the bar's catcher suspended if the panel
            // closes while a file dialog is still open
            HyprSettings.modalDialogOpen = false;
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: 6
        color: Theme.bg
        border.color: Theme.border

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
                    onClicked: root.panelOpen = false
                }
            }

            Row {
                spacing: 6

                Repeater {
                    model: ["Wallpaper", "Lock Screen", "Idle"]

                    TextButton {
                        required property string modelData
                        required property int index

                        label: modelData
                        accent: root.tab === index
                        onClicked: root.tab = index
                    }
                }
            }

            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: root.tab

                PaperTab { id: paperTab }
                LockTab { id: lockTab }
                IdleTab { id: idleTab }
            }
        }

        Shortcut {
            sequence: "Escape"
            onActivated: root.panelOpen = false
        }
    }
}
