pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// Personal bests for the typing test (bar/TypeTest.qml).
// PBs are one entry per mode+value key ("time-15", "words-25", ...). Persisted
// under Quickshell.stateDir via FileView — the same store trick as the
// launcher's frecency.
Item {
  id: root

  // key → { wpm, acc, raw, consistency, at }
  property var pbs: ({})

  readonly property string storePath: Quickshell.stateDir + "/typing-pbs.json"

  FileView {
    id: file
    path: root.storePath
    blockAllReads: true
    preload: true
    printErrors: false
    watchChanges: false
  }

  function load() {
    root.pbs = {};

    const raw = file.text();
    if (!raw) return;

    let parsed = null;
    try { parsed = JSON.parse(raw); } catch (e) { return; }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return;

    const out = {};
    for (const k in parsed) {
      const v = parsed[k];
      if (v && typeof v.wpm === "number")
        out[k] = { wpm: v.wpm, acc: v.acc || 0, raw: v.raw || 0,
                   consistency: v.consistency || 0, at: v.at || 0 };
    }
    root.pbs = out;
  }

  function save() { file.setText(JSON.stringify(root.pbs)); }

  function pb(key) { return root.pbs[key] || null; }

  // record a run; returns true when it beat the previous best for that key
  function record(key, wpm, acc, raw, consistency) {
    const prev = root.pbs[key];
    if (prev && prev.wpm >= wpm) return false;
    const next = Object.assign({}, root.pbs);
    next[key] = { wpm: wpm, acc: acc, raw: raw,
                  consistency: consistency, at: Date.now() };
    root.pbs = next;
    root.save();
    return true;
  }

  Component.onCompleted: root.load()
}
