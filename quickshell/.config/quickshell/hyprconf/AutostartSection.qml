import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root

    property bool dirty: false
    property bool silent: false

    spacing: 10

    function loadFrom(model) {
        root.silent = true;
        cmdModel.clear();
        const list = model.autostart || [];
        for (let i = 0; i < list.length; i++) {
            cmdModel.append({ cmd: list[i] });
        }
        root.dirty = false;
        root.silent = false;
    }

    function writeTo(model) {
        const out = [];
        for (let i = 0; i < cmdModel.count; i++) {
            const c = cmdModel.get(i).cmd.trim();
            if (c !== "") out.push(c);
        }
        model.autostart = out;
    }

    function moveRow(from, to) {
        if (to < 0 || to >= cmdModel.count || from === to) return;
        cmdModel.move(from, to, 1);
    }

    ListModel {
        id: cmdModel
        onDataChanged: if (!root.silent) root.dirty = true
        onCountChanged: if (!root.silent) root.dirty = true
    }

    component AutostartRow: Row {
        id: crow
        required property int index
        required property string cmd

        spacing: 6

        TextEntry {
            width: 400
            text: crow.cmd
            placeholderText: "command to run at hyprland.start"
            onEditingFinished: if (text !== crow.cmd) cmdModel.setProperty(crow.index, "cmd", text)
        }

        TextButton {
            label: "\uf077"
            textSize: 11
            tooltip: "Move up"
            onClicked: root.moveRow(crow.index, crow.index - 1)
        }

        TextButton {
            label: "\uf078"
            textSize: 11
            tooltip: "Move down"
            onClicked: root.moveRow(crow.index, crow.index + 1)
        }

        TextButton {
            label: "\uf1f8"
            textSize: 12
            tooltip: "Remove command"
            onClicked: cmdModel.remove(crow.index)
        }
    }

    SectionCard {
        Layout.fillWidth: true
        title: "Autostart (hyprland.start)"

        Repeater {
            model: cmdModel
            delegate: AutostartRow {}
        }

        Row {
            spacing: 8

            TextEntry {
                id: newCmdField
                width: 370
                placeholderText: "new command (e.g. swayosd-server)"
                onAccepted: addBtn.clicked()
            }

            TextButton {
                id: addBtn
                label: "\uf067 add command"
                tooltip: "Append to autostart"
                onClicked: {
                    const c = newCmdField.text.trim();
                    if (c === "") return;
                    cmdModel.append({ cmd: c });
                    newCmdField.text = "";
                }
            }
        }
    }
}
