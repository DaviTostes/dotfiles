import QtQuick
import Quickshell
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
        anchors.fill: parent
        anchors.margins: 2
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
        source: Conf.fileUrl(root.path, Quickshell.env("HOME"))
    }

    Text {
        anchors.centerIn: parent
        visible: root.path === ""
        text: "no image"
        color: Theme.muted
        font.family: Theme.font
        font.pixelSize: 11
    }
}
