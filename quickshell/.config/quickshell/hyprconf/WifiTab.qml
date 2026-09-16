import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Wi-Fi tab of the Hypr Config dropdown (replaces iwmenu).
//
// This talks to **iwd** through `iwctl`, not to Quickshell.Networking: that
// module only supports NetworkManager (its backend enum is
// None/NetworkManager) and this machine runs iwd with NetworkManager
// inactive, so Networking.devices would be empty.
//
// The iwctl tables are fixed-width and ANSI-coloured — the signal "stars"
// are dimmed for the unfilled slots — so the parse below strips colour for
// the text fields and reads the raw stars for the level.
ColumnLayout {
    id: root

    property string station: ""     // wlan0, discovered from `station list`
    property string state: ""       // connected / disconnected / connecting
    property string current: ""     // SSID currently connected
    property var known: []          // SSIDs iwd already has credentials for
    property var networks: []       // [{ ssid, security, level, known }]
    property string pending: ""     // SSID waiting for a passphrase
    property string status: ""
    property int selected: -1

    spacing: 10

    readonly property bool connected: root.current !== ""

    function stripAnsi(s) { return (s || "").replace(/\x1b\[[0-9;]*m/g, "") }

    // ----- parsing -----

    // `station list` → the first station-mode device
    function pickStation(raw) {
        const lines = root.stripAnsi(raw).split("\n");
        let found = "";
        for (let i = 0; i < lines.length; i++) {
            const m = lines[i].match(/^\s*([A-Za-z0-9._-]+)\s+(connected|disconnected|connecting|scanning)\b/i);
            if (m) found = m[1];
        }
        root.station = found;
        if (found === "") root.status = "nenhuma interface wi-fi encontrada";
    }

    // `station <dev> show` → state + connected network
    function parseShow(section) {
        let st = "", cur = "";
        const lines = root.stripAnsi(section).split("\n");
        for (let i = 0; i < lines.length; i++) {
            let m = lines[i].match(/\bState\s+(connected|disconnected|connecting|disconnecting)\b/i);
            if (m) st = m[1].toLowerCase();
            m = lines[i].match(/\bConnected network\s+(.+?)\s*$/i);
            if (m) cur = m[1];
        }
        root.state = st;
        root.current = st === "connected" ? cur : "";
    }

    // `station <dev> get-networks` → the table rows
    function parseNetworks(section) {
        const out = [];
        const lines = section.split("\n");

        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            const plain = root.stripAnsi(line).trim();
            if (plain === "") continue;
            if (/^[\u2500\u2501-]+$/.test(plain)) continue;          // table rule
            if (/^Network name\b/i.test(plain)) continue;            // header

            const m = plain.match(/^(.+?)\s{2,}(\S+)\s{2,}(\*+)\s*$/);
            if (!m) continue;

            const ssid = m[1].trim();
            const security = m[2];
            const total = m[3].length;
            // stars inside an ANSI span are iwctl's *unfilled* slots
            const dimMatch = line.match(/\x1b\[[0-9;]*m(\*+)\x1b\[0m/);
            const dim = dimMatch ? dimMatch[1].length : 0;
            const bright = Math.max(total - dim, 0);

            out.push({
                ssid: ssid,
                security: security,
                level: total > 0 ? Math.round(bright * 4 / total) : 0,
            });
        }

        // strongest first, known networks before unknown ones
        out.sort((a, b) => (b.level - a.level) || a.ssid.localeCompare(b.ssid));
        for (let i = 0; i < out.length; i++) {
            out[i].known = root.known.indexOf(out[i].ssid) !== -1;
        }
        root.networks = out;
    }

    // `known-networks list` → SSIDs with stored credentials
    function parseKnown(section) {
        const out = [];
        const lines = root.stripAnsi(section).split("\n");
        for (let i = 0; i < lines.length; i++) {
            const plain = lines[i].trim();
            if (plain === "") continue;
            if (/^[\u2500\u2501-]+$/.test(plain)) continue;
            if (/^Name\b/i.test(plain)) continue;
            const m = plain.match(/^(.+?)\s{2,}/);
            if (m) out.push(m[1].trim());
        }
        root.known = out;
    }

    function parseProbe(raw) {
        const parts = raw.split("@@@");
        root.parseShow(parts[0] || "");
        root.parseNetworks(parts[1] || "");
        root.parseKnown(parts[2] || "");
        for (let i = 0; i < root.networks.length; i++) {
            root.networks[i].known = root.known.indexOf(root.networks[i].ssid) !== -1;
        }
    }

    // ----- actions -----

    function probe() {
        if (root.station !== "") probeProc.running = true;
    }

    function reload() {
        root.status = "";
        root.pending = "";
        listProc.running = true;
    }

    function scan() {
        root.status = "escaneando…";
        run(["iwctl", "station", root.station, "scan"]);
    }

    function disconnect() {
        root.status = "desconectando…";
        run(["iwctl", "station", root.station, "disconnect"]);
    }

    function pick(n) {
        if (!root.station || !n) return;
        if (n.ssid === root.current) { root.disconnect(); return; }
        // known networks connect straight away; anything else asks for the
        // passphrase (iwctl --passphrase takes it non-interactively)
        if (n.known) { root.connect(n.ssid, ""); return; }
        root.pending = n.ssid;
        passEntry.text = "";
        Qt.callLater(() => passEntry.forceActiveFocus());
    }

    function connect(ssid, psk) {
        root.pending = "";
        root.status = "conectando em " + ssid + "…";
        run(psk !== ""
            ? ["iwctl", "--passphrase", psk, "--dont-ask", "station", root.station, "connect", ssid]
            : ["iwctl", "--dont-ask", "station", root.station, "connect", ssid]);
    }

    function run(argv) {
        actionProc.command = argv;
        actionProc.running = true;
    }

    function securityText(n) {
        if (n.security === "open") return "aberta";
        if (n.security === "psk") return "WPA";
        return n.security;
    }

    // ----- processes -----

    Process {
        id: listProc

        command: ["iwctl", "station", "list"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.pickStation(text)
        }
        onExited: root.probe()
    }

    Process {
        id: probeProc

        // one shot for the three tables, split on our own separator. the
        // device name comes from pickStation() and is validated there.
        command: root.station !== ""
                 ? ["sh", "-c", "iwctl station " + root.station + " show; echo '@@@'; "
                      + "iwctl station " + root.station + " get-networks; echo '@@@'; "
                      + "iwctl known-networks list"]
                 : []
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.parseProbe(text)
        }
    }

    Process {
        id: actionProc

        // a scan can take a few seconds; the exit handler refreshes after
        stdout: StdioCollector { id: actionOut; waitForEnd: true }
        stderr: StdioCollector { id: actionErr; waitForEnd: true }
        onExited: code => {
            if (code !== 0) {
                // iwctl prints errors on *stdout* ("Invalid network name …")
                const txt = root.stripAnsi(actionErr.text).trim()
                          || root.stripAnsi(actionOut.text).trim();
                const first = txt.split("\n")[0];
                root.status = first !== "" ? "erro: " + first
                                           : "falhou (código " + code + ")";
            }
            refreshTimer.restart();
        }
    }

    Timer { id: refreshTimer; interval: 1200; onTriggered: root.probe() }

    // device names come from iwctl, but never trust text in a shell line
    onStationChanged: if (root.station !== "" && !/^[A-Za-z0-9._-]+$/.test(root.station)) {
        root.status = "nome de interface inesperado: " + root.station;
        root.station = "";
    }

    // ----- station -----
    SectionCard {
        Layout.fillWidth: true
        title: "Wi-Fi"

        RowLayout {
            width: parent.width
            spacing: 8

            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: root.station === "" ? "nenhuma interface"
                      : root.connected ? root.station + " — " + root.current
                      : root.station + " — " + (root.state === "" ? "desconhecido" : root.state)
                color: root.connected ? Theme.live : Theme.text
                font.family: Theme.font
                font.pixelSize: 13
            }

            TextButton {
                visible: root.station !== "" && !root.connected
                label: "\uf021 escanear"
                tooltip: ""
                onClicked: root.scan()
            }

            TextButton {
                visible: root.connected
                label: "\uf00d desconectar"
                tooltip: ""
                onClicked: root.disconnect()
            }
        }
    }

    // ----- networks -----
    SectionCard {
        Layout.fillWidth: true
        title: "Redes (" + root.networks.length + ")"

        Text {
            visible: root.networks.length === 0
            width: parent.width
            text: root.station === "" ? "sem interface wi-fi"
                                      : "nenhuma rede — use «escanear»"
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: 12
        }

        ListView {
            id: list

            visible: root.networks.length > 0
            width: parent.width
            height: Math.min(root.networks.length, 6) * 32
            clip: true
            model: root.networks
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                id: row

                required property var modelData
                required property int index

                width: list.width
                height: 32
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
                        root.pick(row.modelData);
                    }
                }

                SignalBars {
                    id: bars

                    anchors.left: parent.left
                    anchors.leftMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    level: row.modelData.level
                }

                Text {
                    id: ssid

                    anchors.left: bars.right
                    anchors.leftMargin: 10
                    anchors.right: badge.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: row.modelData.ssid
                    color: row.modelData.ssid === root.current ? Theme.accent : Theme.text
                    font.family: Theme.font
                    font.pixelSize: 12
                }

                Row {
                    id: badge

                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    Text {
                        text: row.modelData.ssid === root.current ? "conectada" : ""
                        visible: text !== ""
                        color: Theme.live
                        font.family: Theme.font
                        font.pixelSize: 11
                    }

                    Text {
                        text: root.securityText(row.modelData)
                        color: Theme.muted
                        font.family: Theme.font
                        font.pixelSize: 11
                    }
                }
            }
        }

        // ----- passphrase prompt (unknown network) -----
        RowLayout {
            width: parent.width
            spacing: 8
            visible: root.pending !== ""

            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: "senha de «" + root.pending + "»"
                color: Theme.accent2
                font.family: Theme.font
                font.pixelSize: 12
            }

            TextEntry {
                id: passEntry

                password: true
                width: 220
                placeholderText: "senha"
                onAccepted: root.connect(root.pending, passEntry.text)
            }

            TextButton {
                label: "conectar"
                accent: true
                tooltip: ""
                onClicked: root.connect(root.pending, passEntry.text)
            }

            TextButton {
                label: "cancelar"
                tooltip: ""
                onClicked: root.pending = ""
            }
        }
    }

    Item { Layout.fillHeight: true }

    Row {
        Layout.fillWidth: true
        spacing: 12

        StatusLine {
            text: root.status
            labelWidth: 360
        }
    }

    // four ascending bars, `level` of them lit
    component SignalBars: Row {
        id: bars

        property int level: 0

        spacing: 2

        Repeater {
            model: 4

            Item {
                required property int index

                width: 3
                height: 12

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 4 + index * 2
                    radius: 1
                    color: index < bars.level ? Theme.accent : Theme.border
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
            }
        }
    }
}
