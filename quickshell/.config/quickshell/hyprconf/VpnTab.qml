import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// VPN tab of the Hypr Config dropdown (manages Proton VPN CLI).
//
// Drives `protonvpn` through Process with argv arrays (never shell
// strings). Status parsing follows the CLI output:
//   Disconnected → "Status: Disconnected"
//   Connected    → "Status: Connected" + "Server: NAME in LOCATION"
//                 + "Load: NN%" + "Protocol: xxx"
// `countries list` is a tabulate table; the header/separator rows are
// skipped when parsing.
ColumnLayout {
    id: root

    property string account: ""
    property bool connected: false
    property string server: ""
    property string location: ""
    property string load: ""
    property string protocol: ""
    property string status: ""
    property string statusKind: "info"   // info | success | error
    property string pendingTarget: ""
    property bool busy: false
    property var countries: []      // [{ name, code }]
    property string countryFilter: ""
    property string selectedCountry: ""
    property string serverEntry: ""
    property bool useP2p: false
    property bool useSecureCore: false
    property bool useTor: false
    property int selected: -1
    property int verifyCount: 0

    spacing: 10

    function stripAnsi(s) { return (s || "").replace(/\x1b\[[0-9;]*m/g, "") }

    function errorLine(s) {
        const lines = root.stripAnsi(s).split("\n");
        let first = "";
        for (let i = 0; i < lines.length; i++) {
            const t = lines[i].trim();
            if (t === "") continue;
            if (/fail|error|not found|no servers|authentic/i.test(t)) return t;
            if (first === "") first = t;
        }
        return first;
    }

    // ----- parsing -----

    function parseStatus(raw) {
        const lines = root.stripAnsi(raw).split("\n");
        let st = "", srv = "", loc = "", ld = "", proto = "";
        for (let i = 0; i < lines.length; i++) {
            const t = lines[i].trim();
            let m = t.match(/^Status:\s*(connected|disconnected)/i);
            if (m) st = m[1].toLowerCase();
            m = t.match(/^Server:\s*(.+?)\s+in\s+(.+)$/i);
            if (m) { srv = m[1].trim(); loc = m[2].trim(); }
            m = t.match(/^Load:\s*(.+)$/i);
            if (m) ld = m[1].trim();
            m = t.match(/^Protocol:\s*(.+)$/i);
            if (m) proto = m[1].trim();
        }
        root.connected = st === "connected";
        root.server = srv;
        root.location = loc;
        root.load = ld;
        root.protocol = proto;
    }

    function parseAccount(raw) {
        const m = root.stripAnsi(raw).match(/Account:\s*'?(.*?)'?\s*$/m);
        root.account = m ? m[1].trim() : "";
    }

    function parseCountries(raw) {
        const out = [];
        const lines = root.stripAnsi(raw).split("\n");
        for (let i = 0; i < lines.length; i++) {
            const plain = lines[i].trim();
            if (plain === "") continue;
            if (/^Country\b/i.test(plain)) continue;
            if (/^[-─ ]+$/.test(plain)) continue;
            const m = plain.match(/^(.*)\s+([A-Za-z]{2})$/);
            if (!m) continue;
            out.push({ name: m[1].trim(), code: m[2].toUpperCase() });
        }
        out.sort((a, b) => a.name.localeCompare(b.name));
        root.countries = out;
    }

    function filteredCountries() {
        const q = root.countryFilter.trim().toLowerCase();
        if (q === "") return root.countries;
        return root.countries.filter(c => c.name.toLowerCase().indexOf(q) >= 0
            || c.code.toLowerCase().indexOf(q) >= 0);
    }

    function stateDotColor() {
        if (root.busy) return Theme.accent2;
        if (root.statusKind === "error" && !root.connected) return Theme.err;
        if (root.connected) return Theme.live;
        return Theme.paused;
    }

    function stateLabel() {
        if (root.busy && root.pendingTarget !== "") return root.pendingTarget + "…";
        if (root.busy) return "working…";
        if (root.account === "") return "not signed in (protonvpn signin)";
        if (root.connected && root.server !== "") return "Connected — " + root.server;
        if (root.connected) return "Connected";
        return root.account + " — disconnected";
    }

    function statusColor() {
        if (root.busy) return Theme.accent2;
        if (root.statusKind === "error") return Theme.err;
        if (root.statusKind === "success") return Theme.live;
        return Theme.muted;
    }

    function setStatus(kind, msg) {
        root.statusKind = kind;
        root.status = msg;
    }

    // ----- actions -----

    function reload() {
        root.selected = -1;
        if (!root.busy) root.statusKind = "info";
        statusProc.running = true;
        accountProc.running = true;
        countriesProc.running = true;
    }

    function refreshStatus() {
        statusProc.running = true;
    }

    function extraFlags() {
        const out = [];
        if (root.useP2p) out.push("--p2p");
        if (root.useSecureCore) out.push("--securecore");
        if (root.useTor) out.push("--tor");
        return out;
    }

    function run(argv, what, target) {
        if (root.busy) return;
        root.busy = true;
        root.pendingTarget = target || what;
        root.setStatus("info", what + "…");
        actionProc.command = argv;
        actionProc.running = true;
    }

    function connectFastest() {
        if (root.busy) return;
        run(["protonvpn", "connect"].concat(root.extraFlags()), "connecting to fastest server", "connecting");
    }

    function connectRandom() {
        if (root.busy) return;
        run(["protonvpn", "connect", "--random"].concat(root.extraFlags()), "connecting to random server", "connecting");
    }

    function connectCountry(code) {
        if (root.busy) return;
        if (!/^[A-Za-z]{2}$/.test(code)) {
            root.setStatus("error", "unexpected country code: " + code);
            return;
        }
        const entry = root.countries.find(c => c.code === code);
        const name = entry ? entry.name : code;
        root.selectedCountry = code;
        run(["protonvpn", "connect", "--country", code].concat(root.extraFlags()),
            "connecting to " + name, "connecting to " + name);
    }

    function connectServer() {
        if (root.busy) return;
        const name = root.serverEntry.trim();
        if (name === "") {
            root.setStatus("error", "enter a server (e.g. CH#242)");
            return;
        }
        if (/^-/.test(name)) {
            root.setStatus("error", "unexpected server name: " + name);
            return;
        }
        run(["protonvpn", "connect", name], "connecting to " + name, "connecting to " + name);
    }

    function disconnect() {
        if (root.busy) return;
        run(["protonvpn", "disconnect"], "disconnecting", "disconnecting");
    }

    // ----- processes -----

    Process {
        id: statusProc
        command: ["protonvpn", "status"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.parseStatus(text);
                // a fresh successful poll clears a stale error
                if (root.connected && !root.busy && root.statusKind === "error") root.statusKind = "info";
            }
        }
        stderr: StdioCollector { waitForEnd: true }
        onExited: {
            // while a connect/disconnect is in flight, keep polling until
            // NetworkManager settles (the CLI can report the old state for
            // a couple of seconds right after the action exits)
            if (root.busy) verifyTimer.restart();
        }
    }

    Process {
        id: accountProc
        command: ["protonvpn", "info"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.parseAccount(text)
        }
        stderr: StdioCollector { waitForEnd: true }
    }

    Process {
        id: countriesProc
        command: ["protonvpn", "countries", "list"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.parseCountries(text)
        }
        stderr: StdioCollector {
            id: countriesErr
            waitForEnd: true
        }
        onExited: code => {
            if (code !== 0) {
                const detail = root.errorLine(countriesErr.text);
                root.setStatus("error", detail !== "" ? "error: " + detail : "failed to list countries");
            }
        }
    }

    Process {
        id: actionProc
        stdout: StdioCollector { id: actionOut; waitForEnd: true }
        stderr: StdioCollector { id: actionErr; waitForEnd: true }
        onExited: code => {
            if (code !== 0) {
                const txt = root.errorLine(actionErr.text) || root.errorLine(actionOut.text);
                root.busy = false;
                root.pendingTarget = "";
                root.setStatus("error", txt !== "" ? "error: " + txt : "failed (code " + code + ")");
                root.refreshStatus();
            } else {
                const txt = root.stripAnsi(actionOut.text).trim().split("\n")[0];
                const wasDisconnect = root.pendingTarget === "disconnecting";
                root.busy = false;
                root.pendingTarget = "";
                root.setStatus("success", txt !== "" ? txt : (wasDisconnect ? "Disconnected." : "Connected."));
                // poll a few times: the daemon can lag behind the CLI exit
                verifyCount = 0;
                root.refreshStatus();
                verifyTimer.restart();
            }
        }
    }

    Timer {
        id: verifyTimer
        interval: 2000
        repeat: true
        onTriggered: {
            root.refreshStatus();
            verifyCount++;
            if (verifyCount >= 3) verifyTimer.stop();
        }
    }

    Timer { id: refreshTimer; interval: 1500; onTriggered: root.refreshStatus() }

    // ----- status -----
    SectionCard {
        Layout.fillWidth: true
        title: "VPN"

        RowLayout {
            width: parent.width
            spacing: 8

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                width: 10
                height: 10
                radius: 5
                color: root.stateDotColor()
                Behavior on color { ColorAnimation { duration: 200 } }
            }

            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: root.stateLabel()
                color: root.connected && !root.busy ? Theme.live : Theme.text
                font.family: Theme.font
                font.pixelSize: 13
                font.bold: root.connected || root.busy
                Behavior on color { ColorAnimation { duration: 200 } }
            }

            Text {
                visible: root.busy
                text: "\uf110"
                color: Theme.accent2
                font.family: Theme.font
                font.pixelSize: 12
                RotationAnimation on rotation {
                    running: root.busy
                    loops: Animation.Infinite
                    from: 0
                    to: 360
                    duration: 1000
                }
            }

            Text {
                visible: !root.busy && root.connected && root.load !== ""
                text: root.load
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: 11
            }
        }

        Text {
            visible: !root.busy && root.connected && root.server !== ""
            width: parent.width
            elide: Text.ElideRight
            text: root.location !== "" ? root.server + " — " + root.location : root.server
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: 12
        }

        Text {
            visible: !root.busy && root.connected && root.protocol !== ""
            width: parent.width
            elide: Text.ElideRight
            text: "protocol " + root.protocol
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: 11
        }

        Text {
            visible: !root.busy && !root.connected && root.account !== ""
            width: parent.width
            elide: Text.ElideRight
            text: "account " + root.account + " — disconnected"
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: 12
        }

        Text {
            visible: !root.busy && root.account === ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: "not signed in — run `protonvpn signin` in a terminal"
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: 12
        }

        Row {
            spacing: 6
            opacity: root.busy ? 0.45 : 1
            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            TextButton {
                label: root.busy && root.pendingTarget !== "disconnecting" ? "\uf110 working" : "\uf021 connect"
                accent: !root.connected
                tooltip: root.busy ? "busy…" : ""
                onClicked: { if (!root.busy) root.connectFastest(); }
            }

            TextButton {
                label: "\uf074 random"
                tooltip: root.busy ? "busy…" : ""
                onClicked: { if (!root.busy) root.connectRandom(); }
            }

            TextButton {
                visible: root.connected || root.busy
                label: root.busy && root.pendingTarget === "disconnecting" ? "\uf110 working" : "\uf00d disconnect"
                tooltip: root.busy ? "busy…" : ""
                onClicked: { if (!root.busy) root.disconnect(); }
            }
        }

        Text {
            visible: root.status !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            elide: Text.ElideRight
            maximumLineCount: 2
            text: root.status
            color: root.statusColor()
            font.family: Theme.font
            font.pixelSize: 11
            Behavior on color { ColorAnimation { duration: 200 } }
        }

        Row {
            spacing: 14

            CheckRow {
                label: "P2P"
                checked: root.useP2p
                onToggled: c => root.useP2p = c
            }

            CheckRow {
                label: "Secure Core"
                checked: root.useSecureCore
                onToggled: c => root.useSecureCore = c
            }

            CheckRow {
                label: "Tor"
                checked: root.useTor
                onToggled: c => root.useTor = c
            }
        }
    }

    // ----- countries -----
    SectionCard {
        Layout.fillWidth: true
        title: "Country (" + root.filteredCountries().length + "/" + root.countries.length + ")"

        TextEntry {
            width: parent.width
            placeholderText: "filter country or code…"
            text: root.countryFilter
            onTextEdited: root.countryFilter = text
        }

        Text {
            visible: root.countries.length === 0
            width: parent.width
            text: "loading countries…"
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: 12
        }

        ListView {
            id: countryList
            visible: root.filteredCountries().length > 0
            width: parent.width
            height: Math.min(root.filteredCountries().length, 5) * 32
            clip: true
            model: root.filteredCountries()
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                width: countryList.width
                height: 32
                radius: 6
                color: row.modelData.code === root.selectedCountry || rowMa.containsMouse
                       ? Theme.hover : "transparent"
                Behavior on color { ColorAnimation { duration: 150 } }

                MouseArea {
                    id: rowMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: root.busy ? Qt.BusyCursor : Qt.PointingHandCursor
                    onClicked: {
                        if (root.busy) return;
                        root.selected = index;
                        root.connectCountry(row.modelData.code);
                    }
                }

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    anchors.right: codeLabel.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: row.modelData.name
                    color: root.busy && row.modelData.code === root.selectedCountry ? Theme.accent2
                           : row.modelData.code === root.selectedCountry ? Theme.accent : Theme.text
                    font.family: Theme.font
                    font.pixelSize: 12
                    Behavior on color { ColorAnimation { duration: 150 } }
                }

                Text {
                    id: codeLabel
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.busy && row.modelData.code === root.selectedCountry ? "…" : row.modelData.code
                    color: Theme.muted
                    font.family: Theme.font
                    font.pixelSize: 11
                }
            }
        }
    }

    // ----- manual server -----
    SectionCard {
        Layout.fillWidth: true
        title: "Server"

        RowLayout {
            width: parent.width
            spacing: 8

            TextEntry {
                Layout.fillWidth: true
                placeholderText: "server (e.g. CH#242)"
                text: root.serverEntry
                onTextEdited: root.serverEntry = text
                onAccepted: root.connectServer()
            }

            TextButton {
                label: "connect"
                accent: true
                tooltip: ""
                onClicked: root.connectServer()
            }
        }
    }

    Item { Layout.fillHeight: true }

    Row {
        Layout.fillWidth: true
        spacing: 12

        StatusLine {
            text: root.status
            busy: root.busy || actionProc.running
            labelWidth: 360
        }
    }
}
