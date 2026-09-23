import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Io

// Bluetooth tab of the Hypr Config dropdown (replaces bzmenu).
//
// Quickshell talks to BlueZ over D-Bus directly. Clicking a device connects
// (or disconnects) it; the ✕ forgets a known device.
//
// Pairing: BlueZ refuses to attach the HID profile to a device that is not
// bonded, and Quickshell 0.3.1 registers no pairing *agent*, so calling
// `Device1.Connect()` on a fresh device connects nothing — bluetoothd just
// logs "Rejected connection from !bonded device". Bonded devices keep using
// Quickshell natively; the un-bonded case falls back to `bluetoothctl`
// (pair → trust → connect), which registers its own agent and completes
// Just Works pairing. Devices demanding host PIN/passkey entry still can't
// be paired from here.
ColumnLayout {
    id: root

    property var adapter: Bluetooth.defaultAdapter
    // Snapshot of adapter.devices. Only the *set* needs rebuilding — the
    // delegates bind straight to the live device objects, so connected /
    // pairing / battery changes repaint on their own.
    property var devices: []
    property int selected: 0
    property string status: ""

    // Un-bonded devices go through `bluetoothctl` (see the header comment);
    // pairStep walks pair → trust → connect and is 0 when idle.
    property string pairTarget: ""
    property int pairStep: 0

    readonly property bool on: root.adapter !== null && root.adapter.enabled

    spacing: 10

    function label(d) { return d ? (d.name || d.deviceName || d.address) : "" }

    function validAddress(a) {
        return typeof a === "string" && /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/i.test(a);
    }

    function plain(s) {
        return (s || "").replace(/\x1b\[[0-9;]*m/g, "").replace(/\r/g, "");
    }

    // bluetoothctl mixes progress lines with errors; surface the first line
    // that actually reads like an error, else the first non-empty one
    function errorLine(s) {
        const lines = root.plain(s).split("\n");
        let first = "";
        for (let i = 0; i < lines.length; i++) {
            const t = lines[i].trim();
            if (t === "") continue;
            if (/fail|error|not available|authentication|refused/i.test(t)) return t;
            if (first === "") first = t;
        }
        return first;
    }

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
        return "parear";
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
        } else if (d.bonded) {
            // a real bond exists — BlueZ can bring the HID link up on its own
            // (bluez also sets a transient `paired` without a bond, which is
            // not enough for HID, so only `bonded` takes this path)
            d.connect();
            root.status = "conectando " + root.label(d) + "…";
        } else {
            // fresh device: Connect() alone never bonds it (no agent in 0.3.1)
            root.pair(d);
        }
    }

    function pair(d) {
        const mac = d ? d.address : "";
        if (!root.validAddress(mac)) {
            root.status = "endereço bluetooth inesperado: " + mac;
            return;
        }
        root.pairTarget = mac;
        root.pairStep = 1;
        root.status = "pareando " + root.label(d) + "…";
        pairProc.command = ["bluetoothctl", "--timeout", "30", "pair", mac];
        pairProc.running = true;
    }

    function finishPair(code, detail) {
        const wasConnecting = root.pairStep === 3;
        root.pairStep = 0;
        root.pairTarget = "";
        if (code !== 0) {
            root.status = detail !== "" ? "erro: " + detail
                                        : "falhou (código " + code + ")";
        } else {
            root.status = wasConnecting ? "pareado e conectado" : "pareado";
        }
        root.refresh();
    }

    // one `bluetoothctl` invocation per step: each one registers an agent for
    // the whole operation, which is what actually creates the bond. `trust`
    // is best-effort (lets BlueZ auto-connect the keyboard next time).
    Process {
        id: pairProc

        stdout: StdioCollector { id: pairOut; waitForEnd: true }
        stderr: StdioCollector { id: pairErr; waitForEnd: true }

        onExited: code => {
            const out = root.plain(pairOut.text);
            const err = root.plain(pairErr.text);
            const already = /AlreadyExists/i.test(err) || /AlreadyExists/i.test(out);
            const detail = root.errorLine(err) || root.errorLine(out);

            if (root.pairStep === 1 && (code === 0 || already)) {
                // a leftover transient "paired" flag makes `pair` report
                // AlreadyExists; trust + connect still settle a real bond
                root.pairStep = 2;
                root.status = "confiando " + root.pairTarget + "…";
                pairProc.command = ["bluetoothctl", "trust", root.pairTarget];
                pairProc.running = true;
            } else if (root.pairStep === 2) {
                // trust is best-effort: a failure here shouldn't stop connect
                root.pairStep = 3;
                root.status = "conectando " + root.pairTarget + "…";
                pairProc.command = ["bluetoothctl", "--timeout", "30",
                                    "connect", root.pairTarget];
                pairProc.running = true;
            } else {
                root.finishPair(code, detail);
            }
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
