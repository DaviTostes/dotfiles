import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root

    property bool dirty: false
    property bool silent: false
    property var curves: []
    property var curveNames: ["default"]

    spacing: 10

    function loadFrom(model) {
        root.silent = true;
        root.curves = (model.curves || []).slice();
        const names = ["default"];
        for (let i = 0; i < root.curves.length; i++) {
            const n = root.curves[i].name;
            if (n && names.indexOf(n) < 0) names.push(n);
        }
        root.curveNames = names;

        leavesModel.clear();
        const list = model.animations || [];
        for (let i = 0; i < list.length; i++) {
            const a = list[i];
            leavesModel.append({
                leaf: a.leaf || "",
                enabled: a.enabled !== false,
                speed: Number(a.speed) || 1,
                bezier: a.bezier || "default",
                style: a.style || ""
            });
        }
        root.dirty = false;
        root.silent = false;
    }

    function writeTo(model) {
        model.curves = root.curves.slice();
        const out = [];
        for (let i = 0; i < leavesModel.count; i++) {
            const r = leavesModel.get(i);
            out.push({
                leaf: r.leaf,
                enabled: r.enabled,
                speed: r.speed,
                bezier: r.bezier || "default",
                style: r.style || ""
            });
        }
        model.animations = out;
    }

    ListModel {
        id: leavesModel
        onDataChanged: if (!root.silent) root.dirty = true
        onCountChanged: if (!root.silent) root.dirty = true
    }

    component AnimLeafRow: Row {
        id: arow
        required property int index
        required property string leaf
        required property bool enabled
        required property real speed
        required property string bezier
        required property string style

        spacing: 6

        Item {
            width: 128
            height: 26

            CheckRow {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                label: arow.leaf
                checked: arow.enabled
                onToggled: c => leavesModel.setProperty(arow.index, "enabled", c)
            }
        }

        NumField {
            from: 0.1
            to: 50
            step: 0.5
            decimals: 2
            value: arow.speed
            onValueEdited: v => leavesModel.setProperty(arow.index, "speed", v)
        }

        MonCombo {
            implicitWidth: 122
            model: {
                const names = root.curveNames.slice();
                if (arow.bezier && names.indexOf(arow.bezier) < 0)
                    names.unshift(arow.bezier);
                return names;
            }
            Component.onCompleted: currentIndex = find(arow.bezier)
            onActivated: leavesModel.setProperty(arow.index, "bezier", currentText)
        }

        TextEntry {
            width: 92
            text: arow.style
            placeholderText: "style"
            onEditingFinished: if (text !== arow.style) leavesModel.setProperty(arow.index, "style", text)
        }

        TextButton {
            label: "\uf1f8"
            textSize: 12
            tooltip: "Remove leaf"
            onClicked: leavesModel.remove(arow.index)
        }
    }

    SectionCard {
        Layout.fillWidth: true
        title: "Animations (per leaf)"

        Repeater {
            model: leavesModel
            delegate: AnimLeafRow {}
        }

        Row {
            spacing: 8

            TextEntry {
                id: newLeafField
                width: 160
                placeholderText: "leaf name (e.g. fade)"
            }

            TextButton {
                label: "\uf067 add leaf"
                tooltip: "Add animation leaf"
                onClicked: {
                    const name = newLeafField.text.trim();
                    if (name === "") return;
                    leavesModel.append({
                        leaf: name,
                        enabled: true,
                        speed: 3,
                        bezier: "default",
                        style: ""
                    });
                    newLeafField.text = "";
                }
            }

            Text {
                height: 26
                verticalAlignment: Text.AlignVCenter
                text: "curves: " + root.curveNames.join(", ")
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: 11
                elide: Text.ElideRight
                width: 240
            }
        }
    }
}
