pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// Shared opencode chat selection between every panel instance: the bars' docked
// intelligence central and the standalone full chat. They all show the same
// conversation list and the same current session, so switching a chat (or
// starting one) in any window propagates to the others.
//
// Each instance still owns its own message model, SSE stream and turn state;
// only the SELECTION (which chat, or a pending new chat) is shared here.
Item {
  id: root

  // remembered panel-owned session ids (sessionID -> true), persisted once for
  // every panel so two instances cannot clobber each other's store
  property var panelSessions: ({})
  property bool panelSessionsLoaded: false

  // the session every panel displays. "" means "no explicit selection".
  property string currentSessionId: ""
  // true while the user has an unsaved "new chat" open (nothing created yet)
  property bool newChatPending: false
  // bumped on every selection change so watchers re-read even if the id is the
  // same (e.g. re-adopting after a reload)
  property int switchTick: 0

  // select an existing session everywhere
  function setCurrent(id) {
    root.currentSessionId = id ? id : "";
    root.newChatPending = false;
    root.switchTick++;
  }

  // open the pending "new chat" everywhere
  function startNew() {
    root.currentSessionId = "";
    root.newChatPending = true;
    root.switchTick++;
  }

  function remember(id) {
    if (!id || root.panelSessions[id]) return;
    const next = Object.assign({}, root.panelSessions);
    next[id] = true;
    root.panelSessions = next;
    store.setText(JSON.stringify(next));
  }

  function forget(id) {
    if (!id || !root.panelSessions[id]) return;
    const next = Object.assign({}, root.panelSessions);
    delete next[id];
    root.panelSessions = next;
    store.setText(JSON.stringify(next));
  }

  // drop ids that no longer exist on the server. `known` must be the FULL
  // session list — a truncated page would wrongly forget chats that fell off.
  function prune(known) {
    if (!root.panelSessionsLoaded) return;
    const alive = {};
    for (const s of (known || [])) alive[s.id] = true;
    let changed = false;
    const next = {};
    for (const id in root.panelSessions) {
      if (alive[id]) next[id] = true;
      else changed = true;
    }
    if (!changed) return;
    root.panelSessions = next;
    store.setText(JSON.stringify(next));
  }

  FileView {
    id: store
    path: Quickshell.stateDir + "/opencode-panel-sessions.json"
    blockAllReads: true
    preload: true
    printErrors: false
    watchChanges: false
    onLoaded: {
      root.panelSessionsLoaded = true;
      const raw = store.text();
      if (!raw) return;
      let parsed = null;
      try { parsed = JSON.parse(raw); } catch (e) { return; }
      if (!parsed || typeof parsed !== "object") return;
      const next = {};
      for (const id in parsed) if (parsed[id]) next[id] = true;
      root.panelSessions = next;
    }
    onLoadFailed: root.panelSessionsLoaded = true
  }
}
