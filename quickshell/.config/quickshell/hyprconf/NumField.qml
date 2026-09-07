import QtQuick
import QtQuick.Controls.Basic

// Number field with -/+ steppers; emits valueEdited() when the value changes.
Row {
    id: root

    property real value: 0
    property real from: 0
    property real to: 999999
    property real step: 1
    property int decimals: 0
    signal valueEdited(real v)

    readonly property string textVal: decimals > 0 ? Number(value).toFixed(decimals) : String(Math.round(value))

    spacing: 4

    function clamp(v) { return Math.min(root.to, Math.max(root.from, v)); }

    TextButton {
        label: "\uf068"
        onClicked: root.valueEdited(root.clamp(root.value - root.step))
    }

    TextEntry {
        id: field
        width: 62
        horizontalAlignment: TextInput.AlignHCenter
        text: root.textVal
        onEditingFinished: {
            const n = parseFloat(text);
            if (!isNaN(n)) {
                const c = root.clamp(n);
                if (c !== root.value) root.valueEdited(c);
                else text = Qt.binding(() => root.textVal);
            } else {
                text = Qt.binding(() => root.textVal);
            }
        }
    }

    TextButton {
        label: "\uf067"
        onClicked: root.valueEdited(root.clamp(root.value + root.step))
    }
}
