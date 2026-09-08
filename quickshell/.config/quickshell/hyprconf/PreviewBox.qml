import QtQuick
import Quickshell
import Quickshell.Io
import "Conf.js" as Conf

Rectangle {
    id: root

    property string path: ""

    implicitWidth: 300
    implicitHeight: 120
    radius: 6
    color: Theme.deep
    border.color: Theme.border
    clip: true

    Image {
        id: img
        anchors.fill: parent
        anchors.margins: 2
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
        source: Conf.fileUrl(root.path, Quickshell.env("HOME"))
        // fade in once decoded, sink toward the box color while loading
        opacity: root.path === "" ? 0 : (img.status === Image.Ready ? 1 : 0.15)
        Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
        scale: ma.containsMouse && root.path !== "" ? 1.03 : 1
        Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    }

    Text {
        anchors.centerIn: parent
        visible: root.path === ""
        text: "no image"
        color: Theme.muted
        font.family: Theme.font
        font.pixelSize: 11
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.path !== ""
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            openProc.command = ["xdg-open", Conf.expandPath(root.path, Quickshell.env("HOME"))];
            openProc.running = true;
        }
    }

    Process { id: openProc }
}
