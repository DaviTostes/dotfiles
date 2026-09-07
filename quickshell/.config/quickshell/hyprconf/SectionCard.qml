import QtQuick

// Card with a small accent title and content below it.
Column {
    id: root

    property string title: ""
    default property alias content: inner.data

    spacing: 5

    Text {
        visible: root.title !== ""
        text: root.title
        font.family: Theme.font
        font.bold: true
        font.pixelSize: 10
        color: Theme.accent
        leftPadding: 2
    }

    Rectangle {
        width: parent.width
        height: inner.implicitHeight + 16
        radius: 6
        color: Theme.surface
        border.color: Theme.border

        Column {
            id: inner
            anchors.fill: parent
            anchors.margins: 8
            spacing: 8
        }
    }
}
