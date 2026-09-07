import QtQuick

// Segmented control for picking one of a few fixed values
// (fit modes, alignments, ...). Chips follow the Pomodoro
// ChipRow look: accent fill when selected, hover pop.
Row {
    id: root

    property var options: []
    property string value: ""
    signal picked(string v)

    spacing: 4

    Repeater {
        model: root.options

        Rectangle {
            id: seg
            required property string modelData
            readonly property bool on: root.value === modelData

            width: segText.implicitWidth + 12
            height: 20
            radius: 5
            color: seg.on ? Theme.accent : (segMa.containsMouse ? Theme.hover : Theme.surface)
            Behavior on color { ColorAnimation { duration: 150 } }
            scale: segMa.containsMouse ? 1.07 : 1
            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

            Text {
                id: segText
                anchors.centerIn: parent
                text: seg.modelData
                color: seg.on ? Theme.deep : Theme.text
                Behavior on color { ColorAnimation { duration: 150 } }
                font.family: Theme.font
                font.pixelSize: 11
                font.bold: seg.on
            }

            MouseArea {
                id: segMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.picked(seg.modelData)
            }
        }
    }
}
