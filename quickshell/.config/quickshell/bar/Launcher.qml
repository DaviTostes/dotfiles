import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick
import QtQuick.Controls.Basic
import "../hyprconf"

// Super+Space application launcher (replaces `wofi --show drun`).
//
// Unlike the bar's Pomodoro-style dropdowns — which live inside a bar
// PopupWindow and inherit the bar's OnDemand keyboard grab, hence the
// hidden-TextInput trick in Opencode.qml — this is its own fullscreen
// layer-shell surface. It sits on the Overlay layer and asks for EXCLUSIVE
// keyboard interactivity so it can be typed into for as long as it is
// mapped.
//
// The keyboard request is deliberately constant (not bound to `open`):
// layer surfaces must send it before their first commit, and an unmapped
// surface grabs nothing — so `open` only drives visibility.
//
// One instance, not one per monitor: it opens on whichever monitor is
// focused at the time, exactly like the wofi it replaces.
PanelWindow {
  id: root

  property bool open: false

  // stays mapped briefly while closing so the fades can play (same trick
  // as HyprConfig's hideTimer)
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
  // desktop entries
  // ---------------------------------------------------------------

  // DesktopEntries.applications is an ObjectModel; snapshot it into a plain
  // JS array so it can be filtered and sorted by score.
  property var apps: []
  property var results: []
  property int selected: 0

  readonly property int maxRows: 8
  readonly property int rowHeight: 38
  readonly property int maxResults: 60

  // frecency: desktop entry id → { n: launch count, t: last launch (ms) }
  property var usage: ({})
  readonly property string usagePath: Quickshell.stateDir + "/launcher-usage.json"

  function wordStart(t, i) {
    return i === 0 || t[i - 1] === " " || t[i - 1] === "-" || t[i - 1] === ".";
  }

  // Subsequence match, like wofi's default: every query character must
  // appear in order. Bonuses for word starts and runs, penalty for late
  // matches. Returns 0 when the text does not match.
  function score(query, text) {
    const q = query.toLowerCase();
    const t = text.toLowerCase();
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

  function refresh() {
    const out = [];
    const entries = DesktopEntries.applications.values;

    for (let i = 0; i < entries.length; i++) {
      const e = entries[i];
      if (e && !e.noDisplay) out.push(e);
    }

    out.sort((a, b) => a.name.localeCompare(b.name));
    root.apps = out;
    root.update();
  }

  function update() {
    const q = field.text.trim();

    if (q === "") {
      // no query → frecency: most used first, alphabetical for the rest
      const ranked = root.apps.slice();
      ranked.sort((a, b) => (root.usageRank(b) - root.usageRank(a))
                            || a.name.localeCompare(b.name));
      root.results = ranked.slice(0, root.maxResults);
      root.selected = 0;
      return;
    }

    const hits = [];
    for (let i = 0; i < root.apps.length; i++) {
      const e = root.apps[i];
      const s = Math.max(root.score(q, e.name),
                         root.score(q, e.genericName) * 0.6);
      // usage is a capped bonus, not a replacement for match quality: it
      // breaks ties between similar matches without letting a stale
      // favourite jump over a much better one
      if (s > 0) hits.push({ s: s + Math.min(root.usageRank(e), 15), e: e });
    }
    hits.sort((a, b) => b.s - a.s);

    const out = [];
    for (let i = 0; i < hits.length && i < root.maxResults; i++) out.push(hits[i].e);
    root.results = out;
    root.selected = 0;
  }

  // ---------------------------------------------------------------
  // usage (frecency) — persisted per shell in Quickshell.stateDir
  // ---------------------------------------------------------------

  // Launch count (capped) plus a recency bonus. 0..15, so it can reorder
  // the list but never outweigh a clearly better match.
  function usageRank(entry) {
    const u = entry ? root.usage[entry.id] : null;
    if (!u) return 0;

    const day = 86400000;
    const age = Math.max(Date.now() - (u.t || 0), 0);
    const recency = age < day ? 3
                  : age < 7 * day ? 2
                  : age < 30 * day ? 1 : 0;

    return Math.min(u.n || 0, 6) * 2 + recency;
  }

  function loadUsage() {
    root.usage = {};

    const raw = usageFile.text();
    if (!raw) return;

    let parsed = null;
    try { parsed = JSON.parse(raw); } catch (e) { return; }
    if (!parsed || typeof parsed !== "object") return;

    for (const id in parsed) {
      const u = parsed[id];
      if (u && typeof u.n === "number") root.usage[id] = { n: u.n, t: u.t || 0 };
    }
  }

  function saveUsage() {
    // drop entries whose app is gone so the file can't grow forever
    const known = {};
    for (let i = 0; i < root.apps.length; i++) known[root.apps[i].id] = true;

    const out = {};
    for (const id in root.usage) {
      if (known[id]) out[id] = root.usage[id];
    }

    usageFile.setText(JSON.stringify(out));
  }

  function record(entry) {
    if (!entry || !entry.id) return;
    const u = root.usage[entry.id] || { n: 0 };
    root.usage[entry.id] = { n: (u.n || 0) + 1, t: Date.now() };
    root.saveUsage();
  }

  // `qs ipc call launcher clearUsage` — wipes the frecency history
  function clearUsage() {
    root.usage = {};
    root.saveUsage();
    root.update();
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
    root.record(entry);
    root.close();
    entry.execute();
  }

  function iconFor(entry) {
    if (!entry || !entry.icon) return "";
    return Quickshell.iconPath(entry.icon, true);
  }

  Component.onCompleted: {
    root.loadUsage();
    root.refresh();
  }

  // frecency store. stateDir is created by quickshell; printErrors off so the
  // (expected) "file does not exist" warning on first run stays quiet.
  // FileView caches the text, so hand-edits / imports only take effect after
  // a config reload — otherwise the next launch rewrites the file from the
  // stale snapshot.
  FileView {
    id: usageFile

    path: root.usagePath
    preload: true
    blockAllReads: true
    printErrors: false
    watchChanges: false
  }

  // the launcher stays in sync with installs/removals
  Connections {
    target: DesktopEntries
    function onApplicationsChanged() { root.refresh(); }
  }

  // ---------------------------------------------------------------
  // open / close
  // ---------------------------------------------------------------

  function openFocused() {
    // follow the focused monitor. There is no monitor → screen helper
    // (only monitorFor(screen)), so look it up the same way shell.qml
    // does for the bar IPC bridge.
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
    // focus only sticks once the surface is mapped
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

  // dim backdrop; the window is fullscreen, so clicks here close it (the
  // bar's Catcher is only needed for popups that don't fill the screen)
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

      // ----- search field -----
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
          text: "\uf002"
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
          placeholderText: "Search..."
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

      // ----- results -----
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

          IconImage {
            id: rowIcon

            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 20
            height: 20
            source: root.iconFor(modelData)
          }

          Text {
            id: rowName

            anchors.left: rowIcon.right
            anchors.leftMargin: 10
            anchors.right: rowSub.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.name
            color: index === root.selected ? Theme.accent : Theme.text
            font.family: Theme.font
            font.pixelSize: 13
            elide: Text.ElideRight
            Behavior on color { ColorAnimation { duration: 150 } }
          }

          // generic name ("Web Browser") as a dim right-aligned hint
          Text {
            id: rowSub

            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, 180)
            text: modelData.genericName
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: 11
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignRight
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
