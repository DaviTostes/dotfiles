import QtQuick
import Quickshell
import Quickshell.Io
import "Conf.js" as Conf

// Thumbnail gallery of a wallpaper directory. Click a thumbnail to apply
// it to the row that opened the grid. Files are listed with find(1)
// (sorted by mtime, newest first) so it works for any reachable path.
Rectangle {
    id: root

    // currently applied path (absolute or ~/ relative) for the highlight
    property string picked: ""
    signal chosen(string p)

    property string dir: HyprSettings.wallpaperDir
    readonly property string homeDir: Quickshell.env("HOME")
    readonly property string dirPath: Conf.expandPath(dir, root.homeDir)

    implicitWidth: 200
    implicitHeight: 250
    radius: 6
    color: Theme.surface
    border.color: Theme.border

    function load() { scanTimer.restart() }

    Timer {
        id: scanTimer
        interval: 200
        onTriggered: {
            root.loading = true;
            listProc.running = true;
        }
    }

    onDirPathChanged: root.load()

    Process {
        id: listProc
        command: ["sh", "-c",
            "find -L \"$1\" -maxdepth 1 -type f \\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg'"
            + " -o -iname '*.webp' -o -iname '*.bmp' -o -iname '*.gif' -o -iname '*.avif' \\)"
            + " -printf '%T@\\t%p\\n' 2>/dev/null | sort -rn | cut -f2",
            "sh", root.dirPath]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split("\n").filter(l => l !== "");
                items.clear();
                for (const l of lines) items.append({ p: Conf.homeRel(l, root.homeDir) });
                root.loading = false;
            }
        }
    }

    property bool loading: true

    Column {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 8

        Row {
            id: dirRow
            width: parent.width
            spacing: 6

            TextEntry {
                id: dirEntry
                width: parent.width - refreshBtn.width - 6
                text: root.dir
                placeholderText: "/path/to/wallpapers"
                onEditingFinished: {
                    if (text.trim() !== "" && text !== root.dir) root.dir = text.trim();
                    text = Qt.binding(() => root.dir);
                }
            }

            TextButton {
                id: refreshBtn
                label: "\uf2f9"
                textSize: 13
                tooltip: "Refresh"
                onClicked: root.load()
            }
        }

        Item {
            width: parent.width
            height: parent.height - dirRow.height - 8

            GridView {
                id: view
                anchors.fill: parent
                clip: true
                cellWidth: 104
                cellHeight: 66
                model: items

                delegate: Item {
                    id: cell
                    required property string p

                    width: view.cellWidth - 8
                    height: view.cellHeight - 8

                    Rectangle {
                        id: thumb
                        anchors.fill: parent
                        radius: 5
                        color: Theme.deep
                        clip: true
                        border.width: selected ? 2 : 1
                        border.color: selected ? Theme.accent
                                     : (cellMa.containsMouse ? Theme.accent2 : Theme.border)

                        readonly property bool selected:
                            Conf.expandPath(cell.p, root.homeDir)
                            === Conf.expandPath(root.picked, root.homeDir)

                        Image {
                            anchors.fill: parent
                            asynchronous: true
                            fillMode: Image.PreserveAspectCrop
                            source: Conf.fileUrl(cell.p, root.homeDir)
                            sourceSize.width: 240
                            scale: cellMa.containsMouse ? 1.06 : 1
                            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                        }

                        MouseArea {
                            id: cellMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.chosen(cell.p)
                        }
                    }
                }
            }

            Text {
                visible: items.count === 0 && !root.loading
                anchors.centerIn: parent
                text: root.dirPath === "" ? "set a wallpaper directory"
                                          : "no images found in this directory"
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: 11
            }
        }
    }

    ListModel { id: items }
}
