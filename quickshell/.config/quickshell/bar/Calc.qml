import Quickshell.Io
import QtQuick
import QtQuick.Controls.Basic
import "../hyprconf"

// calculator tab of the intelligence central.
//
// A terminal-style front-end to `calc` — the arbitrary-precision calculator
// written in C (the /usr/bin/calc CLI). One long-lived `calc -q -c -u`
// process is driven over stdin, so variables, user functions and precision
// set on one line survive into the next:
//   -q  skip the startup resource files (no banner, no user rc surprises)
//   -c  survive scan/parse errors instead of aborting the whole session
//   -u  unbuffered stdout, so a result is readable the moment it is printed
//
// Every submitted line is echoed into the scrollback transcript along with
// its output (or the error calc reported), and `show globals` keeps the
// variables column live. Enter evaluates; Up/Down walk the input history.
//
// The real editor lives in the BAR (Opencode.qml's hiddenInput) while the
// panel is docked — the popup window is keyboard-less, so this tab only
// mirrors `draft` and forwards keys through the host, exactly like the
// translate tab.
Item {
  id: root

  signal copyRequested(string text)
  signal cursorMoved(int pos)

  // routed from the bar's hiddenInput while the calc tab is open
  property string draft: ""
  property bool panelActive: false

  // sentinel calc echoes after a line so output can be attributed to one
  // submission even though the process keeps running. Unique per panel
  // instance so a user printing the literal sentinel cannot be mistaken for
  // calc's own terminator.
  readonly property string doneMark:
      "__QS_CALC_" + Math.random().toString(36).slice(2, 10) + "__"

  // ---------- process / evaluation state ----------
  property bool procUp: false
  property string pending: ""       // "" | "eval" | "vars"
  property int pendingIdx: -1       // transcript row the eval belongs to
  property string outBuf: ""
  property string errBuf: ""
  property string varsBuf: ""
  property string varsValBuf: ""    // second pass: numeric values in real mode
  property var evalQueue: []        // [{ idx, line }] submissions in flight
  property var vars: []             // [{ name, type, value }]
  property var history: []          // submitted lines for ↑/↓ recall
  property int histIdx: -1          // -1 = editing a fresh line
  property bool syncing: false      // guards the draft <-> field mirror
  property bool pinned: true        // transcript follows the tail

  readonly property int inputH: 38

  ListModel { id: transcriptModel }

  Component.onCompleted: transcriptModel.append({
    input: "", output: "calc — arbitrary-precision CLI (C)\n"
        + "Enter evaluates · ↑/↓ history · Ctrl+L clears the screen",
    error: "", running: false, note: true
  })

  // ---------- mirror from the bar's hidden editor ----------
  onDraftChanged: if (!root.syncing) {
    root.syncing = true;
    entryField.text = root.draft;
    root.syncing = false;
  }

  // cursor mirror from the bar's real editor (docked mode)
  function setCursorPos(p) { entryField.cursorPosition = p; }
  function focusEntry() { entryField.forceActiveFocus(); }

  // ---------- evaluation ----------
  // calc aborts — and, worse, keeps waiting for the rest of the expression —
  // on an unmatched opener, an unterminated string, or an unterminated
  // `/* */` comment. Reject those before they ever reach the persistent
  // process, which one bad line would otherwise desync. Brackets inside
  // string literals are ignored (calc accepts `print "(x)"`), and `//` is
  // integer division in calc, not a comment, so it is left alone.
  function balanced(s) {
    let depth = 0, inStr = false, inBlock = false;
    for (let i = 0; i < s.length; i++) {
      const c = s[i], n = s[i + 1];
      if (inBlock) {
        if (c === "*" && n === "/") { inBlock = false; i++; }
        continue;
      }
      if (inStr) {
        if (c === "\\") { i++; continue; }   // skip the escaped character
        if (c === '"') inStr = false;
        continue;
      }
      if (c === '"') { inStr = true; continue; }
      if (c === "/" && n === "*") { inBlock = true; i++; continue; }
      if (c === "(" || c === "[" || c === "{") depth++;
      else if (c === ")" || c === "]" || c === "}") depth--;
    }
    if (s.trim().endsWith("\\")) return false;
    return depth === 0 && !inStr && !inBlock;
  }

  function submit() {
    const line = root.draft;
    if (line.trim() === "") return;

    if (line.trim() === "clear" || line.trim() === ":clear") {
      root.draft = "";
      root.clearScreen();
      return;
    }
    if (!root.balanced(line)) {
      transcriptModel.append({
        input: line, output: "",
        error: "unbalanced expression — close the ( [ { or quote first",
        running: false, note: false
      });
      root.draft = "";
      root.scrollTail();
      return;
    }

    root.history = root.history.concat([line]);
    if (root.history.length > 500) root.history = root.history.slice(-500);
    root.histIdx = -1;
    root.draft = "";

    transcriptModel.append({ input: line, output: "", error: "", running: true, note: false });
    root.trimTranscript();
    const idx = transcriptModel.count - 1;
    root.evalQueue = root.evalQueue.concat([{ idx: idx, line: line }]);
    root.scrollTail();
    root.pump();
  }

  function clearScreen() {
    transcriptModel.clear();
    // every queued submission lost its row too
    root.evalQueue = [];
    // an in-flight eval's row no longer exists: drop its output target so the
    // result cannot be written into a later, unrelated row (the old code
    // relied on a bounds check that stops being true once new rows are added)
    root.pendingIdx = -1;
    root.outBuf = "";
    root.errBuf = "";
    root.vars = [];
  }

  // bound the transcript so a long-lived tab cannot grow without limit.
  // Removing from the front shifts every later index down, so the in-flight
  // eval target and the queued jobs are adjusted to match.
  function trimTranscript() {
    const max = 300;
    while (transcriptModel.count > max) {
      transcriptModel.remove(0);
      if (root.pendingIdx >= 0) root.pendingIdx -= 1;
      for (const j of root.evalQueue) j.idx -= 1;
    }
  }

  // send the next queued submission (one at a time — the transcript row it
  // belongs to travels with it so out-of-order replies can't mismatch)
  function pump() {
    if (root.pending !== "" || root.evalQueue.length === 0) return;
    const job = root.evalQueue[0];
    root.evalQueue = root.evalQueue.slice(1);
    root.pending = "eval";
    root.pendingIdx = job.idx;
    root.outBuf = "";
    root.errBuf = "";
    root.send(job.line + "\n" + 'print "' + root.doneMark + '"\n');
  }

  function refreshVars() {
    root.pending = "vars";
    root.varsBuf = "";
    root.send('show globals\nprint "' + root.doneMark + '"\n');
  }

  function send(text) {
    if (root.procUp) { runner.write(text); return; }
    runner.queued += text;
    if (!runner.running) runner.running = true;
  }

  function onOut(line) {
    if (line.trim() === root.doneMark) {
      if (root.pending === "eval") root.finishEval();
      else if (root.pending === "vars") root.finishVars();
      else if (root.pending === "varsval") root.finishVarsVal();
      return;
    }
    if (root.pending === "vars") root.varsBuf += line + "\n";
    else if (root.pending === "varsval") root.varsValBuf += line + "\n";
    else root.outBuf += line + "\n";
  }

  function onErr(line) {
    // calc without a controlling tty moans about readline on exit; not ours
    if (/Unable to associate stdin/.test(line)) return;
    if (root.pending === "vars" || root.pending === "varsval") return;
    root.errBuf += line + "\n";
  }

  function finishEval() {
    const out = [], errs = [];
    for (let l of root.outBuf.split("\n")) {
      if (l === "") continue;
      l = l.replace(/^\t+/, "");
      if (/^\s*Error\b/.test(l)) errs.push(l.trim());
      else out.push(l);
    }
    for (let l of root.errBuf.split("\n")) {
      if (l.trim() !== "") errs.push(l.trim());
    }
    const i = root.pendingIdx;
    if (i >= 0 && i < transcriptModel.count) {
      transcriptModel.setProperty(i, "output", out.join("\n"));
      transcriptModel.setProperty(i, "error", errs.join("\n"));
      transcriptModel.setProperty(i, "running", false);
    }
    root.pendingIdx = -1;
    root.scrollTail();
    root.refreshVars();
  }

  // `show globals` prints a fixed-width table:
  //     Name    Level    Type
  //     ----    -----    -----
  //     x          0     real = (1)              5
  //     s          0     string = "hi"
  //     m          0     matrix
  //
  // For real values the Type column carries calc's exact rational form
  // (e.g. `real = (7/2)   2840511/50`), which is not what the transcript
  // shows. So names/types are taken here and numeric values are rendered
  // by calc itself in real mode in a short second pass.
  function finishVars() {
    const rows = [];
    for (let l of root.varsBuf.split("\n")) {
      const t = l.trim();
      if (t === "" || /^(Name|----|Number:)/.test(t)) continue;
      const m = l.match(/^(\S+)\s+\d+\s+(.*)$/);
      if (!m) continue;
      const rest = m[2].trim();
      let type = rest, value = "";
      const eq = rest.indexOf("=");
      if (eq >= 0) {
        type = rest.slice(0, eq).trim();
        const after = rest.slice(eq + 1).trim();
        const q = after.match(/"([\s\S]*)"\s*$/);
        const toks = after.split(/\s+/);
        value = q ? '"' + q[1] + '"' : toks[toks.length - 1];
      }
      rows.push({ name: m[1], type: type, value: value });
    }
    root.vars = rows;

    // numeric globals get their value reprinted in real (decimal) mode so
    // the column reads `56810.22`, not the exact fraction `2840511/50`
    let cmd = "";
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].type !== "real") continue;
      if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(rows[i].name)) continue;
      cmd += 'print "__V' + i + '__", ' + rows[i].name + ';\n';
    }
    if (cmd === "") {
      root.pending = "";
      root.pump();
      return;
    }
    root.varsValBuf = "";
    root.pending = "varsval";
    root.send(cmd + 'print "' + root.doneMark + '"\n');
  }

  // second pass: fold the real-mode renderings back into the rows
  function finishVarsVal() {
    for (let l of root.varsValBuf.split("\n")) {
      const m = l.match(/^__V(\d+)__\s*([\s\S]*)$/);
      if (!m) continue;
      const i = parseInt(m[1], 10);
      if (i >= 0 && i < root.vars.length) root.vars[i].value = m[2].trim();
    }
    root.vars = root.vars.slice();   // new array so the Repeater rebuilds
    root.pending = "";
    root.pump();
  }

  // the process died (a `quit`, a fatal runtime error, or a crash): close the
  // in-flight row with what we know and let the next submission restart it
  function onProcExit(code) {
    root.procUp = false;
    if (root.pending !== "") {
      const i = root.pendingIdx;
      if (i >= 0 && i < transcriptModel.count) {
        if (root.errBuf.trim() !== "") {
          transcriptModel.setProperty(i, "error", root.errBuf.trim());
        } else {
          // a clean exit — a `quit`/`exit`, typically: not an error
          transcriptModel.setProperty(i, "output", "session reset");
          transcriptModel.setProperty(i, "note", true);
        }
        transcriptModel.setProperty(i, "running", false);
      }
      root.pending = "";
      root.pendingIdx = -1;
      root.vars = [];
    }
    root.pump();
  }

  // ---------- history recall ----------
  function historyPrev() {
    if (root.history.length === 0) return;
    // Up at the newest goes one entry back; at the oldest it stays put
    // (the old code wrapped from the oldest straight to the newest)
    if (root.histIdx === -1) root.histIdx = root.history.length - 1;
    else if (root.histIdx > 0) root.histIdx -= 1;
    root.setDraft(root.history[root.histIdx]);
  }

  function historyNext() {
    if (root.histIdx === -1) return;
    root.histIdx++;
    if (root.histIdx >= root.history.length) {
      root.histIdx = -1;
      root.setDraft("");
    } else {
      root.setDraft(root.history[root.histIdx]);
    }
  }

  function setDraft(s) {
    root.draft = s;
    entryField.cursorPosition = s.length;
    root.cursorMoved(s.length);
  }

  // ---------- transcript scrolling ----------
  function scrollTail() {
    if (root.pinned) flick.contentY = Math.max(0, flick.contentHeight - flick.height);
  }

  // ---------- calc process ----------
  Process {
    id: runner
    command: ["calc", "-q", "-c", "-u"]
    stdinEnabled: true
    property string queued: ""

    stdout: SplitParser { onRead: line => root.onOut(line) }
    stderr: SplitParser { onRead: line => root.onErr(line) }

    onStarted: {
      root.procUp = true;
      if (runner.queued !== "") {
        runner.write(runner.queued);
        runner.queued = "";
      }
    }
    onExited: code => root.onProcExit(code)
  }

  // ---------- layout ----------
  Column {
    anchors.fill: parent
    spacing: 8

    Row {
      width: parent.width
      height: parent.height - root.inputH - 8
      spacing: 8

      // ----- screen: the scrollback -----
      Rectangle {
        id: screen
        width: Math.max(0, parent.width - varsBox.width - parent.spacing)
        height: parent.height
        radius: 6
        color: Theme.bg
        border.color: Theme.border
        border.width: 1

        Flickable {
          id: flick
          anchors.fill: parent
          anchors.margins: 10
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          contentWidth: width
          contentHeight: col.height
          onContentHeightChanged: root.scrollTail()
          onMovementEnded: root.pinned =
            (contentY >= contentHeight - height - 4)

          Column {
            id: col
            width: flick.width
            spacing: 10

            Repeater {
              model: transcriptModel

              delegate: Column {
                required property string input
                required property string output
                required property string error
                required property bool running
                required property bool note

                width: col.width
                spacing: 2

                Text {
                  visible: input !== ""
                  width: parent.width
                  text: "» " + input
                  font.family: Theme.font
                  font.pixelSize: 12
                  color: Theme.accent
                  wrapMode: Text.Wrap
                }

                Text {
                  visible: output !== "" || running
                  width: parent.width
                  text: running && output === "" ? "◌" : output
                  font.family: Theme.font
                  font.pixelSize: 12
                  color: note ? Theme.muted : Theme.live
                  wrapMode: Text.Wrap

                  MouseArea {
                    anchors.fill: parent
                    enabled: output !== ""
                    cursorShape: Qt.PointingHandCursor
                    // let a drag fall through to the Flickable so the
                    // transcript still scrolls over the text
                    preventStealing: false
                    onClicked: root.copyRequested(output)
                  }
                }

                Text {
                  visible: error !== ""
                  width: parent.width
                  text: error
                  font.family: Theme.font
                  font.pixelSize: 12
                  color: Theme.err
                  wrapMode: Text.Wrap
                }
              }
            }
          }
        }

        // ----- unobtrusive tail marker: jumps back to the newest line -----
        Rectangle {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: 10
          width: 24
          height: 22
          radius: 5
          color: tailMa.containsMouse ? Theme.hover : Theme.surface
          border.color: Theme.border
          border.width: 1
          visible: !root.pinned && flick.contentHeight > flick.height
          Text {
            anchors.centerIn: parent
            text: "\uf103"           // angle-double-down
            font.family: Theme.font
            font.pixelSize: 10
            color: Theme.text
          }
          MouseArea {
            id: tailMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.pinned = true; root.scrollTail(); }
          }
        }
      }

      // ----- variables column (fed by `show globals`) -----
      Rectangle {
        id: varsBox
        width: Math.max(150, Math.min(230, parent.width * 0.3))
        height: parent.height
        radius: 6
        color: Theme.surface
        border.color: Theme.border
        border.width: 1

        Item {
          anchors.fill: parent
          anchors.margins: 8

          Item {
            id: varsHead
            width: parent.width
            height: 20
            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "variables"
              font.family: Theme.font
              font.bold: true
              font.pixelSize: 11
              color: Theme.accent
            }
            Rectangle {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: clearLabel.implicitWidth + 12
              height: 18
              radius: 4
              color: clearMa.containsMouse ? Theme.hover : "transparent"
              Behavior on color { ColorAnimation { duration: 200 } }
              Text {
                id: clearLabel
                anchors.centerIn: parent
                text: "clear"
                font.family: Theme.font
                font.pixelSize: 10
                color: Theme.muted
              }
              MouseArea {
                id: clearMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.clearScreen()
              }
            }
          }

          Flickable {
            anchors.top: varsHead.bottom
            anchors.topMargin: 6
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            contentWidth: width
            contentHeight: varsCol.height

            Column {
              id: varsCol
              width: parent.width
              spacing: 5

              Repeater {
                model: root.vars

                delegate: Column {
                  required property var modelData
                  width: varsCol.width
                  spacing: 0

                  Text {
                    width: parent.width
                    text: modelData.name
                    font.family: Theme.font
                    font.pixelSize: 11
                    color: Theme.accent
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    visible: modelData.value !== ""
                    text: modelData.value
                    font.family: Theme.font
                    font.pixelSize: 11
                    color: Theme.live
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    visible: modelData.type !== "" && modelData.value === ""
                    text: "(" + modelData.type + ")"
                    font.family: Theme.font
                    font.pixelSize: 10
                    color: Theme.muted
                    elide: Text.ElideRight
                  }
                }
              }

              Text {
                visible: root.vars.length === 0
                width: varsCol.width
                text: "no variables yet\nx = 5 defines one"
                font.family: Theme.font
                font.pixelSize: 10
                color: Theme.idleText
                wrapMode: Text.Wrap
              }
            }
          }
        }
      }
    }

    // ----- input line -----
    Rectangle {
      id: inputBox
      width: parent.width
      height: root.inputH
      radius: 6
      color: Theme.surface
      border.color: root.panelActive ? Theme.muted : Theme.border
      border.width: 1

      Text {
        id: prompt
        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        text: "»"
        font.family: Theme.font
        font.bold: true
        font.pixelSize: 14
        color: Theme.live
      }

      TextField {
        id: entryField
        anchors.left: prompt.right
        anchors.leftMargin: 8
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        background: null
        placeholderText: "expression…  (x = 5 · sqrt(2) · 2^128)"
        placeholderTextColor: Theme.idleText
        color: Theme.accent
        font.family: Theme.font
        font.pixelSize: 13
        selectionColor: Theme.hover
        selectedTextColor: Theme.accent
        // the popup is keyboard-less while docked: the bar's hiddenInput is
        // the real editor — fake the caret here while the panel is open
        cursorVisible: root.panelActive
        cursorDelegate: Item {
          implicitWidth: 2
          Rectangle {
            anchors.fill: parent
            radius: 1
            color: Theme.accent
            SequentialAnimation on opacity {
              running: root.panelActive
              loops: Animation.Infinite
              NumberAnimation { to: 1; duration: 600 }
              NumberAnimation { to: 0; duration: 600 }
            }
          }
        }

        onTextChanged: if (!root.syncing) {
          root.syncing = true;
          root.draft = text;
          root.syncing = false;
        }
        onCursorPositionChanged: if (!root.syncing) {
          root.syncing = true;
          root.cursorMoved(cursorPosition);
          root.syncing = false;
        }

        Keys.priority: Keys.BeforeItem
        Keys.onUpPressed: event => { event.accepted = true; root.historyPrev(); }
        Keys.onDownPressed: event => { event.accepted = true; root.historyNext(); }
        Keys.onReturnPressed: event => { event.accepted = true; root.submit(); }
        Keys.onEnterPressed: event => { event.accepted = true; root.submit(); }
      }
    }
  }
}
