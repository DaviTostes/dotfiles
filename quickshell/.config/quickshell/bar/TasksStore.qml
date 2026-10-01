pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// Single source of truth for the tasks pill.
//
// The dropdown is rendered once per monitor (one Pill per bar), but the list
// is global: keeping the array in each pill meant every bar held its own
// in-memory copy, so a change made on one monitor never reached the other and
// the counts drifted until a reload. All persistent state — tasks and
// per-prefix colors — lives here instead; every pill reads and mutates this
// singleton, so the bars stay in lockstep. Persisted at
// Quickshell.stateDir/tasks.json (+ tasks-prefix-colors.json) via FileView,
// the same store trick as the launcher.
Item {
  id: root

  // stored tasks: { id, name, desc, prefix, done, created, doneAt }. Always
  // replaced wholesale on mutation (never edited in place) so consumer
  // bindings re-evaluate.
  property var tasks: []

  // per-prefix color overrides: lowercased prefix → "#rrggbb". Persisted
  // separately so a prefix keeps its color across restarts.
  property var prefixColors: ({})

  readonly property var pendingTasks: root.tasks.filter(t => !t.done)
  readonly property var doneTasks: root.tasks.filter(t => t.done)

  readonly property string storePath: Quickshell.stateDir + "/tasks.json"
  readonly property string prefixColorsPath: Quickshell.stateDir + "/tasks-prefix-colors.json"

  // ---------- persistence ----------
  // stateDir is created by quickshell; printErrors off so the (expected)
  // "file does not exist" warning on first run stays quiet. FileView caches
  // the text, so a hand-edit only takes effect after a config reload.
  FileView {
    id: tasksFile
    path: root.storePath
    blockAllReads: true
    preload: true
    printErrors: false
    watchChanges: false
  }

  FileView {
    id: prefixColorsFile
    path: root.prefixColorsPath
    blockAllReads: true
    preload: true
    printErrors: false
    watchChanges: false
  }

  function loadTasks() {
    root.tasks = [];

    const raw = tasksFile.text();
    if (!raw) return;

    let parsed = null;
    try { parsed = JSON.parse(raw); } catch (e) { return; }
    if (!Array.isArray(parsed)) return;

    const out = [];
    for (let i = 0; i < parsed.length; i++) {
      const t = parsed[i];
      if (!t || typeof t.name !== "string") continue;
      out.push({
        id: String(t.id !== undefined ? t.id : Date.now() + "-" + i),
        name: t.name,
        desc: typeof t.desc === "string" ? t.desc : "",
        prefix: typeof t.prefix === "string" ? t.prefix : "",
        done: !!t.done,
        created: typeof t.created === "number" ? t.created : 0,
        doneAt: typeof t.doneAt === "number" ? t.doneAt : 0
      });
    }
    root.tasks = out;
  }

  function saveTasks() { tasksFile.setText(JSON.stringify(root.tasks)); }

  function loadPrefixColors() {
    root.prefixColors = {};

    const raw = prefixColorsFile.text();
    if (!raw) return;

    let parsed = null;
    try { parsed = JSON.parse(raw); } catch (e) { return; }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return;

    const out = {};
    for (const k in parsed) {
      if (typeof parsed[k] === "string" && /^#[0-9a-fA-F]{6}$/.test(parsed[k]))
        out[k.toLowerCase()] = parsed[k];
    }
    root.prefixColors = out;
  }

  function savePrefixColors() { prefixColorsFile.setText(JSON.stringify(root.prefixColors)); }

  // set a custom color for a prefix; falsy color removes the override (auto)
  function setPrefixColor(prefix, color) {
    const key = (prefix || "").toLowerCase();
    if (key === "") return;
    const next = Object.assign({}, root.prefixColors);
    if (color) next[key] = color;
    else delete next[key];
    root.prefixColors = next;
    root.savePrefixColors();
  }

  // ---------- mutations ----------
  function find(id) { return root.tasks.find(t => t.id === id); }

  function addTask(name, desc, prefix) {
    const now = Date.now();
    const t = {
      id: now + "-" + Math.floor(Math.random() * 1e6),
      name: name,
      desc: desc,
      prefix: prefix,
      done: false,
      created: now,
      doneAt: 0
    };
    root.tasks = [t].concat(root.tasks);   // newest first
    root.saveTasks();
    return t;
  }

  function updateTask(id, name, desc, prefix) {
    root.tasks = root.tasks.map(t => t.id === id
        ? Object.assign({}, t, { name: name, desc: desc, prefix: prefix })
        : t);
    root.saveTasks();
  }

  function toggleTask(id) {
    root.tasks = root.tasks.map(t => t.id === id
        ? Object.assign({}, t, { done: !t.done, doneAt: !t.done ? Date.now() : 0 })
        : t);
    root.saveTasks();
  }

  function removeTask(id) {
    root.tasks = root.tasks.filter(t => t.id !== id);
    root.saveTasks();
  }

  // reorder within the visible tab: swap with the neighbour at index+delta in
  // the caller's filtered group. The store mixes pending/done, but both views
  // are filters, so rebuilding as (reordered current group) + (other group
  // untouched) keeps every view consistent.
  function moveTask(id, delta, group) {
    const cur = group.slice();
    const i = cur.findIndex(t => t.id === id);
    const j = i + delta;
    if (i < 0 || j < 0 || j >= cur.length) return;

    const tmp = cur[i]; cur[i] = cur[j]; cur[j] = tmp;

    const inGroup = {};
    for (let k = 0; k < cur.length; k++) inGroup[cur[k].id] = true;
    const other = root.tasks.filter(t => !inGroup[t.id]);

    root.tasks = cur.concat(other);
    root.saveTasks();
  }

  Component.onCompleted: {
    root.loadTasks();
    root.loadPrefixColors();
  }
}
