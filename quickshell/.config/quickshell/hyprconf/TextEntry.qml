import QtQuick
import QtQuick.Controls.Basic

TextField {
    id: root

    // 0 = neutral, 1 = valid (ok border), 2 = invalid (error border)
    property int validity: 0

    color: Theme.text
    placeholderTextColor: Theme.muted
    selectionColor: Theme.accent
    selectedTextColor: Theme.deep
    font.family: Theme.font
    font.pixelSize: 12
    leftPadding: 8
    rightPadding: 8
    topPadding: 5
    bottomPadding: 5
    implicitHeight: 26

    background: Rectangle {
        radius: 6
        color: root.activeFocus ? Theme.hover : Theme.surface
        border.color: root.validity === 2 ? Theme.err
                                          : (root.activeFocus ? Theme.accent : Theme.border)
        Behavior on color { ColorAnimation { duration: 150 } }
        Behavior on border.color { ColorAnimation { duration: 150 } }
    }
}
