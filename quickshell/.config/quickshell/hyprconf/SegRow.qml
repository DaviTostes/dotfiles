import QtQuick

// Segmented control for picking one of a few fixed values
// (fit modes, alignments, ...). An accent pill slides behind the
// selected chip; unselected chips get the hover pop + press dip.
Item {
    id: root

    property var options: []
    property string value: ""
    signal picked(string v)

    // suppress the slide on the very first placement of the pill
    property bool pillReady: false
    property Item targetSeg: null

    implicitWidth: row.implicitWidth
    // 26 matches the combo / button heights in a row so everything
    // lines up (Row does not center its children vertically)
    implicitHeight: 26

    Rectangle {
        id: pill
        visible: root.targetSeg !== null
        x: root.targetSeg ? root.targetSeg.x : 0
        width: root.targetSeg ? root.targetSeg.width : 0
        height: row.height
        y: row.y
        radius: 5
        color: Theme.accent

        Behavior on x { enabled: root.pillReady; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on width { enabled: root.pillReady; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    }

    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
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
                color: "transparent"
                scale: segMa.pressed ? 0.94
                                     : (!seg.on && segMa.containsMouse ? 1.07 : 1)
                Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

                onOnChanged: {
                    if (seg.on) {
                        root.targetSeg = seg;
                        root.pillReady = true;
                    }
                }
                Component.onCompleted: {
                    if (seg.on) {
                        root.targetSeg = seg;
                        root.pillReady = true;
                    }
                }

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
}
