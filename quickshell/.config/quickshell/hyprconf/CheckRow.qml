import QtQuick

// Checkbox row. Root is an Item (not a positioner) so children can use anchors.
Item {
    id: root

    property string label: ""
    property bool checked: false
    signal toggled(bool checked)

    implicitWidth: box.width + 7 + lbl.implicitWidth
    implicitHeight: 18

    Rectangle {
        id: box
        width: 15
        height: 15
        radius: 4
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        color: root.checked ? Theme.accent
                            : (ma.containsMouse ? Theme.hover : Theme.surface)
        border.color: root.checked ? Theme.accent : Theme.border
        scale: ma.pressed ? 0.9 : 1
        Behavior on color { ColorAnimation { duration: 180 } }
        Behavior on border.color { ColorAnimation { duration: 180 } }
        Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

        Text {
            anchors.centerIn: parent
            text: "\uf00c"
            color: Theme.deep
            font.family: Theme.font
            font.pixelSize: 9
            font.bold: true
            // pops in with a little overshoot when checked
            scale: root.checked ? 1 : 0
            Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
        }
    }

    Text {
        id: lbl
        text: root.label
        anchors.left: box.right
        anchors.leftMargin: 7
        anchors.verticalCenter: parent.verticalCenter
        color: Theme.text
        font.family: Theme.font
        font.pixelSize: 12
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled(!root.checked)
    }
}
