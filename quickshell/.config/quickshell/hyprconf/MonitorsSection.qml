import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root

    property bool dirty: false
    property bool silent: false
    property var detectedMonitors: []

    spacing: 10

    function loadFrom(model, monitors) {
        root.silent = true;
        root.detectedMonitors = (monitors || []).slice();
        monModel.clear();
        const list = model.monitors || [];
        for (let i = 0; i < list.length; i++) {
            const m = list[i];
            monModel.append({
                output: m.output || "",
                mode: m.mode || "preferred",
                position: m.position || "auto",
                scale: String(m.scale !== undefined ? m.scale : "1")
            });
        }
        root.dirty = false;
        root.silent = false;
    }

    function writeTo(model) {
        const out = [];
        for (let i = 0; i < monModel.count; i++) {
            const r = monModel.get(i);
            out.push({
                output: r.output,
                mode: r.mode || "preferred",
                position: r.position || "auto",
                scale: r.scale || "1"
            });
        }
        model.monitors = out;
    }

    ListModel {
        id: monModel
        onDataChanged: if (!root.silent) root.dirty = true
        onCountChanged: if (!root.silent) root.dirty = true
    }

    component MonitorRow: Row {
        id: mrow
        required property int index
        required property string output
        required property string mode
        required property string position
        required property string scale

        spacing: 6

        MonCombo {
            implicitWidth: 135
            model: {
                const names = root.detectedMonitors.slice();
                if (mrow.output && names.indexOf(mrow.output) < 0)
                    names.unshift(mrow.output);
                return names.length ? names : [mrow.output || "DP-1"];
            }
            Component.onCompleted: currentIndex = find(mrow.output)
            onActivated: monModel.setProperty(mrow.index, "output", currentText)
        }

        TextEntry {
            width: 150
            text: mrow.mode
            placeholderText: "1920x1080@144"
            onEditingFinished: if (text !== mrow.mode) monModel.setProperty(mrow.index, "mode", text)
        }

        TextEntry {
            width: 105
            text: mrow.position
            placeholderText: "0x0"
            onEditingFinished: if (text !== mrow.position) monModel.setProperty(mrow.index, "position", text)
        }

        TextEntry {
            width: 65
            text: mrow.scale
            placeholderText: "1"
            onEditingFinished: if (text !== mrow.scale) monModel.setProperty(mrow.index, "scale", text)
        }

        TextButton {
            label: "\uf1f8"
            textSize: 12
            tooltip: "Remove monitor rule"
            onClicked: monModel.remove(mrow.index)
        }
    }

    SectionCard {
        Layout.fillWidth: true
        title: "Monitors (compositor)"

        Row {
            spacing: 6
            visible: monModel.count > 0

            Text { width: 135; text: "Output"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 10 }
            Text { width: 150; text: "Mode (res@hz)"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 10 }
            Text { width: 105; text: "Position"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 10 }
            Text { width: 65; text: "Scale"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 10 }
        }

        Repeater {
            model: monModel
            delegate: MonitorRow {}
        }

        Row {
            spacing: 10

            TextButton {
                label: "\uf067 add monitor"
                tooltip: "Add monitor rule"
                onClicked: monModel.append({
                    output: root.detectedMonitors[0] || "DP-1",
                    mode: "preferred",
                    position: "auto",
                    scale: "1"
                })
            }

            Text {
                height: 26
                verticalAlignment: Text.AlignVCenter
                text: root.detectedMonitors.length
                    ? "detected: " + root.detectedMonitors.join(", ")
                    : "hyprland monitors unavailable, pick manually"
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: 11
                elide: Text.ElideRight
                width: 340
            }
        }
    }
}
