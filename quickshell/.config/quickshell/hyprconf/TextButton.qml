import QtQuick

// Button matching the Pomodoro dropdown controls: gray surface,
// light accent fill when selected, hover scale + color animations.
Rectangle {
    id: root

    signal clicked
    property string label: ""
    property bool accent: false

    implicitHeight: 26
    implicitWidth: txt.implicitWidth + 16
    radius: 6
    color: root.accent ? Theme.accent
                       : (ma.containsMouse || ma.pressed ? Theme.hover : Theme.surface)
    Behavior on color { ColorAnimation { duration: 200 } }
    scale: ma.pressed ? 0.96 : (ma.containsMouse ? 1.04 : 1)
    Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

    Text {
        id: txt
        anchors.centerIn: parent
        text: root.label
        font.family: Theme.font
        font.bold: root.accent
        font.pixelSize: 12
        color: root.accent ? Theme.deep : Theme.text
        Behavior on color { ColorAnimation { duration: 200 } }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
