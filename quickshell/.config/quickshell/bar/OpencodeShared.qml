pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// Shared opencode state between every panel instance: the bars' docked
// intelligence central and the standalone full chat.
//
// ONLY the chat HISTORY (which sessions the panel owns) and the recently-used
// models are shared. The currently-open chat is per-instance, so the docked
// panel and the standalone window can each show a different conversation at
// the same time; switching one does not move the other.
Item {
  id: root

  // remembered panel-owned session ids (sessionID -> true), persisted once for
  // every panel so two instances cannot clobber each other's store
  property var panelSessions: ({})
  property bool panelSessionsLoaded: false

  // recently used models, most-recent first: [{ id, providerID }]. Persisted
  // so the picker can surface them at the top across restarts.
  property var recentModels: []

  // push a model ref to the front of the recents list
  function touchModel(ref) {
    if (!ref || !ref.id) return;
    const next = [{ id: ref.id, providerID: ref.providerID || "" }];
    for (const r of root.recentModels)
      if (!(r.id === ref.id && r.providerID === ref.providerID)) next.push(r);
    root.recentModels = next.slice(0, 6);
    recentStore.setText(JSON.stringify(root.recentModels));
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

  FileView {
    id: recentStore
    path: Quickshell.stateDir + "/opencode-recent-models.json"
    blockAllReads: true
    preload: true
    printErrors: false
    watchChanges: false
    onLoaded: {
      const raw = recentStore.text();
      if (!raw) return;
      let parsed = null;
      try { parsed = JSON.parse(raw); } catch (e) { return; }
      if (!Array.isArray(parsed)) return;
      const next = [];
      for (const r of parsed)
        if (r && r.id) next.push({ id: r.id, providerID: r.providerID || "" });
      root.recentModels = next.slice(0, 6);
    }
  }
}
