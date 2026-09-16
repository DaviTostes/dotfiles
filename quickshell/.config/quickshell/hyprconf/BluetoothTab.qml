import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell
import Quickshell.Bluetooth

// Bluetooth tab of the Hypr Config dropdown (replaces bzmenu).
//
// Quickshell talks to BlueZ over D-Bus directly, so there is no external
// tool involved. Clicking a device connects it (BlueZ pairs on demand) or
// disconnects it; the ✕ forgets a known device.
//
// Caveat from 0.3.1: quickshell ships no pairing *agent*, so a device that
// needs PIN/passkey confirmation cannot be paired from here — already
// paired devices (and Just Works ones) are fine.
ColumnLayout {
    id: root

    property var adapter: Bluetooth.defaultAdapter
    // Snapshot of adapter.devices. Only the *set* needs rebuilding — the
    // delegates bind straight to the live device objects, so connected /
    // pairing / battery changes repaint on their own.
    property var devices: []
    property int selected: 0
    property string status: ""

    readonly property bool on: root.adapter !== null && root.adapter.enabled

    spacing: 10

    function label(d) { return d ? (d.name || d.deviceName || d.address) : "" }

    // BlueZ reports an icon *name* per device class; theme lookups for those
    // names are unreliable here, so map them to Nerd Font glyphs (same
    // approach as the panel's icon buttons).
    function glyph(d) {
        const i = d ? (d.icon || "") : "";
        if (i.indexOf("headset") >= 0 || i.indexOf("headphone") >= 0) return "\uf025";
        if (i.indexOf("audio") >= 0) return "\uf001";
        if (i.indexOf("keyboard") >= 0) return "\uf11c";
        if (i.indexOf("mouse") >= 0) return "\uf245";
        if (i.indexOf("gaming") >= 0) return "\uf11b";
        if (i.indexOf("phone") >= 0) return "\uf10b";
        if (i.indexOf("computer") >= 0) return "\uf109";
        if (i.indexOf("printer") >= 0) return "\uf02f";
        return "\uf293";   // bluetooth
    }

    function refresh() {
        const out = [];

        if (root.adapter) {
            const vals = root.adapter.devices.values;
            for (let i = 0; i < vals.length; i++) {
                const d = vals[i];
                if (d && !d.blocked) out.push(d);
            }
            // connected first, then known, then alphabetical
            out.sort((a, b) => (b.connected - a.connected)
                             || ((b.bonded || b.paired) - (a.bonded || a.paired))
                             || root.label(a).localeCompare(root.label(b)));
        }

        root.devices = out;
        if (root.selected >= out.length) root.selected = 0;
    }

    // called when the dropdown opens (HyprConfig reloads every tab)
    function reload() {
        root.status = "";
        root.selected = 0;
        root.refresh();
    }

    function adapterText() {
        const a = root.adapter;
        if (!a) return "nenhum adaptador";
        if (a.state === BluetoothAdapterState.Enabling) return "ligando…";
        if (a.state === BluetoothAdapterState.Disabling) return "desligando…";
        if (!a.enabled) return "desligado";
        if (a.discovering) return "escaneando…";
        return "ligado";
    }

    function stateText(d) {
        if (d.pairing) return "pareando…";
        if (d.state === BluetoothDeviceState.Connecting) return "conectando…";
        if (d.state === BluetoothDeviceState.Disconnecting) return "desconectando…";
        if (d.connected) return d.batteryAvailable ? Math.round(d.battery) + "%" : "conectado";
        if (d.bonded || d.paired) return "pareado";
        return "novo";
    }

    function stateColor(d) {
        if (d.pairing) return Theme.accent2;
        if (d.state === BluetoothDeviceState.Connecting
                || d.state === BluetoothDeviceState.Disconnecting) return Theme.accent2;
        if (d.connected) return Theme.live;
        if (d.bonded || d.paired) return Theme.muted;
        return Theme.idleText;
    }

    function activate(d) {
        if (!d) return;

        if (d.pairing) {
            d.cancelPair();
            root.status = "cancelado: " + root.label(d);
        } else if (d.connected) {
            d.disconnect();
            root.status = "desconectando " + root.label(d) + "…";
        } else {
            d.connect();
            root.status = "conectando " + root.label(d) + "…";
        }
    }

    Component.onCompleted: root.refresh()

    Connections {
        target: Bluetooth
        function onDefaultAdapterChanged() { root.refresh(); }
    }

    Connections {
        // devices come and go while scanning
        target: root.adapter ? root.adapter.devices : null
        function onValuesChanged() { root.refresh(); }
    }

    // ----- adapter -----
    SectionCard {
        Layout.fillWidth: true
        title: "Adaptador"

        RowLayout {
            width: parent.width
            spacing: 8

            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: root.adapter ? root.adapter.name : "nenhum adaptador"
                color: root.on ? Theme.text : Theme.idleText
                font.family: Theme.font
                font.pixelSize: 13
            }

            Text {
                text: root.adapterText()
                color: root.on ? Theme.muted : Theme.idleText
                font.family: Theme.font
                font.pixelSize: 11
            }

            TextButton {
                label: root.on ? "\uf011 desligar" : "\uf011 ligar"
                accent: root.on
                tooltip: ""
                onClicked: if (root.adapter) root.adapter.enabled = !root.adapter.enabled
            }

            TextButton {
                visible: root.on
                label: root.adapter && root.adapter.discovering ? "\uf00d parar" : "\uf021 escanear"
                accent: root.adapter && root.adapter.discovering
                tooltip: ""
                onClicked: if (root.adapter) root.adapter.discovering = !root.adapter.discovering
            }
        }
    }

    // ----- devices -----
    SectionCard {
        Layout.fillWidth: true
        title: "Aparelhos (" + root.devices.length + ")"

        Text {
            visible: root.devices.length === 0
            width: parent.width
            text: root.on ? "nenhum aparelho — use «escanear» para procurar"
                          : "ligue o adaptador para ver os aparelhos"
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: 12
        }

        ListView {
            id: list

            visible: root.devices.length > 0
            width: parent.width
            height: Math.min(root.devices.length, 7) * 34
            clip: true
            model: root.devices
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                id: row

                required property var modelData
                required property int index

                width: list.width
                height: 34
                radius: 6
                color: index === root.selected || rowMa.containsMouse
                       ? Theme.hover : "transparent"
                Behavior on color { ColorAnimation { duration: 150 } }

                MouseArea {
                    id: rowMa

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.selected = index;
                        root.activate(row.modelData);
                    }
                }

                Text {
                    id: devIcon

                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.glyph(row.modelData)
                    color: row.modelData.connected ? Theme.accent : Theme.muted
                    font.family: Theme.font
                    font.pixelSize: 14
                    Behavior on color { ColorAnimation { duration: 150 } }
                }

                Text {
                    id: devName

                    anchors.left: devIcon.right
                    anchors.leftMargin: 8
                    anchors.right: devState.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: root.label(row.modelData)
                    color: row.modelData.connected ? Theme.accent : Theme.text
                    font.family: Theme.font
                    font.pixelSize: 12
                }

                Text {
                    id: devState

                    anchors.right: forgetBtn.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.stateText(row.modelData)
                    color: root.stateColor(row.modelData)
                    font.family: Theme.font
                    font.pixelSize: 11
                }

                TextButton {
                    id: forgetBtn

                    anchors.right: parent.right
                    anchors.rightMargin: 2
                    anchors.verticalCenter: parent.verticalCenter
                    visible: row.modelData.paired || row.modelData.bonded
                    label: "\uf00d"
                    textSize: 11
                    tooltip: ""
                    onClicked: {
                        root.status = "esquecendo " + root.label(row.modelData) + "…";
                        row.modelData.forget();
                    }
                }
            }
        }
    }

    // keeps the footer pinned to the bottom like the other tabs
    Item { Layout.fillHeight: true }

    Row {
        Layout.fillWidth: true
        spacing: 12

        StatusLine {
            text: root.status
            labelWidth: 360
        }
    }
}
