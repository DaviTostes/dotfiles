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

  // DesktopEntries.applications is an ObjectModel; snapshot it into plain
  // records once per (re)scan so the per-keystroke filter never re-lowercases
  // every name and never localeCompares.
  //
  // Each record is `{ id, entry, nameL, genericL }` — `entry` is the live
  // DesktopEntry, so the delegate still shows name/genericName live (a
  // localized rename repaints without a rescan), while the search only uses
  // the pre-lowercased copies.
  property var apps: []
  property var results: []
  property int selected: 0
  // the app list is only rebuilt when DesktopEntries reports a change; the
  // launcher can then open without paying a full rescan + re-sort
  property bool appsDirty: true
  // icon name → resolved URL. Resolving goes through QIcon::fromTheme (a
  // theme/directory probe, expensive when the name does not resolve), and it
  // used to run again for every delegate that was built — i.e. on every
  // keystroke, since the model array is replaced. Memoizing keeps it to once
  // per app for the life of the shell.
  property var iconUrls: ({})

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
  // matches. Returns 0 when the text does not match. Both arguments must
  // already be lowercase (the caller keeps lowercase copies of every field).
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

  // plain string compare of the pre-lowercased names — localeCompare is
  // ~an order of magnitude slower and this runs on every entry of every
  // sort (the full alphabetical sort, and the frecency tie-break)
  function cmpName(a, b) {
    return a.nameL < b.nameL ? -1 : a.nameL > b.nameL ? 1 : 0;
  }

  function makeApp(e) {
    const name = e.name || "";
    const generic = e.genericName || "";
    return {
      id: e.id,
      entry: e,
      nameL: name.toLowerCase(),
      genericL: generic.toLowerCase()
    };
  }

  function refresh() {
    const entries = DesktopEntries.applications.values;
    const out = [];

    for (let i = 0; i < entries.length; i++) {
      const e = entries[i];
      if (e && !e.noDisplay) out.push(root.makeApp(e));
    }

    out.sort(root.cmpName);
    root.apps = out;
    root.appsDirty = false;
    root.update();
  }

  // Replacing the model array makes the ListView destroy and rebuild every
  // delegate (and with them every IconImage). Most keystrokes keep the same
  // visible rows, so only hand the view a new array when the slice actually
  // changed — record identity is stable between rescans.
  function setResults(out) {
    const old = root.results;
    let same = old.length === out.length;
    for (let i = 0; same && i < out.length; i++) same = old[i] === out[i];
    if (!same) root.results = out;
    root.selected = 0;
  }

  function update() {
    const q = field.text.trim();
    // resolve frecency once per entry up front: usageRank() reads Date.now()
    // and the usage map, and the comparators below run O(n log n) times
    const now = Date.now();
    const rank = ({});
    for (let i = 0; i < root.apps.length; i++) {
      const e = root.apps[i];
      rank[e.id] = root.usageRank(e, now);
    }

    if (q === "") {
      // no query → frecency: most used first, alphabetical for the rest.
      // `apps` is already alphabetical, so the tie-break only has to be a
      // name compare (not a localeCompare).
      const ranked = root.apps.slice();
      ranked.sort((a, b) => (rank[b.id] - rank[a.id]) || root.cmpName(a, b));
      const out = ranked.slice(0, root.maxResults);
      root.setResults(out);
      return;
    }

    const ql = q.toLowerCase();
    const hits = [];
    for (let i = 0; i < root.apps.length; i++) {
      const e = root.apps[i];
      const s = Math.max(root.score(ql, e.nameL),
                         root.score(ql, e.genericL) * 0.6);
      // usage is a capped bonus, not a replacement for match quality: it
      // breaks ties between similar matches without letting a stale
      // favourite jump over a much better one
      if (s > 0) hits.push({ s: s + Math.min(rank[e.id], 15), e: e });
    }
    hits.sort((a, b) => b.s - a.s);

    const out = [];
    for (let i = 0; i < hits.length && i < root.maxResults; i++) out.push(hits[i].e);
    root.setResults(out);
  }

  // ---------------------------------------------------------------
  // usage (frecency) — persisted per shell in Quickshell.stateDir
  // ---------------------------------------------------------------

  // Launch count (capped) plus a recency bonus. 0..15, so it can reorder
  // the list but never outweigh a clearly better match.
  // `now` is passed in by update() so a whole ranking pass shares one clock
  // read instead of calling Date.now() inside a sort comparator
  function usageRank(app, now) {
    const u = app ? root.usage[app.id] : null;
    if (!u) return 0;

    const day = 86400000;
    const age = Math.max((now === undefined ? Date.now() : now) - (u.t || 0), 0);
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

  function record(app) {
    if (!app || !app.id) return;
    const u = root.usage[app.id] || { n: 0 };
    root.usage[app.id] = { n: (u.n || 0) + 1, t: Date.now() };
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
    const app = root.results[root.selected];
    if (!app) return;
    root.record(app);
    root.close();
    app.entry.execute();
  }

  // resolved icon URL for a record, resolved at most once per app
  function iconUrl(app) {
    if (!app || !app.entry || !app.entry.icon) return "";
    const cached = root.iconUrls[app.id];
    if (cached !== undefined) return cached;
    const url = Quickshell.iconPath(app.entry.icon, true);
    root.iconUrls[app.id] = url;
    return url;
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

  // installs/removals mark the snapshot dirty instead of rescanning right
  // away: while the launcher is closed there is nothing to repaint, and the
  // rescan then happens on the next open (or on the next change while open)
  Connections {
    target: DesktopEntries
    function onApplicationsChanged() {
      root.appsDirty = true;
      if (root.open) root.refresh();
    }
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
    // opening must not pay for a full rescan + re-sort: the snapshot is only
    // rebuilt when DesktopEntries actually changed (and then it happens at
    // startup or while the launcher is open). Otherwise the (cheap) filter
    // pass is enough.
    if (root.appsDirty) root.refresh();
    else root.update();
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

    // Escape closes the launcher. Layer surfaces do not reliably map onto
    // Qt's "active window", so a window-scoped Shortcut here swallowed the
    // key without ever activating — and in doing so stopped the field's
    // Keys handler from seeing it too. Application scope works (same fix as
    // Opencode.qml); `enabled` keeps it from colliding with that panel's
    // Escape shortcut while the launcher is closed.
    Shortcut {
      sequence: "Escape"
      context: Qt.ApplicationShortcut
      enabled: root.open
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
            source: root.iconUrl(modelData)
          }

          Text {
            id: rowName

            anchors.left: rowIcon.right
            anchors.leftMargin: 10
            anchors.right: rowSub.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.entry.name
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
            text: modelData.entry.genericName
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
