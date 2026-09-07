import QtQuick
import QtQuick.Controls.Basic

// Dark-themed combo box used for monitor names.
ComboBox {
    id: root

    implicitWidth: 150
    implicitHeight: 26
    font.family: Theme.font
    font.pixelSize: 12

    background: Rectangle {
        radius: 6
        color: root.activeFocus ? Theme.hover : Theme.surface
        border.color: root.activeFocus ? Theme.accent : Theme.border
        Behavior on color { ColorAnimation { duration: 150 } }
        Behavior on border.color { ColorAnimation { duration: 150 } }
    }

    contentItem: Text {
        leftPadding: 8
        rightPadding: 20
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: root.displayText === "" ? root.placeholderText : root.displayText
        color: root.displayText === "" ? Theme.muted : Theme.text
        font.family: Theme.font
        font.pixelSize: 12
    }

    indicator: Text {
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        text: "\uf0d7"
        color: Theme.muted
        font.family: Theme.font
        font.pixelSize: 11
    }

    delegate: ItemDelegate {
        id: del
        required property var model
        required property int index

        width: root.width
        height: 24
        highlighted: root.highlightedIndex === index

        background: Rectangle {
            radius: 5
            color: del.highlighted ? Theme.hover : "transparent"
        }

        contentItem: Text {
            leftPadding: 8
            verticalAlignment: Text.AlignVCenter
            text: del.model.modelData !== undefined ? del.model.modelData : del.model[root.textRole]
            color: del.highlighted ? Theme.accent : Theme.text
            font.family: Theme.font
            font.pixelSize: 12
        }
    }

    popup: Popup {
        y: root.height + 4
        width: root.width
        padding: 4
        implicitHeight: Math.min(contentItem.implicitHeight + 8, 240)

        background: Rectangle {
            color: Theme.bg
            radius: 6
            border.color: Theme.border
        }

        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: root.popup.visible ? root.delegateModel : null
            currentIndex: root.highlightedIndex
            spacing: 2
        }
    }
}
