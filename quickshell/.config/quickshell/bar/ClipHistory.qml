import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls.Basic
import "../hyprconf"

// Super+Alt+Space clipboard history — replaces
// `cliphist list | wofi -S dmenu | cliphist decode | wl-copy`.
//
// Only wofi's role (the picker) is replaced: cliphist stays as the store
// (sqlite, images included, fed by the `wl-paste --watch cliphist store`
// autostart) and plain text/binary copies below go through `wl-copy`.
//
// Same shape as Launcher.qml — its own fullscreen Overlay layer-shell
// surface with EXCLUSIVE keyboard focus, so it is typed into directly.
PanelWindow {
  id: root

  property bool open: false

  // cliphist entries, in cliphist's own order (newest first)
  property var items: []
  property var results: []
  property int selected: 0

  readonly property int maxRows: 10
  readonly property int rowHeight: 34
  readonly property int maxResults: 60

  // stays mapped briefly while closing so the fades can play
  visible: root.open || hideTimer.running
  Timer { id: hideTimer; interval: 150 }

  color: "transparent"
  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

  // ---------------------------------------------------------------
  // cliphist
  // ---------------------------------------------------------------

  // Subsequence scorer, same as Launcher.qml's. Kept local instead of
  // shared so the two panels stay independent (~20 lines). Both arguments
  // must already be lowercase — parseList() keeps a lowercase preview so the
  // per-keystroke pass never re-lowercases the whole history.
  function wordStart(t, i) {
    return i === 0 || t[i - 1] === " " || t[i - 1] === "\t"
        || t[i - 1] === "-" || t[i - 1] === "/";
  }

  function score(q, t) {
    let qi = 0;
    let sc = 0;
    let streak = 0;
    let last = -2;

    for (let ti = 0; ti < t.length && qi < q.length; ti++) {
      if (t[ti] !== q[qi]) continue;
      streak = (ti === last + 1) ? streak + 1 : 1;
      sc += 10 + (wordStart(t, ti) ? 8 : 0) + streak * 2
            - Math.min(ti, 20) * 0.1;
      last = ti;
      qi++;
    }

    return qi === q.length ? sc : 0;
  }

  // `cliphist list` prints "<id>\t<single line preview>" per entry. Split on
  // the FIRST tab only — a preview may contain tabs of its own — and drop
  // anything whose id is not numeric (junk from a failed run).
  function parseList(raw) {
    const out = [];
    const lines = raw.split("\n");

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line === "") continue;

      const tab = line.indexOf("\t");
      if (tab <= 0) continue;

      const id = line.slice(0, tab);
      if (!/^\d+$/.test(id)) continue;

      const preview = line.slice(tab + 1);
      out.push({ id: id, preview: preview, previewL: preview.toLowerCase() });
    }

    root.items = out;
    root.update();
  }

  // The previous listing deliberately stays on screen while cliphist
  // answers: clearing it here made the panel open empty and then pop in —
  // a second layout pass plus the card growing under the cursor. The rows
  // are replaced the moment the process returns (and the single entry
  // point is the shell warm-up below, so the first open is never empty at
  // all).
  function refresh() {
    root.selected = 0;
    if (!listProc.running) listProc.running = true;
  }

  function setResults(out) {
    // Replacing the model array makes the ListView destroy and rebuild every
    // delegate. Most keystrokes keep the same visible rows, so only hand the
    // view a new array when the slice actually changed (the entry records
    // are stable between `cliphist list` runs, so identity works).
    const old = root.results;
    let same = old.length === out.length;
    for (let i = 0; same && i < out.length; i++) same = old[i] === out[i];
    if (!same) root.results = out;
    root.selected = 0;
  }

  function update() {
    const q = field.text.trim();

    if (q === "") {
      // no query → cliphist's order, newest first
      root.setResults(root.items.slice(0, root.maxResults));
      return;
    }

    const ql = q.toLowerCase();
    const hits = [];
    for (let i = 0; i < root.items.length; i++) {
      const it = root.items[i];
      const s = root.score(ql, it.previewL);
      if (s > 0) hits.push({ s: s, i: i, it: it });
    }
    hits.sort((a, b) => (b.s - a.s) || (a.i - b.i));

    const out = [];
    for (let i = 0; i < hits.length && i < root.maxResults; i++) out.push(hits[i].it);
    root.setResults(out);
  }

  function move(delta) {
    const n = root.results.length;
    if (n === 0) return;
    root.selected = ((root.selected + delta) % n + n) % n;
    list.positionViewAtIndex(root.selected, ListView.Contain);
  }

  function activate() {
    const entry = root.results[root.selected];
    if (!entry) return;
    root.close();
    // ids are validated numeric at parse time, so this line is safe.
    // cliphist decode | wl-copy is what the old bind did — keeping the pipe
    // is what preserves images (wl-copy sniffs the type).
    copyProc.command = ["sh", "-c", "cliphist decode " + entry.id + " | wl-copy"];
    copyProc.running = true;
  }

  Process {
    id: listProc

    command: ["cliphist", "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseList(text)
    }
  }

  Process { id: copyProc }

  // warm the listing up at shell start so the first open is populated
  // immediately instead of waiting for the process to answer
  Component.onCompleted: root.refresh()

  // ---------------------------------------------------------------
  // open / close
  // ---------------------------------------------------------------

  function openFocused() {
    // same monitor → screen lookup as Launcher.qml / shell.qml
    const m = Hyprland.focusedMonitor;
    if (m) {
      for (let i = 0; i < Quickshell.screens.length; i++) {
        const s = Quickshell.screens[i];
        const sm = Hyprland.monitorFor(s);
        if (sm && sm.name === m.name) { root.screen = s; break; }
      }
    }

    hideTimer.stop();
    field.text = "";
    root.refresh();
    root.open = true;
    Qt.callLater(() => field.forceActiveFocus());
  }

  function toggle() {
    if (root.open) root.close();
    else root.openFocused();
  }

  function close() { root.open = false; }

  // ---------------------------------------------------------------
  // visuals — Pomodoro palette, same motion as the bar dropdowns
  // ---------------------------------------------------------------

  // dim backdrop; the window is fullscreen, so clicks here close it
  Rectangle {
    anchors.fill: parent
    color: Theme.deep
    opacity: root.open ? 0.55 : 0
    Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }
  }

  Rectangle {
    id: card

    anchors.centerIn: parent
    width: 580
    height: col.implicitHeight + 20
    radius: 8
    color: Theme.bg
    border.color: Theme.border
    border.width: 1
    clip: true

    opacity: root.open ? 1 : 0
    scale: root.open ? 1 : 0.98
    Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    // swallows clicks on the card's padding so they don't reach the scrim
    MouseArea { anchors.fill: parent }

    Shortcut {
      sequence: "Escape"
      onActivated: root.close()
    }

    Column {
      id: col

      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: 10
      spacing: 8

      // ----- filter field -----
      Rectangle {
        width: parent.width
        height: 40
        radius: 6
        color: Theme.surface
        border.color: field.activeFocus ? Theme.muted : Theme.border
        border.width: 1

        Text {
          id: searchIcon

          anchors.left: parent.left
          anchors.leftMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          text: "\uf0c5"
          font.family: Theme.font
          font.pixelSize: 13
          color: Theme.muted
        }

        TextField {
          id: field

          anchors.left: searchIcon.right
          anchors.leftMargin: 10
          anchors.right: parent.right
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          background: null
          focus: root.open
          placeholderText: "Clipboard history..."
          placeholderTextColor: Theme.idleText
          color: Theme.accent
          font.family: Theme.font
          font.pixelSize: 14
          selectionColor: Theme.hover
          selectedTextColor: Theme.accent
          onTextChanged: root.update()
          Keys.onDownPressed: root.move(1)
          Keys.onUpPressed: root.move(-1)
          Keys.onReturnPressed: root.activate()
          Keys.onEnterPressed: root.activate()
          Keys.onEscapePressed: root.close()
        }
      }

      // ----- empty state -----
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        visible: root.results.length === 0 && !listProc.running
        text: root.items.length === 0 ? "clipboard vazio" : "nada encontrado"
        color: Theme.muted
        font.family: Theme.font
        font.pixelSize: 12
      }

      // ----- entries -----
      ListView {
        id: list

        width: parent.width
        height: Math.min(root.results.length, root.maxRows) * root.rowHeight
        clip: true
        model: root.results
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          required property var modelData
          required property int index

          width: list.width
          height: root.rowHeight
          radius: 6
          color: index === root.selected ? Theme.hover
               : rowMouse.containsMouse ? Theme.surface : "transparent"
          Behavior on color { ColorAnimation { duration: 150 } }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.preview
            color: index === root.selected ? Theme.accent : Theme.text
            font.family: Theme.font
            font.pixelSize: 12
            elide: Text.ElideRight
            Behavior on color { ColorAnimation { duration: 150 } }
          }

          MouseArea {
            id: rowMouse

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.selected = index;
              root.activate();
            }
          }
        }
      }
    }
  }
}
