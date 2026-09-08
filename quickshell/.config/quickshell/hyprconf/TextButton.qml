import QtQuick

// Button matching the Pomodoro dropdown controls: gray surface,
// light accent fill when selected, hover scale + color animations.
// Optional unsaved-changes dot and an in-panel tooltip shown above.
Rectangle {
    id: root

    signal clicked
    property string label: ""
    property bool accent: false
    property bool dot: false
    property string tooltip: ""
    // icon glyphs render small/low at the body text size; icon-only
    // buttons pass a larger value
    property real textSize: 12

    // gate so the tooltip only shows after a short hover delay
    readonly property bool tipOpen: tipTimer.elapsed && ma.containsMouse

    implicitHeight: 26
    implicitWidth: txt.implicitWidth + 16
    radius: 6
    color: root.accent ? Theme.accent
                       : (ma.containsMouse || ma.pressed ? Theme.hover : Theme.surface)
    Behavior on color { ColorAnimation { duration: 200 } }
    scale: ma.pressed ? 0.96 : (ma.containsMouse ? 1.04 : 1)
    Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

    // unsaved-changes marker
    Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 3
        width: 5
        height: 5
        radius: 2.5
        color: Theme.err
        scale: root.dot ? 1 : 0
        Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutBack } }
    }

    // in-panel tooltip above the button (the panel is a tall layer
    // surface, so it is not clipped the way bar popups are)
    Rectangle {
        id: tip
        z: 200
        visible: opacity > 0
        opacity: root.tipOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        anchors.bottom: parent.top
        anchors.bottomMargin: 4
        anchors.horizontalCenter: parent.horizontalCenter
        width: tipText.implicitWidth + 16
        height: tipText.implicitHeight + 10
        radius: 5
        color: Theme.bg
        border.color: Theme.border

        Text {
            id: tipText
            anchors.centerIn: parent
            text: root.tooltip
            color: Theme.text
            font.family: Theme.font
            font.pixelSize: 11
        }
    }

    Timer {
        id: tipTimer
        property bool elapsed: false
        interval: 450
        running: root.tooltip !== "" && ma.containsMouse
        onTriggered: tipTimer.elapsed = true
        onRunningChanged: if (!running) tipTimer.elapsed = false
    }

    Text {
        id: txt
        anchors.centerIn: parent
        text: root.label
        font.family: Theme.font
        font.bold: root.accent
        font.pixelSize: root.textSize
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
