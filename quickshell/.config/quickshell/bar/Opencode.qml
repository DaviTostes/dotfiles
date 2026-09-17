import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls.Basic
import "../hyprconf"

// opencode — native chat panel (no kitty window at all).
//
// Talks to the opencode2 HTTP service (the same background server the TUI
// uses): reads ~/.local/state/opencode/service.json for url+password, and
// renders the conversation as QML. Nothing is ever hidden, spawned or
// focused — opening/closing is pure animation, and there is no window for
// Hyprland's focus-restore to resurrect.
//
// Streaming: a persistent SSE connection on GET /api/event drives the
// chat live. `session.text.delta` / `session.reasoning.delta` events
// carry token-level text chunks and are applied incrementally to the
// ListModel, so only the streaming delegate re-renders. Coarser events
// (session.step.*, session.execution.*, permission.asked, …) trigger
// debounced full reloads. A watchdog restarts the stream if no bytes
// (not even the ": heartbeat") arrive.
//
// API map (v2, discovered via GET /openapi.json):
//   GET  /api/health                              service up?
//   GET  /api/session?parentID=null               root sessions (newest first)
//   GET  /api/session/active                      { sessionID: {type} } running
//   POST /api/session                             new chat
//   GET  /api/session/{id}/message                history
//   POST /api/session/{id}/prompt  {text, files}  send (files = @-mentions)
//   POST /api/session/{id}/command {command,text} slash commands
//   POST /api/session/{id}/model   {model}        switch model
//   POST /api/session/{id}/agent   {agent}        switch agent
//   POST /api/session/{id}/interrupt              stop
//   GET  /api/session/{id}/permission             pending permission ask
//   POST /api/session/{id}/permission/{pid}/reply {reply: once|always|reject}
//   GET  /api/fs/find?query=&type=file            @-mention file finder
//   GET  /api/agent /api/model /api/command       switcher contents
//   GET  /api/event                               SSE event stream
Pill {
  id: root

  // ---------- panel ----------
  property bool panelOpen: false
  property string mode: "chat"    // central tab: chat | translate | calc
  // tab swipe: on tab change the incoming body starts offset to the side
  // (direction follows the tab order) and glides back to 0
  property real swipeOfs: 0
  property int prevTab: 0
  Behavior on swipeOfs {
    id: swipeBehavior
    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
  }
  property string menu: ""        // "" | "sessions" | "models" | "agents" | "commands" | "files"
  property int menuSel: 0         // keyboard selection in the searchable menus
  property string menuSavedInput: ""  // chat draft parked while a menu searches
  // models / agents / sessions take the keyboard over as a search box
  readonly property bool menuSearchOpen: root.menu === "models"
      || root.menu === "agents" || root.menu === "sessions"

  // ---------- service ----------
  property string svcUrl: ""
  property string svcPw: ""
  property bool svcUp: false
  property int svcTries: 0

  // ---------- chat state ----------
  property var session: null      // Session.Info or null
  property var sessionList: []
  property var activeSessions: ({})  // sessionID -> true while a turn is running
  // sessions this panel created or opened on purpose: only these are picked
  // automatically and only these show up in the picker. A session running in
  // the TUI (or nvim) must never be dragged into the panel just because it is
  // the active one. Persisted in Quickshell.stateDir.
  property var panelSessions: ({})  // sessionID -> true
  property bool panelSessionsLoaded: false  // store read from disk (guards prune)
  property bool newChatPending: false  // "+" pressed, session not created yet
  property var agents: []
  property var models: []
  property var commands: []
  property var fileHits: []       // @-mention finder hits: {path, type}
  property int fileSel: 0         // keyboard-selected finder hit
  property int finderSeq: 0       // guards against out-of-order finder replies
  property string finderQuery: "" // latest @-token, requested after a debounce
  property var pendingImages: []  // clipboard images awaiting send: {name, b64}
  property int imageSeq: 0        // monotonic, so chip names never collide
  property bool pasteFallbackText: true  // Ctrl+V falls back to text paste
  property var pendingForms: []   // pending select-questions (Form.Info)
  property var formAnswers: ({})  // formID -> { fieldKey: answer }
  property var formTextTarget: null  // { formID, key, title, form } while typing an answer
  property var expanded: ({})     // key -> bool, for tool/reasoning foldouts
  property bool sending: false
  property bool busy: false       // assistant turn in flight
  property string error: ""
  property var pendingPerm: null  // Permission.Request or null
  property var lastModel: null    // last model seen on any session — new chats start with it
  property string lastAgent: ""   // last agent seen on any session
  // turn lifecycle timestamps: a turn is in flight from its start until an
  // execution-end arrives AFTER it. The message list alone can't tell
  // "between steps" (newest assistant completed, next not created yet)
  // from "turn done", so the gap is covered by these stamps.
  property real turnStartMs: 0
  property real execEndMs: 0
  property real lastChangeMs: Date.now()  // last visible message-list change
  property string prevTopKey: ""          // newest message identity at previous load
  property real lastDeltaMs: 0            // last streaming token received
  property bool clearBusyNextLoad: false  // panel (re)opened: all-complete ⇒ idle
  property bool rebuilding: false         // chatModel rebuild in progress (guards scroll state)
  property bool chatLoading: false        // switching chats: history still arriving
  property var rebuildQueue: []            // chunked structural rebuild (see startRebuild)
  property int rebuildAt: 0
  readonly property int rebuildChunkSize: 8  // delegates built per frame
  // chatModel row index: "key|kind" -> row. The model is append-only between
  // rebuilds, so this stays valid and turns the streaming hot path (flush /
  // applyEnded) from an O(n) row scan into an O(1) lookup.
  property var modelKeyMap: ({})
  property var modelKeys: []               // row -> "key|kind" (mirrors the model)
  property var textByKey: ({})             // "key|kind" -> text, guards against shrink
  // rendered-markdown memo: session switches / rebuilds recreate delegates
  // with identical text, so the expensive parse is done once per text
  property var mdCache: ({})
  property var mdCacheOrder: []
  readonly property int mdCacheMax: 128

  // the message TextEdit that last got a mouse selection — Ctrl+C is
  // pressed on the BAR's hidden input (it owns the keyboard), which
  // forwards the copy to this
  property var selEdit: null

  // ---------- SSE stream ----------
  //
  // Qt's QML XMLHttpRequest does not reliably deliver chunked/SSE bodies
  // incrementally (it can stay silent until DONE), so the stream is
  // consumed through a long-running `curl` process instead. SplitParser's
  // segments aren't newline-aligned and it swallows the blank-line
  // terminators, so raw chunks are re-framed into SSE lines here; a data
  // payload is dispatched when the next line (not a blank line) arrives.
  // The watchdog restarts the stream if no bytes (not even the
  // ": heartbeat") arrive for 30s.
  property bool streamLive: false
  property int streamFails: 0     // consecutive failed connects while closed
  property string sseBuf: ""
  property string rawBuf: ""

  // keep plain XMLHttpRequest objects alive while a request is in flight
  property var inflight: []

  implicitWidth: label.implicitWidth + 14

  // ---------- http helper ----------
  function api(method, path, body, cb) {
    if (root.svcUrl === "") return;
    const x = new XMLHttpRequest();
    root.inflight.push(x);
    x.onreadystatechange = () => {
      if (x.readyState !== 4) return;
      const i = root.inflight.indexOf(x);
      if (i >= 0) root.inflight.splice(i, 1);
      const ok = x.status >= 200 && x.status < 300;
      let data = null;
      try { data = JSON.parse(x.responseText); } catch (e) {}
      if (cb) cb(ok, data, x.status);
    };
    x.open(method, root.svcUrl + path);
    // a hung request must not wedge `sending` forever — XHR fires
    // readyState 4 (status 0) on timeout, which is handled like a failure
    x.timeout = 20000;
    x.setRequestHeader("Authorization", "Basic " + Qt.btoa("opencode:" + root.svcPw));
    x.setRequestHeader("Content-Type", "application/json");
    x.send(body === null ? null : JSON.stringify(body));
  }

  // ---------- SSE stream ----------
  function connectStream() {
    if (root.svcUrl === "" || !root.svcUp || sseProc.running) return;
    root.sseBuf = "";
    root.rawBuf = "";
    sseProc.command = [
      "curl", "-sN",
      "-u", "opencode:" + root.svcPw,
      "-H", "Accept: text/event-stream",
      root.svcUrl + "/api/event"
    ];
    sseProc.running = true;
    root.streamLive = true;
  }

  // the stream is intentionally not torn down when the panel closes (it
  // drives "turn finished" notifications); this only bounces a dead one
  function restartStream() {
    sseProc.running = false;
    connectStream();
  }

  function streamLine(chunk) {
    watchdog.restart();
    // SplitParser's segments are not reliably newline-aligned (chunks can
    // contain or start mid-line), so re-frame lines here from raw chunks.
    // One split instead of repeated indexOf+slice keeps this cheap under the
    // token-rate delta stream.
    root.rawBuf += chunk;
    const parts = root.rawBuf.split("\n");
    root.rawBuf = parts.pop();          // trailing partial line, if any
    for (let i = 0; i < parts.length; i++) {
      const line = parts[i];
      root.sseLine(line.endsWith("\r") ? line.slice(0, -1) : line);
    }
  }

  // one complete SSE line
  function sseLine(line) {
    if (line.startsWith("data:")) {
      // previous payload is complete once another line shows up
      // (the event stream's blank-line terminators don't survive
      // SplitParser, so this — not the blank line — is the dispatch
      // trigger; a following blank/comment line flushes the last one)
      if (root.sseBuf !== "") root.dispatchSse();
      root.sseBuf += line.slice(5).replace(/^ /, "");
      return;
    }
    root.dispatchSse();
  }

  function dispatchSse() {
    if (root.sseBuf === "") return;
    const payload = root.sseBuf;
    root.sseBuf = "";
    try { root.handleEvent(JSON.parse(payload)); } catch (e) {}
  }

  Process {
    id: sseProc

    stdout: SplitParser {
      onRead: line => root.streamLine(line)
    }

    onExited: {
      // flush a final event that arrived without a trailing line
      root.dispatchSse();
      root.streamLive = false;
      if (!root.svcUp) return;
      // the stream is no longer tied to panel visibility (it feeds background
      // notifications), so reconnect while the service is up
      if (root.panelOpen) {
        root.streamFails = 0;
        streamRetry.restart();
        return;
      }
      // while closed, bound the reconnect loop so a server that accepts
      // connections but drops them cannot hammer it forever
      root.streamFails += 1;
      if (root.streamFails > 10) return;
      retryTimer.restart();
    }
  }

  function handleEvent(ev) {
    const sid = root.session ? root.session.id : "";
    const d = ev.data || {};
    const mine = d.sessionID === sid;
    switch (ev.type) {
      // token-level chunks — applied directly, no reload. Skipped while the
      // panel is closed: the delegate bindings still run (the popup content
      // exists) so every flush would re-parse live markdown for something
      // nobody sees. The final text arrives via *.ended and the history is
      // reloaded on open.
      case "session.text.delta":
        if (mine && root.panelOpen) applyDelta(d, "assistant");
        return;
      case "session.reasoning.delta":
        if (mine && root.panelOpen) applyDelta(d, "reasoning");
        return;
      // part finalized: the FULL text rides in the event itself — apply it
      // directly (the GET /message reload lags the stream and would drop
      // the part back to a stale state)
      case "session.text.ended":
      case "session.reasoning.ended":
        if (mine) {
          applyEnded(d, ev.type === "session.reasoning.ended" ? "reasoning" : "assistant");
          refreshSoon();
        }
        return;
      case "session.step.started":
      case "session.step.streamed":
      case "session.usage.updated":
        if (mine) refreshSoon();
        return;
      // per-step lifecycle: "tool-calls" means more steps are coming (the
      // turn continues), anything else ("stop", …) is the turn's end —
      // authoritative for `busy`, unlike the execution events which are
      // sometimes lost across stream reconnects
      case "session.step.ended":
        if (mine) {
          if (d.finish && d.finish !== "tool-calls") {
            root.busy = false;
            root.execEndMs = Date.now();
            // ping the desktop only when the panel is CLOSED (while it is
            // open you can see the turn finish — a popup is just noise)
            if (!root.panelOpen) root.notifyDone(false, ev.id);
          } else {
            root.busy = true;
          }
          refreshSoon();
        }
        // a step ending is the cheapest signal to refresh the running dots —
        // only useful while they are on screen
        if (root.panelOpen) root.loadActive();
        return;
      // a failed step may not be followed by a step.ended — clear busy here
      // so the turn cannot wedge the input disabled
      case "session.step.failed":
        if (mine) { root.busy = false; root.execEndMs = Date.now(); refreshSoon(); }
        if (root.panelOpen) root.loadActive();
        return;
      case "session.execution.started":
        if (mine) { root.busy = true; root.turnStartMs = Date.now(); }
        return;
      case "session.execution.succeeded":
        if (mine) { root.execEndMs = Date.now(); refreshSoon(); }
        return;
      case "session.execution.failed":
      case "session.execution.interrupted":
        if (mine) { root.busy = false; root.execEndMs = Date.now(); refreshSoon(); }
        return;
      case "session.error":
        if (mine) {
          root.busy = false;
          root.execEndMs = Date.now();
          const e = d.error || d;
          const msg = typeof e === "string" ? e
              : (e && (e.message || e.name)) || "";
          root.error = msg !== "" ? msg : "model error";
          if (!root.panelOpen) root.notifyDone(true, ev.id);
          refreshSoon();
        }
        return;
      case "session.inbox.enqueued":
      case "session.inbox.delivered":
        if (mine) refreshSoon();
        return;
      // the session list itself changed (created elsewhere, moved, deleted,
      // gone idle) — refetch it so the sessions menu never goes stale
      case "session.created":
      case "session.deleted":
      case "session.moved":
      case "session.forked":
        // the picker is only on screen with the panel; opening refreshes it
        if (root.panelOpen) root.loadSession();
        return;
      case "session.idle":
      case "session.active":
        if (root.panelOpen) root.loadActive();
        return;
      case "session.agent.selected":
      case "session.model.selected":
        if (mine) { root.loadSessionInfo(); refreshSoon(); }
        return;
      case "permission.asked":
        root.loadPerms();
        refreshSoon();
        return;
      case "permission.replied":
        root.loadPerms();
        return;
      // select questions (the question tool) surface as forms
      case "form.created":
      case "form.updated":
      case "form.replied":
      case "form.cancelled":
        root.loadForms();
        root.loadPerms();
        refreshSoon();
        return;
      case "server.connected":
        root.streamLive = true;
        root.streamFails = 0;
        return;
    }
    // everything else belonging to this session (tool lifecycle, errors,
    // compaction, …): one debounced reload covers it
    if (mine && ev.type.startsWith("session.")) refreshSoon();
  }

  // stream a token into the model. Deltas are BATCHED (flushed ~12x/s) —
  // applying every token makes the markdown delegate re-parse and the
  // column re-layout per token (stutter, partial renders). Deltas key parts
  // by assistantMessageID + per-type ordinal (the same key loadMessages
  // builds); unknown parts are queued and appended on flush so streaming
  // shows even before the part is persisted server-side.
  property var pendingDeltas: ({})

  function applyDelta(d, kind) {
    root.lastDeltaMs = Date.now();
    const key = (d.assistantMessageID || "") + ":"
        + (kind === "reasoning" ? "reasoning" : "text") + ":" + (d.ordinal || 0);
    const mapKey = key + "|" + kind;
    root.pendingDeltas[mapKey] = (root.pendingDeltas[mapKey] || "") + d.delta;
    if (!deltaFlush.running) deltaFlush.start();
  }

  // a part just ended: the event carries its FULL text — apply it
  // authoritatively (never shorter than what's on screen), drop any pending
  // deltas for it (stale partials), and mark it settled (markdown render)
  function applyEnded(d, kind) {
    if (!d || typeof d.text !== "string") return;
    const key = (d.assistantMessageID || "") + ":"
        + (kind === "reasoning" ? "reasoning" : "text") + ":" + (d.ordinal || 0);
    const k = key + "|" + kind;
    delete root.pendingDeltas[k];
    const i = root.modelIndex(key, kind);
    if (i >= 0) {
      // never let the authoritative full text shrink what is on screen
      if (d.text.length >= (root.textByKey[k] || "").length) {
        root.textByKey[k] = d.text;
        chatModel.setProperty(i, "text", d.text);
      }
      chatModel.setProperty(i, "live", false);
    } else {
      // part was never streamed to us — add it settled
      root.modelAppend({ key: key, kind: kind, text: d.text,
                         name: "", state: "", toolIn: "", toolOut: "",
                         diff: "", live: false });
    }
    if (chatView.pinned) Qt.callLater(chatView.stick);
  }

  function flushDeltas() {
    const pend = root.pendingDeltas;
    root.pendingDeltas = {};
    let stuck = false;
    for (const mapKey in pend) {
      const sep = mapKey.lastIndexOf("|");
      const key = mapKey.slice(0, sep);
      const kind = mapKey.slice(sep + 1);
      const add = pend[mapKey];
      const i = root.modelIndex(key, kind);
      if (i >= 0) {
        const t = (root.textByKey[mapKey] || "") + add;
        root.textByKey[mapKey] = t;
        chatModel.setProperty(i, "text", t);
        chatModel.setProperty(i, "live", true);
      } else {
        root.modelAppend({ key: key, kind: kind, text: add,
                           name: "", state: "", toolIn: "", toolOut: "",
                           diff: "", live: true });
      }
      stuck = true;
    }
    // callLater: stick after the layout pass, against fresh contentHeight
    if (stuck) Qt.callLater(chatView.stick);
  }

  Timer {
    id: deltaFlush
    interval: 80
    repeat: true
    onTriggered: {
      root.flushDeltas();
      if (Object.keys(root.pendingDeltas).length === 0) deltaFlush.stop();
    }
  }

  // ---------- model index ----------
  // All appends/clears go through here so the key index and text map stay in
  // lockstep with the ListModel.
  function modelAppend(d) {
    const k = d.key + "|" + d.kind;
    root.modelKeyMap[k] = root.modelKeys.length;
    root.modelKeys.push(k);
    root.textByKey[k] = d.text === undefined ? "" : d.text;
    chatModel.append(d);
  }

  function modelClear() {
    chatModel.clear();
    root.modelKeyMap = ({});
    root.modelKeys = [];
    root.textByKey = ({});
    // deltas queued for the model being dropped must not flush into the
    // replacement (they would append the old chat's tokens as new rows)
    root.pendingDeltas = ({});
  }

  function modelIndex(key, kind) {
    const i = root.modelKeyMap[key + "|" + kind];
    return i === undefined ? -1 : i;
  }

  // ---------- chunked structural rebuild ----------
  // A session switch (or any reorder) replaces the whole model. Doing
  // clear() + append(everything) in one call makes Qt create every delegate
  // and parse every markdown block on the main thread in a single frame:
  // animations freeze and the chat then pops in fully formed. Appending in
  // small batches across frames keeps the event loop responsive.
  function startRebuild(items) {
    root.modelClear();
    root.startAppend(items);
    if (items.length === 0) root.chatLoading = false;
  }

  // append-only variant (new messages / a large tail): no clear, so the
  // already-visible history is not re-created
  function startAppend(items) {
    root.rebuildQueue = items;
    root.rebuildAt = 0;
    if (items.length === 0) { root.rebuilding = false; return; }
    rebuildTimer.running = true;
  }

  function rebuildChunk() {
    const q = root.rebuildQueue;
    let n = 0;
    while (root.rebuildAt < q.length && n < root.rebuildChunkSize) {
      root.modelAppend(q[root.rebuildAt]);
      root.rebuildAt += 1;
      n += 1;
    }
    if (root.rebuildAt >= q.length) {
      rebuildTimer.running = false;
      root.rebuildQueue = [];
      root.rebuilding = false;
      root.chatLoading = false;
      if (chatView.pinned) Qt.callLater(chatView.stick);
    }
  }

  // interval 1ms (not 0) so the render pass gets a chance between batches
  Timer {
    id: rebuildTimer
    interval: 1
    repeat: true
    onTriggered: root.rebuildChunk()
  }

  // coalesced server reload. While the panel is closed there is nothing to
  // repaint and deltas still land on the model, so the reload is skipped —
  // a full reload happens on the next open anyway.
  function refreshSoon() { if (root.panelOpen) refreshTimer.restart(); }

  // everything the panel must do when it becomes (or stays) visible. Called
  // from onPanelOpenChanged, NOT from PopupWindow.onVisibleChanged, so a
  // rapid close→reopen still reconnects: `visible` never dropped to false,
  // but panelOpen did change.
  function panelShown() {
    // the BAR window holds compositor keyboard focus (its OnDemand grab was
    // taken by the pill's click) — focus the hidden TextInput that lives
    // there and mirror the active tab's field into it; re-asserted shortly
    // after, once the keyboard mode change and map have settled
    focusPanelField();
    refocusTimer.restart();
    root.streamFails = 0;      // reopening the panel re-arms background retries
    if (root.svcUp) root.connectStream();
    // events missed while closed may not have been reconciled — reload now
    // (also reconciles a stale `busy` via loadMessages)
    root.lastChangeMs = Date.now();
    root.clearBusyNextLoad = true;
    root.loadSession();
    root.loadExtras();       // agents/models/commands may have appeared
    root.loadMessages();
    root.loadPerms();
    root.loadForms();
    root.loadSessionInfo();
    activePoll.restart();
  }

  // focus the single real editor (the bar's hiddenInput) and mirror the
  // active tab's field into it
  function focusPanelField() {
    if (!root.panelOpen) return;
    root.inputSyncing = true;
    hiddenInput.text = root.mode === "translate" ? translateBox.sourceText
                                                 : inputField.text;
    root.inputSyncing = false;
    hiddenInput.forceActiveFocus();
  }

  Timer {
    id: refocusTimer
    interval: 250
    onTriggered: if (root.panelOpen) hiddenInput.forceActiveFocus();
  }

  Timer {
    id: refreshTimer
    interval: 120
    onTriggered: {
      // never rebuild mid-stream: a clear() while deltas are arriving drops
      // the not-yet-persisted tokens (flicker, partial text). Wait until
      // the stream pauses — step/tool boundaries reload all the same.
      if (Date.now() - root.lastDeltaMs < 400) { restart(); return; }
      root.loadMessages();
      root.loadPerms();
      root.loadForms();
      root.loadSessionInfo();
    }
  }

  Timer {
    id: streamRetry
    interval: 2000
    onTriggered: root.connectStream()
  }

  // while the panel is open, poll the set of running sessions so the
  // sessions menu can show which agents are working (SSE step events also
  // refresh it, this just covers missed/replayed events)
  Timer {
    id: activePoll
    interval: 4000
    repeat: true
    onTriggered: root.loadActive()
  }

  // no bytes at all (not even the heartbeat) for 30s → restart the stream.
  // Must be well above the server's heartbeat interval.
  Timer {
    id: watchdog
    interval: 30000
    onTriggered: root.restartStream()
  }

  // ---------- service discovery ----------
  function ensureService() {
    root.svcTries = 0;
    readService();
  }

  // read the already-loaded service.json and health-check. The file itself
  // is (re)loaded by svcFile (watchChanges) and retryTimer via reload() —
  // text() alone returns the cached copy, so a restarted service would keep
  // the stale port/password forever.
  function readService() {
    try {
      const svc = JSON.parse(svcFile.text());
      root.svcUrl = svc.url;
      root.svcPw = svc.password;
    } catch (e) { root.svcUrl = ""; }
    root.checkService();
  }

  function checkService() {
    if (root.svcUrl === "") return respawnService();
    api("GET", "/api/health", null, ok => {
      if (ok) {
        root.svcUp = true;
        root.svcTries = 0;         // recovered: allow future respawns again
        root.error = "";
        loadSession();
        loadExtras();
        connectStream();
        return;
      }
      root.svcUp = false;
      respawnService();
    });
  }

  function respawnService() {
    if (root.svcTries === 0)
      Quickshell.execDetached(["opencode2", "serve", "--service"]);
    if (++root.svcTries > 6) {
      root.error = "opencode service unreachable";
      return;
    }
    retryTimer.restart();
  }

  FileView {
    id: svcFile
    path: Quickshell.env("HOME") + "/.local/state/opencode/service.json"
    blockAllReads: true
    preload: true
    // the service rewrites this file on every (re)start with a new port and
    // password — watch it so the widget reconnects instead of talking to
    // the dead server forever
    watchChanges: true
    onLoaded: root.readService()
    onLoadFailed: root.checkService()
    onFileChanged: svcFile.reload()
  }

  // the panel's own chat store (see panelSessions). stateDir is created by
  // quickshell itself; FileView caches the text, so a hand-edit only takes
  // effect after a config reload — otherwise the next write clobbers it.
  FileView {
    id: panelSessionsFile
    path: Quickshell.stateDir + "/opencode-panel-sessions.json"
    blockAllReads: true
    preload: true
    printErrors: false
    watchChanges: false
    onLoaded: {
      root.panelSessionsLoaded = true;
      const raw = panelSessionsFile.text();
      if (!raw) return;
      let parsed = null;
      try { parsed = JSON.parse(raw); } catch (e) { return; }
      if (!parsed || typeof parsed !== "object") return;
      const next = {};
      for (const id in parsed) if (parsed[id]) next[id] = true;
      root.panelSessions = next;
    }
    // no store yet (first run) — an empty store is a valid, loaded one
    onLoadFailed: root.panelSessionsLoaded = true
  }

  Timer {
    id: retryTimer
    interval: 1200
    // reload() forces a fresh disk read; its onLoaded then runs readService()
    onTriggered: svcFile.reload()
  }

  // ---------- data loaders ----------
  // remember/forget a session the panel owns (created here or opened from the
  // picker). Persisted so a restart doesn't make the panel adopt whatever the
  // TUI happens to be running.
  function rememberPanelSession(id) {
    if (!id || root.panelSessions[id]) return;
    const next = Object.assign({}, root.panelSessions);
    next[id] = true;
    root.panelSessions = next;
    panelSessionsFile.setText(JSON.stringify(next));
  }

  function forgetPanelSession(id) {
    if (!id || !root.panelSessions[id]) return;
    const next = Object.assign({}, root.panelSessions);
    delete next[id];
    root.panelSessions = next;
    panelSessionsFile.setText(JSON.stringify(next));
  }

  // drop ids that no longer exist on the server, so the store (and the
  // picker) can't grow forever. `known` must be the FULL session list — a
  // truncated page would wrongly forget panel chats that fell off the end.
  function prunePanelSessions(known) {
    // never prune before the store was read from disk: the first server
    // reply could otherwise wipe every remembered id
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
    panelSessionsFile.setText(JSON.stringify(next));
  }

  // one place owns the session list + the running-session map; it runs on
  // service connect, on panel open and whenever the server reports the list
  // changed (session.created/moved/deleted). `parentID=null` keeps subagent
  // child sessions out of the picker — they are not chats you pick.
  function loadSession() {
    api("GET", "/api/session/active", null, (okA, a) => {
      root.activeSessions = (okA && a && a.data) ? a.data : {};
      api("GET", "/api/session?limit=200&parentID=null", null, (ok, data) => {
        if (!ok || !data || !data.data) return;
        root.prunePanelSessions(data.data);
        // the picker and the auto-pick only ever see panel-owned chats; the
        // full server list is used above to prune dead ids
        const own = data.data.filter(s => root.panelSessions[s.id]);
        root.sessionList = own;
        // remember the model/agent last used anywhere — new chats start
        // with them instead of showing the placeholder chips
        for (const s of data.data) {
          if (!root.lastModel && s.model) root.lastModel = s.model;
          if (root.lastAgent === "" && s.agent) root.lastAgent = s.agent;
          if (root.lastModel && root.lastAgent !== "") break;
        }
        // already chatting (or a "+" is pending): never yank the view
        if (root.session || root.newChatPending) return;
        root.session = root.pickSession(own);
        root.chatLoading = root.session !== null;
        chatView.pinned = true;
        root.resetTurnState();
        root.loadMessages();
        root.loadPerms();
        root.loadForms();
        root.loadSessionInfo();
      });
    });
  }

  // which chat to open when the panel has no session yet: the newest of this
  // directory among the panel's own chats, else the newest overall. Sessions
  // running elsewhere (TUI, nvim) are never adopted automatically.
  function pickSession(list) {
    if (!list || list.length === 0) return null;
    const here = list.filter(s =>
      s.location && s.location.directory === Quickshell.env("HOME"));
    return (here.length ? here : list)[0] || null;
  }

  // just the running map — polled while the panel is open and refreshed on
  // every step boundary, so the sessions menu can show who is working
  function loadActive() {
    api("GET", "/api/session/active", null, (ok, d) => {
      if (ok && d && d.data) root.activeSessions = d.data;
    });
  }

  // wipe everything tied to "the turn currently in flight". Called whenever
  // the displayed session changes — otherwise a turn in flight on session A
  // keeps the pill green, shows "thinking…" and disables input on session B
  function resetTurnState() {
    root.busy = false;
    root.sending = false;
    root.error = "";
    root.turnStartMs = 0;
    root.execEndMs = 0;
    root.lastChangeMs = Date.now();
    root.prevTopKey = "";
    root.clearBusyNextLoad = false;
  }

  // untitled sessions are common (integrations, never-used new chats);
  // never render the raw ses_… id in the picker
  function sessionLabel(s) {
    if (!s) return "opencode";
    if (s.title) return s.title;
    const base = root.locationLabel(s);
    return base ? "novo chat · " + base : "novo chat";
  }

  // a short, human location for an untitled session: last path segment of
  // subpath/directory, skipping a bare numeric segment (nvim's
  // /tmp/nvim.<user>/<hash>/0 should read "nvim.<user>", not "0")
  function locationLabel(s) {
    const loc = s.location || {};
    const parts = (s.subpath || loc.directory || "")
        .replace(/\/+$/, "").split("/").filter(x => x !== "");
    let last = parts[parts.length - 1] || "";
    if (/^\d+$/.test(last) && parts.length > 1) last = parts[parts.length - 2];
    return last;
  }

  // refresh the open session's live fields (title, cost, model, agent) —
  // the server re-titles the session after the first prompt
  function loadSessionInfo() {
    if (!root.session) return;
    const sid = root.session.id;
    api("GET", "/api/session/" + sid, null, (ok, d) => {
      // a slow reply from the previous session must not overwrite the one
      // the user just switched to
      if (ok && d && d.data && root.session && root.session.id === sid)
        root.session = d.data;
    });
  }

  function loadExtras() {
    api("GET", "/api/agent", null, (ok, d) => {
      root.agents = (ok && d && d.data ? d.data : [])
        .filter(a => !a.hidden && a.mode !== "subagent")
        .map(a => ({ id: a.id, name: a.name }));
    });
    api("GET", "/api/model", null, (ok, d) => {
      root.models = (ok && d && d.data ? d.data : [])
        .map(m => ({ id: m.modelID, providerID: m.providerID, name: m.name || m.modelID }));
    });
    api("GET", "/api/command", null, (ok, d) => {
      root.commands = (ok && d && d.data ? d.data : [])
        .map(c => ({ name: c.name, description: c.description || "" }));
    });
  }

  function toolOutText(state) {
    if (!state) return "";
    if (typeof state.output === "string") return state.output;
    if (state.content)
      return state.content
        .filter(c => c.type === "text" && (c.text || "") !== "")
        .map(c => c.text).join("\n");
    return "";
  }

  // pretty-print a tool's input only on demand: the model stores the raw
  // object and this runs when the fold-out is opened, not on every reload
  // (JSON.stringify of every tool input on every reload added up)
  function toolInputText(v) {
    if (v === null || v === undefined || v === "") return "";
    if (typeof v === "string") return v;
    try { return JSON.stringify(v, null, 1); } catch (e) { return ""; }
  }

  // cap a joined unified diff, keeping whole lines
  function patchText(p) {
    if (p === "" || p.length <= 4000) return p;
    const cut = p.slice(0, 4000);
    return cut.slice(0, cut.lastIndexOf("\n") + 1) + " …";
  }

  // unified diff → selectable HTML: +green, −red, hunk headers muted.
  // Wrapped as monospace lines (Qt's <pre> would clip instead of wrapping).
  function renderDiff(p) {
    if (!p) return "";
    const esc = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;")
                     .replace(/>/g, "&gt;");
    const lines = p.split("\n").map(l => {
      let c = Theme.text;
      if (l.startsWith("+")) c = Theme.live;
      else if (l.startsWith("-")) c = Theme.err;
      else if (l.startsWith("@@") || l.startsWith("Index")
               || l.startsWith("---") || l.startsWith("+++")) c = Theme.muted;
      const m = l.match(/^(\s*)(.*)$/);
      const indent = m[1].replace(/\t/g, "    ").replace(/ /g, "\u00a0");
      return "<span style=\"color:" + c + "\">" + indent + esc(m[2]) + "</span>";
    });
    return "<p style=\"margin:0\"><code>" + lines.join("<br/>") + "</code></p>";
  }

  // ---------- markdown rendering ----------
  // Qt's MarkdownText packs every block with no spacing, no code-block
  // background and no wrapping inside <pre>. This converts the assistant
  // markdown to the small RichText subset QTextDocument actually honors
  // (margins, tables, block backgrounds), which reads much better.
  function mdEsc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function mdInline(s) {
    s = mdEsc(s);
    const tok = [];
    const stash = html => { tok.push(html); return "\u0000" + (tok.length - 1) + "\u0000"; };
    // code spans/links are stashed so emphasis never rewrites their contents
    s = s.replace(/`([^`]+)`/g, (_, c) => stash("<code>" + c + "</code>"));
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g,
                  (_, t, u) => stash('<a href="' + u + '">' + t + "</a>"));
    s = s.replace(/\*\*(?=\S)([^*]+?\S)\*\*/g, "<b>$1</b>");
    s = s.replace(/(^|\s)__(?=\S)([^_]+?\S)__(?=$|\s)/g, "$1<b>$2</b>");
    s = s.replace(/(^|[^*])\*(?=\S)([^*]+?\S)\*(?=$|[^*\w])/g, "$1<i>$2</i>");
    s = s.replace(/(^|\s)_(?=\S)([^_]+?\S)_(?=$|\s)/g, "$1<i>$2</i>");
    s = s.replace(/~~([^~]+)~~/g, "<s>$1</s>");
    s = s.replace(/\u0000(\d+)\u0000/g, (_, i) => tok[+i]);
    return s;
  }

  function mdSplitRow(s) {
    s = s.trim();
    if (s.startsWith("|")) s = s.slice(1);
    if (s.endsWith("|")) s = s.slice(0, -1);
    return s.split("|").map(x => x.trim());
  }

  function mdIsTableSep(s) {
    return s.indexOf("|") !== -1 && /^[\s|:-]+$/.test(s) && s.indexOf("-") !== -1;
  }

  function mdTable(header, rows) {
    const th = header.map(c =>
        '<th style="padding:5px 9px;">' + mdInline(c) + "</th>").join("");
    const trs = rows.map(r => "<tr>" + r.map(c =>
        '<td style="padding:5px 9px;">' + mdInline(c) + "</td>").join("") + "</tr>").join("");
    return '<table width="100%" cellspacing="0" cellpadding="0" border="1" '
         + 'style="border-color:' + Theme.border + '; margin-top:9px; margin-bottom:9px;">'
         + "<tr>" + th + "</tr>" + trs + "</table>";
  }

  // code as a full-width block: background from the table cell, monospace
  // from <code>, and leading spaces kept as nbsp so long lines still wrap
  function mdCodeBlock(code) {
    const lines = code.split("\n").map(l => {
      const m = l.match(/^(\s*)(.*)$/);
      const indent = m[1].replace(/\t/g, "    ").replace(/ /g, "\u00a0");
      return indent + mdEsc(m[2]);
    });
    return '<table width="100%" cellspacing="0" cellpadding="0" '
         + 'style="margin-top:9px; margin-bottom:9px;">'
         + '<tr><td style="padding:9px 10px; background-color:' + Theme.surface + ';">'
         + '<p style="margin:0;"><code>' + lines.join("<br/>") + "</code></p>"
         + "</td></tr></table>";
  }

  // Memoized wrapper. The parser is called from a per-delegate binding and
  // would otherwise re-run every time a delegate is re-created (session
  // switch, chunked rebuild). `useCache === false` is for live/streaming
  // text, whose every intermediate value is unique and would only churn the
  // cache — settled text is cached and reused on rebuilds.
  function renderMarkdown(md, useCache) {
    if (!md) return "";
    if (useCache === false) return root.renderMarkdownUncached(md);
    const hit = root.mdCache[md];
    if (hit !== undefined) return hit;
    const html = root.renderMarkdownUncached(md);
    root.mdCache[md] = html;
    root.mdCacheOrder.push(md);
    if (root.mdCacheOrder.length > root.mdCacheMax)
      delete root.mdCache[root.mdCacheOrder.shift()];
    return html;
  }

  function renderMarkdownUncached(md) {
    if (!md) return "";
    md = md.replace(/\r\n?/g, "\n");
    const lines = md.split("\n");
    const out = [];
    let i = 0;
    while (i < lines.length) {
      const line = lines[i];
      const fence = line.match(/^\s*(```+|~~~+)\s*(\S*)\s*$/);
      if (fence) {
        const marker = fence[1][0];
        const code = [];
        // compile the closing-fence matcher once, not once per code line
        const closeRe = new RegExp("^\\s*" + marker + "{3,}\\s*$");
        i++;
        while (i < lines.length && !closeRe.test(lines[i])) {
          code.push(lines[i]); i++;
        }
        i++;
        out.push(mdCodeBlock(code.join("\n")));
        continue;
      }
      if (/^\s*$/.test(line)) { i++; continue; }
      if (/^\s*([-*_])\s*\1\s*\1[\s\1]*$/.test(line)) {
        out.push('<hr style="margin-top:10px; margin-bottom:10px;"/>');
        i++; continue;
      }
      const h = line.match(/^(#{1,6})\s+(.*)$/);
      if (h) {
        const lvl = h[1].length;
        out.push("<h" + lvl + ' style="margin-top:' + (lvl <= 2 ? 14 : 11)
                 + 'px; margin-bottom:5px;">' + mdInline(h[2]) + "</h" + lvl + ">");
        i++; continue;
      }
      if (/^\s*>\s?/.test(line)) {
        const bq = [];
        while (i < lines.length && /^\s*>\s?/.test(lines[i])) {
          bq.push(lines[i].replace(/^\s*>\s?/, "")); i++;
        }
        out.push('<blockquote style="margin:7px 0 7px 0;">'
                 + bq.map(mdInline).join("<br/>") + "</blockquote>");
        continue;
      }
      if (line.indexOf("|") !== -1 && i + 1 < lines.length
          && mdIsTableSep(lines[i + 1])) {
        const header = mdSplitRow(line);
        i += 2;
        const rows = [];
        while (i < lines.length && lines[i].indexOf("|") !== -1
               && !/^\s*$/.test(lines[i])) {
          rows.push(mdSplitRow(lines[i])); i++;
        }
        out.push(mdTable(header, rows)); continue;
      }
      if (/^\s*[-*+]\s+/.test(line)) {
        const items = [];
        while (i < lines.length && /^\s*[-*+]\s+/.test(lines[i])) {
          items.push(lines[i].replace(/^\s*[-*+]\s+/, "")); i++;
        }
        out.push('<ul style="margin:7px 0 7px 0;">'
                 + items.map(t => "<li>" + mdInline(t) + "</li>").join("")
                 + "</ul>");
        continue;
      }
      if (/^\s*\d+[.)]\s+/.test(line)) {
        const items = [];
        while (i < lines.length && /^\s*\d+[.)]\s+/.test(lines[i])) {
          items.push(lines[i].replace(/^\s*\d+[.)]\s+/, "")); i++;
        }
        out.push('<ol style="margin:7px 0 7px 0;">'
                 + items.map(t => "<li>" + mdInline(t) + "</li>").join("")
                 + "</ol>");
        continue;
      }
      const para = [line];
      i++;
      while (i < lines.length && !/^\s*$/.test(lines[i])
             && !/^(#{1,6})\s+/.test(lines[i])
             && !/^\s*(```|~~~)/.test(lines[i])
             && !/^\s*>\s?/.test(lines[i])
             && !/^\s*[-*+]\s+/.test(lines[i])
             && !/^\s*\d+[.)]\s+/.test(lines[i])
             && !(i + 1 < lines.length && lines[i].indexOf("|") !== -1
                  && mdIsTableSep(lines[i + 1]))) {
        para.push(lines[i]); i++;
      }
      out.push('<p style="margin-top:7px; margin-bottom:7px;">'
               + para.map(mdInline).join("<br/>") + "</p>");
    }
    return out.join("");
  }

  // identity of the newest message including activity signals — changes on
  // new parts, text/reasoning deltas, tool state changes and completion
  function topKeyOf(m) {
    if (!m) return "";
    const parts = m.content || [];
    const lastPart = parts.length ? parts[parts.length - 1] : null;
    return m.id + ":" + parts.length + ":" + ((m.time || {}).completed || "")
        + (lastPart
          ? ":" + (lastPart.type === "tool" ? (lastPart.state || {}).status
                                            : (lastPart.text || "").length)
          : "");
  }

  // transient toast in the panel (copy confirmations, stt status, …)
  function showToast(msg) { toastText.text = msg; toastTimer.restart(); }

  function showCopyToast() { root.showToast("copied to clipboard"); }

  // ---------- clipboard image paste ----------
  // The editor is a plain TextInput, so a copied image would otherwise be
  // invisible to it. Ctrl+V is intercepted: the clipboard image is read
  // through wl-paste, downscaled to the server's image limits with magick
  // (so the server never has to resize it) and kept as base64 until send.
  function addPendingImage(b64) {
    const imgs = root.pendingImages.slice();
    // a monotonic counter, not imgs.length: removing a chip would otherwise
    // reuse a name and produce duplicate entries
    root.imageSeq += 1;
    // build the data URI once: the chip's Image binding would otherwise
    // rebuild the whole base64 string on every re-evaluation
    imgs.push({ name: "clipboard-" + root.imageSeq + ".png", b64: b64,
                uri: "data:image/png;base64," + b64 });
    root.pendingImages = imgs;
  }

  function removePendingImage(i) {
    const imgs = root.pendingImages.slice();
    imgs.splice(i, 1);
    root.pendingImages = imgs;
  }

  function imageUri(img) { return img.uri || ("data:image/png;base64," + img.b64); }

  function pasteFromClipboard(fallbackText) {
    root.pasteFallbackText = fallbackText !== false;
    pasteImageProc.base64 = "";
    pasteImageProc.running = true;
  }

  // desktop notification for a turn that ends while the panel is closed —
  // the only way to learn the job finished without reopening it. `evId` is
  // the SSE event id: every monitor's panel receives the same event, so the
  // shared marker in the Notifs singleton keeps it to a single notification.
  function notifyDone(isErr, evId) {
    if (evId !== undefined && evId !== "") {
      if (Notifs.lastOpencodeDoneEvent === evId) return;
      Notifs.lastOpencodeDoneEvent = evId;
    }
    const title = isErr ? "opencode — erro"
        : "opencode — " + ((root.session && root.session.title) || "turn complete");
    let body = isErr ? root.error : "";
    if (!isErr) {
      // tail of the newest assistant text (text.ended arrived first, so it
      // is already in the model). Walk the key index — no per-row get().
      for (let i = root.modelKeys.length - 1; i >= 0; i--) {
        const k = root.modelKeys[i];
        if (!k.endsWith("|assistant")) continue;
        const t = root.textByKey[k] || "";
        if (t !== "") {
          body = t.length > 120 ? "…" + t.slice(-120) : t;
          break;
        }
      }
    }
    body = body.replace(/\n+/g, " ").trim();
    if (body === "") body = isErr ? "unknown error" : "turn complete";
    Quickshell.execDetached(["notify-send", "-u", isErr ? "normal" : "low",
                             "-a", "opencode", title, body]);
  }

  function loadMessages() {
    if (!root.session) return;
    const sid = root.session.id;
    api("GET", "/api/session/" + sid + "/message", null, (ok, data, status) => {
      // the displayed session was deleted elsewhere (TUI, another panel):
      // drop it and let loadSession pick a live one instead of showing a
      // permanently frozen history
      if (status === 404 && root.session && root.session.id === sid) {
        root.session = null;
        root.modelClear();
        root.resetTurnState();
        root.loadSession();
        return;
      }
      if (!ok || !data || !data.data) { root.chatLoading = false; return; }
      if (!root.session || root.session.id !== sid) return;  // switched mid-flight
      const wasPinned = chatView.pinned;
      // rebuild atomically: intermediate contentHeight collapses clamp
      // contentY and would clobber the pinned/scroll state mid-rebuild
      root.rebuilding = true;
      let deferred = false;   // structural rebuild handed to rebuildTimer
      try {
      // the API returns messages newest-first; chat order is oldest-first.
      // Walk it backwards instead of copying + reversing the whole array.
      const raw = data.data;
      // streamed text must never shrink (the API copy can lag the live
      // deltas): root.textByKey mirrors the model's text, so it is read
      // directly instead of snapshotting every row on each reload

      // build the desired item list WITHOUT touching the model
      const desired = [];
      for (let mi = raw.length - 1; mi >= 0; mi--) {
        const m = raw[mi];
        if (m.type === "user") {
          desired.push({ key: m.id, kind: "user", text: m.text || "",
                         name: "", state: "", toolIn: "", toolOut: "",
                         diff: "", live: false });
        } else if (m.type === "assistant") {
          // keys match the streaming-delta scheme
          // (msgID:type:perTypeOrdinal); content can be null/missing on
          // in-flight messages — throwing here aborts the load and halves
          // the visible chat
          const done = !!(m.time && m.time.completed);
          const content = m.content || [];
          const counts = {};
          for (let ci = 0; ci < content.length; ci++) {
            const c = content[ci];
            if (!c || !c.type) continue;
            counts[c.type] = (counts[c.type] || 0) + 1;
            const key = m.id + ":" + c.type + ":" + (counts[c.type] - 1);
            if (c.type === "text" && (c.text || "").trim() !== "") {
              const k = key + "|assistant";
              const t = (c.text || "").length >= (root.textByKey[k] || "").length
                  ? c.text : root.textByKey[k];
              desired.push({ key: key, kind: "assistant", text: t,
                             name: "", state: "", toolIn: "", toolOut: "",
                             diff: "", live: !done });
            } else if (c.type === "reasoning") {
              const k = key + "|reasoning";
              const t = (c.text || "").length >= (root.textByKey[k] || "").length
                  ? (c.text || "") : (root.textByKey[k] || "");
              desired.push({ key: key, kind: "reasoning", text: t,
                             name: "", state: "", toolIn: "", toolOut: "",
                             diff: "", live: !done });
            } else if (c.type === "tool") {
              const st = c.state || {};
              const running = st.status === "running" || st.status === "streaming";
              const name = c.tool || c.name || "tool";
              // edit/patch tools carry unified diffs in metadata.files;
              // write has none — synthesize (a new file is all additions)
              const patches = ((st.metadata || {}).files || [])
                  .map(f => f.patch || "").filter(p => p !== "");
              let diff = patchText(patches.join("\n"));
              if (diff === "" && name === "write" && st.input
                  && typeof st.input.content === "string") {
                diff = patchText(st.input.content.split("\n")
                    .map(l => "+" + l).join("\n"));
              }
              desired.push({
                key: key, kind: "tool", name: name,
                state: (st.status || "") + (st.title ? " · " + st.title : running ? " · running…" : ""),
                // keep the raw input; it is only pretty-printed when the
                // fold-out is actually opened (see toolInputText)
                toolIn: st.input || null,
                toolOut: toolOutText(st),
                diff: diff,
                live: false
              });
            }
          }
        }
      }

      // a load that arrives mid chunked-rebuild supersedes it: the partial
      // model is not a safe prefix (appending in place would duplicate), so
      // cancel and rebuild from scratch below
      const wasBuilding = rebuildTimer.running;
      if (wasBuilding) {
        rebuildTimer.running = false;
        root.rebuildQueue = [];
        root.rebuildAt = 0;
      }

      // apply with the smallest possible surgery: destroying delegates
      // re-creates and re-parses every markdown text — visible flicker.
      // Same shape → field updates in place; new parts → append-only;
      // full rebuild only on structural changes (session switch, reorder).
      const n = wasBuilding ? 0 : Math.min(chatModel.count, desired.length);
      let prefix = 0;
      for (; prefix < n; prefix++) {
        const it = chatModel.get(prefix);
        if (it.key !== desired[prefix].key || it.kind !== desired[prefix].kind) break;
      }

      // `chatModel.count > 0` keeps an empty model (a fresh switch, which
      // arrives here already cleared) on the structural path: the append-only
      // path leaves `rebuilding` clear, and a multi-frame append would flip
      // `pinned` off between chunks so the final stick-to-end is dropped.
      const inPlace = !wasBuilding && chatModel.count > 0
          && (prefix === chatModel.count || prefix === desired.length);
      const tail = inPlace ? desired.slice(prefix) : desired;

      if (inPlace) {
        // shape preserved: update the common prefix in place; trailing
        // streamed extras not persisted yet simply stay (merged later)
        const upto = Math.min(chatModel.count, desired.length);
        for (let i = 0; i < upto; i++) {
          const d = desired[i];
          const it = chatModel.get(i);
          if (it.text !== d.text) {
            chatModel.setProperty(i, "text", d.text);
            root.textByKey[d.key + "|" + d.kind] = d.text;
          }
          if (it.name !== d.name) chatModel.setProperty(i, "name", d.name);
          if (it.state !== d.state) chatModel.setProperty(i, "state", d.state);
          if (it.toolIn !== d.toolIn) chatModel.setProperty(i, "toolIn", d.toolIn);
          if (it.toolOut !== d.toolOut) chatModel.setProperty(i, "toolOut", d.toolOut);
          if (it.diff !== d.diff) chatModel.setProperty(i, "diff", d.diff);
          // `live` only ever settles true → false (part finished)
          if (it.live && !d.live) chatModel.setProperty(i, "live", false);
        }
        if (tail.length > root.rebuildChunkSize) {
          // a large tail is appended across frames, not in one blocking loop.
          // This only grows the content, so `rebuilding` is left clear and
          // `pinned` keeps tracking the user's scroll during the append.
          root.startAppend(tail);
        } else {
          for (const d of tail) root.modelAppend(d);
          root.chatLoading = false;
        }
      } else {
        // different shape (session switch / reorder) or a superseded rebuild:
        // clear and rebuild across frames, hidden behind the loading state
        if (!wasBuilding) root.chatLoading = true;
        root.startRebuild(desired);
        deferred = true;
      }

      // busy reconciliation: an incomplete assistant message anywhere means
      // a step is in flight → busy. Clearing is left to the per-step
      // `finish` events (the message list can't tell "between steps" from
      // "turn done"); while the panel is CLOSED nothing can be observed
      // mid-gap, so all-complete there means done.
      const anyIncomplete = raw.some(m =>
        m.type === "assistant" && !(m.time && m.time.completed));
      if (anyIncomplete) {
        root.busy = true;
      } else if (!root.panelOpen || root.clearBusyNextLoad) {
        // closing the panel stops all observation, so all-complete there
        // (or on the reload right after (re)opening) means the turn is done
        root.busy = false;
        root.clearBusyNextLoad = false;
      }
      // escape hatch: if the message list has not changed for 30s while the
      // stream is dead, a missed execution-end would wedge us busy forever
      const topKey = topKeyOf(raw[0]);
      if (topKey !== root.prevTopKey) {
        root.prevTopKey = topKey;
        root.lastChangeMs = Date.now();
      }
      } catch (e) {
        // never swallow a failed rebuild silently — it halves the chat
        console.warn("chat rebuild failed:", e);
        root.chatLoading = false;
      } finally {
        // a deferred rebuild keeps `rebuilding` set until rebuildChunk ends
        if (!deferred) root.rebuilding = false;
      }
      // restore the scroll exactly where the rebuild found it
      chatView.pinned = wasPinned;
      if (wasPinned) Qt.callLater(chatView.stick);
    });
  }

  function loadPerms() {
    if (!root.session) return;
    const sid = root.session.id;
    api("GET", "/api/session/" + sid + "/permission", null, (ok, data) => {
      if (!root.session || root.session.id !== sid) return;  // switched
      root.pendingPerm = (ok && data && data.data && data.data.length)
          ? data.data[data.data.length - 1] : null;
    });
  }

  function permReply(reply) {
    if (!root.pendingPerm) return;
    const sid = root.session.id, pid = root.pendingPerm.id;
    root.pendingPerm = null;
    api("POST", "/api/session/" + sid + "/permission/" + pid + "/reply",
        { reply: reply }, () => root.loadPerms());
  }

  // ---------- select questions (forms) ----------
  // The question tool surfaces as a pending form; without rendering it the
  // turn waits forever. Forms carry fields with options (single/multi).
  function loadForms() {
    if (!root.session) return;
    const sid = root.session.id;
    api("GET", "/api/session/" + sid + "/form", null, (ok, data) => {
      if (!root.session || root.session.id !== sid) return;  // switched
      const list = (ok && data && data.data) ? data.data : [];
      root.pendingForms = list;
      // seed/clean the answers map for the forms currently pending
      const ans = Object.assign({}, root.formAnswers);
      for (const f of list) if (!(f.id in ans)) ans[f.id] = {};
      for (const k in ans) if (!list.some(f => f.id === k)) delete ans[k];
      root.formAnswers = ans;
    });
  }

  function formAnswer(fid, key) {
    const f = root.formAnswers[fid];
    return f ? f[key] : undefined;
  }

  function formSetAnswer(fid, key, value) {
    const ans = Object.assign({}, root.formAnswers);
    const f = Object.assign({}, ans[fid] || {});
    f[key] = value;
    ans[fid] = f;
    root.formAnswers = ans;
  }

  function formOptionSelected(form, field, opt) {
    const cur = root.formAnswer(form.id, field.key);
    if (field.type === "multiselect") return Array.isArray(cur) && cur.indexOf(opt.value) >= 0;
    return cur === opt.value;
  }

  function formToggleOption(form, field, opt) {
    const cur = root.formAnswer(form.id, field.key);
    if (field.type === "multiselect") {
      const arr = Array.isArray(cur) ? cur.slice() : [];
      const i = arr.indexOf(opt.value);
      if (i >= 0) arr.splice(i, 1); else arr.push(opt.value);
      root.formSetAnswer(form.id, field.key, arr);
    } else {
      root.formSetAnswer(form.id, field.key, opt.value);
    }
  }

  // a field is shown (and required) only while every `when` condition holds
  // against the answers given so far (Form.When: {key, op: eq|neq, value})
  function formFieldVisible(form, field) {
    const conds = field.when || [];
    for (const c of conds) {
      const cur = root.formAnswer(form.id, c.key);
      const eq = (cur === undefined ? "" : cur) === c.value;
      if (!(c.op === "eq" ? eq : !eq)) return false;
    }
    return true;
  }

  function formSubmit(form) {
    if (!root.session) return;
    const ans = root.formAnswers[form.id] || {};
    for (const fld of form.fields) {
      if (!fld.required || !root.formFieldVisible(form, fld)) continue;
      const v = ans[fld.key];
      if (v === undefined || v === null || v === ""
          || (Array.isArray(v) && v.length === 0)) {
        root.showToast("missing answer: " + (fld.title || fld.key));
        return;
      }
    }
    api("POST", "/api/session/" + root.session.id + "/form/" + form.id + "/reply",
        { answer: ans }, () => root.loadForms());
  }

  function formCancel(form) {
    if (!root.session) return;
    api("POST", "/api/session/" + root.session.id + "/form/" + form.id + "/cancel",
        {}, () => root.loadForms());
  }

  // the panel window is keyboard-less, so a form text field can't be typed
  // into directly — route the answer through the main editor instead
  function formBeginText(form, field) {
    root.formTextTarget = { formID: form.id, key: field.key,
                            title: field.title || field.key, form: form };
    inputField.text = "";
    hiddenInput.text = "";
    hiddenInput.forceActiveFocus();
    // closing any menu must not restore a parked draft into this field
    if (root.menu !== "") { root.menuSavedInput = ""; root.menu = ""; }
  }

  function formCommitText() {
    const t = root.formTextTarget;
    if (!t) return false;
    const raw = inputField.text.trim();
    const fld = (t.form.fields || []).find(f => f.key === t.key);
    // number/integer answers must be sent as Form.Value numbers, not text
    if (fld && (fld.type === "number" || fld.type === "integer")) {
      const n = Number(raw);
      if (raw === "" || isNaN(n)) {
        root.showToast("invalid number");
        inputField.text = "";
        return true;              // stay on the field so it can be retyped
      }
      root.formTextTarget = null;
      inputField.text = "";
      root.formSetAnswer(t.formID, t.key,
                         fld.type === "integer" ? Math.trunc(n) : n);
      if (t.form.fields.length === 1) root.formSubmit(t.form);
      return true;
    }
    root.formTextTarget = null;
    inputField.text = "";
    if (raw !== "") {
      root.formSetAnswer(t.formID, t.key, raw);
      // single-field forms are answered as soon as the text is committed
      if (t.form.fields.length === 1) root.formSubmit(t.form);
    }
    return true;
  }

  function formCancelText() {
    if (!root.formTextTarget) return false;
    root.formTextTarget = null;
    inputField.text = "";
    return true;
  }

  // ---------- actions ----------
  // "+" only clears the view — the session is created server-side on the
  // first send. Creating it here would leave an empty untitled chat behind
  // every time the button is tapped (or the panel is poked by accident).
  function newChat() {
    root.session = null;
    root.newChatPending = true;   // survive a close/reopen without a reload
    root.modelClear();
    root.chatLoading = false;     // genuinely empty, not loading
    root.expanded = ({});         // fold-outs belong to the old chat
    root.resetTurnState();
    root.pendingPerm = null;
    root.pendingForms = [];
    root.formAnswers = {};
    root.formTextTarget = null;
    root.closeMenu();
    root.menuSavedInput = "";
    inputField.text = "";
    hiddenInput.text = "";
    hiddenInput.forceActiveFocus();
  }

  function switchSession(s) {
    root.session = s;
    root.newChatPending = false;
    if (s && s.id) root.rememberPanelSession(s.id);  // opened here → panel owns it
    root.modelClear();
    // show a loading state instead of the empty "ask opencode" splash while
    // the history arrives, and open the new chat pinned to the bottom
    root.chatLoading = true;
    chatView.pinned = true;
    root.expanded = ({});   // fold-outs are keyed by message id, but start clean
    // the previous chat's busy/error/scroll state must not bleed into this
    // one (a busy session A left the input disabled on an idle session B)
    root.resetTurnState();
    root.pendingPerm = null;
    root.pendingForms = [];
    root.formAnswers = {};
    root.formTextTarget = null;
    root.closeMenu();       // also restores a draft parked by the search menus
    root.loadMessages();
    root.loadPerms();
    root.loadForms();
    root.loadSessionInfo();
  }

  // remove a chat from the server (the picker's hover ✕). If it is the one
  // being viewed, clear the view and let loadSession pick another one.
  function deleteSession(s) {
    if (!s || !s.id) return;
    api("DELETE", "/api/session/" + s.id, null, ok => {
      if (!ok) { root.showToast("could not delete chat"); return; }
      if (root.session && root.session.id === s.id) {
        root.session = null;
        root.newChatPending = false;
        root.modelClear();
        root.resetTurnState();
      }
      root.forgetPanelSession(s.id);
      root.loadSession();
    });
  }

  function switchModel(m) {
    const ref = { id: m.id, providerID: m.providerID };
    root.lastModel = ref;
    if (!root.session) { root.closeMenu(); return; }  // applied on creation
    api("POST", "/api/session/" + root.session.id + "/model",
        { model: ref }, ok => {
          if (ok && root.session)
            root.session = Object.assign({}, root.session, { model: ref });
          root.closeMenu();
        });
  }

  function switchAgent(a) {
    root.lastAgent = a.id;
    if (!root.session) { root.closeMenu(); return; }  // applied on creation
    api("POST", "/api/session/" + root.session.id + "/agent",
        { agent: a.id }, ok => {
          if (ok && root.session)
            root.session = Object.assign({}, root.session, { agent: a.id });
          root.closeMenu();
        });
  }

  function interrupt() {
    if (!root.session) return;
    root.busy = false;
    root.execEndMs = Date.now();
    api("POST", "/api/session/" + root.session.id + "/interrupt", {}, () => {});
  }

  // parse trailing "@path" tokens into file attachments
  function collectFiles(text) {
    const files = [];
    const dir = root.session && root.session.location
        ? root.session.location.directory : Quickshell.env("HOME");
    const home = Quickshell.env("HOME");
    const re = /(^|\s)@([^\s,;]+)/g;
    let m;
    while ((m = re.exec(text)) !== null) {
      const start = m.index + m[1].length;
      const tok = m[2];
      // absolute and ~-anchored mentions must not be glued to the session
      // dir; encodeURI keeps `/` and `:` but escapes spaces and `#`
      let uri;
      if (tok.startsWith("/")) uri = "file://" + encodeURI(tok);
      else if (tok.startsWith("~/")) uri = "file://" + encodeURI(home + tok.slice(1));
      else uri = "file://" + encodeURI(dir + "/" + tok);
      files.push({
        uri: uri,
        name: tok,
        mention: { start: start, end: start + 1 + tok.length, text: "@" + tok }
      });
    }
    return files;
  }

  // a not-yet-created chat is only materialised here, on the first real
  // action (message or slash command), carrying the last used model/agent
  function createSession(title, cb) {
    const body = { title: title };
    if (root.lastAgent !== "") body.agent = root.lastAgent;
    if (root.lastModel) body.model = root.lastModel;
    api("POST", "/api/session", body, (ok, data) => {
      if (!ok || !data || !data.data) {
        root.sending = false;
        root.error = "could not create session";
        return;
      }
      root.session = data.data;
      root.newChatPending = false;
      root.rememberPanelSession(data.data.id);   // the panel owns this chat
      root.loadSession();         // the new chat must appear in the picker
      cb(data.data.id);
    });
  }

  function send() {
    if (root.formTextTarget !== null) { root.formCommitText(); return; }
    // the send button while a search menu is open should pick, not send the
    // search query as a message
    if (root.menuSearchable()) { root.menuPickSelected(); return; }
    if (root.sending || root.busy) return;
    const text = inputField.text.trim();
    if (text === "" && root.pendingImages.length === 0) return;
    inputField.text = "";
    root.error = "";
    root.sending = true;
    root.menu = "";

    // slash command?
    if (text[0] === "/") {
      const sp = text.indexOf(" ");
      const name = sp === -1 ? text.slice(1) : text.slice(1, sp);
      const args = sp === -1 ? "" : text.slice(sp + 1);
      const cmd = root.commands.find(c => c.name === name);
      if (!cmd) {
        root.sending = false;
        root.error = "unknown command: /" + name;
        return;
      }
      const run = sid => api("POST", "/api/session/" + sid + "/command",
          { command: name, text: args }, (ok, d, status) => {
            root.sending = false;
            if (!ok) root.error = "command failed (" + status + ")";
            else { root.busy = true; root.turnStartMs = Date.now(); root.loadMessages(); }
          });
      // a command also needs a session: materialise the pending new chat
      if (root.session) run(root.session.id);
      else createSession(text.slice(0, 60), run);
      return;
    }

    const files = collectFiles(text);
    for (const img of root.pendingImages)
      files.push({ uri: root.imageUri(img), name: img.name });
    root.pendingImages = [];
    const prompt = sid =>
      api("POST", "/api/session/" + sid + "/prompt",
          files.length ? { text: text, files: files } : { text: text },
          (ok, data, status) => {
            root.sending = false;
            chatView.pinned = true;
            chatView.stick();
            if (!ok) {
              root.error = status === 409 ? "session is busy"
                : "send failed (" + status + ")";
              return;
            }
            // the turn is in flight from here until the execution events
            // or the message reconciliation end it — no sending between
            // tool/reasoning steps
            root.busy = true;
            root.turnStartMs = Date.now();
            // the SSE stream delivers the user echo + assistant tokens
            root.loadMessages();
          });
    if (root.session) prompt(root.session.id);
    else createSession(text.slice(0, 60), prompt);
  }

  // ---------- mention / command finders ----------
  function updateFinder() {
    const text = inputField.text;
    // the searchable list menus own the input as their filter box; typing
    // just re-filters (the Repeaters bind to inputField.text) and resets the
    // keyboard selection to the top
    if (root.menuSearchable()) {
      root.menuSel = 0;
      return;
    }
    if (root.formTextTarget !== null) {
      finderTimer.stop();
      root.fileHits = [];
      if (root.menu === "files") root.menu = "";
      return;
    }
    // "/" at start with no space yet → command menu
    if (text.length > 0 && text[0] === "/" && text.indexOf(" ") === -1) {
      finderTimer.stop();
      root.fileHits = [];
      root.menu = "commands";
      return;
    }
    // trailing @token → file finder (works before a session exists too)
    const m = text.match(/@([^\s,;]*)$/);
    if (m) {
      const q = m[1];
      if (q.length === 0) {
        finderTimer.stop();
        root.finderSeq++;          // cancel any in-flight reply
        root.fileHits = [];
        root.fileSel = 0;
        if (root.menu === "files") root.menu = "";
        return;
      }
      root.menu = "files";
      root.finderSeq++;            // older in-flight replies are now stale
      root.finderQuery = q;
      // debounce: one request once typing settles, not one per keystroke
      finderTimer.restart();
      return;
    }
    finderTimer.stop();
    if (root.menu === "files") root.menu = "";
  }

  function runFinder() {
    if (root.menu !== "files" || root.finderQuery === "") return;
    const q = root.finderQuery;
    const seq = ++root.finderSeq;
    api("GET", "/api/fs/find?query=" + encodeURIComponent(q)
        + "&limit=12", null, (ok, data) => {
      if (seq !== root.finderSeq) return;   // a newer query superseded this one
      if (!ok || !data || !data.data) { root.fileHits = []; root.fileSel = 0; return; }
      root.fileHits = data.data.map(f =>
        typeof f === "string" ? { path: f, type: "file" }
                              : { path: f.path || f.name || "", type: f.type || "file" });
      root.fileSel = 0;
    });
  }

  Timer {
    id: finderTimer
    interval: 140
    onTriggered: root.runFinder()
  }

  // keyboard navigation of the @ file finder (the bar's hiddenInput owns
  // the keys, so the panel can't rely on mouse clicks alone)
  function finderMove(dir) {
    if (root.menu !== "files" || root.fileHits.length === 0) return;
    const n = root.fileHits.length;
    root.fileSel = (root.fileSel + dir + n) % n;
  }

  function finderPickSelected() {
    if (root.menu === "files" && root.fileHits.length > 0) {
      root.pickFile(root.fileHits[root.fileSel]);
      return true;
    }
    return false;
  }

  function pickFile(entry) {
    const path = typeof entry === "string" ? entry : entry.path;
    const type = typeof entry === "string" ? "file" : (entry.type || "file");
    const text = inputField.text;
    const m = text.match(/@([^\s,;]*)$/);
    if (m) {
      const dir = root.session && root.session.location
          ? root.session.location.directory : Quickshell.env("HOME");
      let rel = path;
      if (rel.indexOf(dir + "/") === 0) rel = rel.slice(dir.length + 1);
      // files get a trailing space so the mention ends; directories keep the
      // finder open, now scoped to that folder
      const suffix = type === "directory" ? "/" : " ";
      inputField.text = text.slice(0, m.index) + "@" + rel + suffix;
      inputField.cursorPosition = inputField.text.length;
    }
    root.menu = type === "directory" ? "files" : "";
    hiddenInput.forceActiveFocus();
    if (type === "directory") root.updateFinder();
  }

  function toggleFold(key) {
    const e = Object.assign({}, root.expanded);
    e[key] = !e[key];
    root.expanded = e;
  }

  // ---------- list menus (models / agents / sessions) ----------
  // These open a search box inside the panel overlay; the bar's hiddenInput
  // mirror keeps both editors in sync whichever has the keyboard, and the
  // chat draft is parked in menuSavedInput while the menu is open.
  function menuSearchable() {
    return root.menu === "models" || root.menu === "agents"
        || root.menu === "sessions";
  }

  function menuQuery() { return menuSearchField.text.trim().toLowerCase(); }

  function modelMatches(m) {
    const q = root.menuQuery();
    if (q === "") return true;
    return (m.name || "").toLowerCase().indexOf(q) !== -1
        || (m.providerID || "").toLowerCase().indexOf(q) !== -1
        || (m.id || "").toLowerCase().indexOf(q) !== -1;
  }

  function filteredModels() {
    if (root.menu !== "models") return [];
    return root.models.filter(root.modelMatches);
  }

  function filteredAgents() {
    if (root.menu !== "agents") return [];
    const q = root.menuQuery();
    if (q === "") return root.agents;
    return root.agents.filter(a =>
      (a.name || "").toLowerCase().indexOf(q) !== -1
      || (a.id || "").toLowerCase().indexOf(q) !== -1);
  }

  function filteredSessions() {
    if (root.menu !== "sessions") return [];
    const q = root.menuQuery();
    if (q === "") return root.sessionList;
    return root.sessionList.filter(s =>
      root.sessionLabel(s).toLowerCase().indexOf(q) !== -1
      || (s.agent || "").toLowerCase().indexOf(q) !== -1);
  }

  function menuCount() {
    if (root.menu === "models") return root.filteredModels().length;
    if (root.menu === "agents") return root.filteredAgents().length;
    if (root.menu === "sessions") return root.filteredSessions().length;
    return 0;
  }

  function menuMove(dir) {
    const n = root.menuCount();
    if (n === 0) { root.menuSel = 0; return; }
    root.menuSel = ((root.menuSel + dir) % n + n) % n;
  }

  function menuPickSelected() {
    if (!root.menuSearchable()) return false;
    const i = root.menuSel;
    if (root.menu === "models") {
      const l = root.filteredModels();
      if (i >= 0 && i < l.length) root.switchModel(l[i]); else root.closeMenu();
    } else if (root.menu === "agents") {
      const l = root.filteredAgents();
      if (i >= 0 && i < l.length) root.switchAgent(l[i]); else root.closeMenu();
    } else {
      const l = root.filteredSessions();
      if (i >= 0 && i < l.length) root.switchSession(l[i]); else root.closeMenu();
    }
    return true;
  }

  // open a search menu. The chat draft stays visible (and disabled) in the
  // bottom input; the menu's own field is the editor. The bar's editor is
  // cleared and kept in sync so closing restores the draft cleanly.
  function openMenu(name) {
    if (root.menu !== name) {
      if (root.menu === "") root.menuSavedInput = inputField.text;
      root.inputSyncing = true;
      hiddenInput.text = "";
      menuSearchField.text = "";
      root.inputSyncing = false;
    }
    root.menu = name;
    root.menuSel = 0;
    if (root.panelOpen) hiddenInput.forceActiveFocus();
  }

  function closeMenu() {
    if (root.menu === "") return;
    root.menu = "";
    root.menuSel = 0;
    root.inputSyncing = true;
    menuSearchField.text = "";
    // the bar's editor goes back to the parked draft shown in the field
    hiddenInput.text = inputField.text;
    root.inputSyncing = false;
    root.menuSavedInput = "";
    // hand the keyboard back to the chat editor
    if (root.panelOpen) hiddenInput.forceActiveFocus();
  }

  // keep the keyboard-selected row in view (the search row is first)
  function ensureMenuSelVisible() {
    if (!root.menuSearchable()) return;
    const rowH = 26;
    const top = 26 + root.menuSel * rowH;
    const bottom = top + rowH;
    if (top < menuFlick.contentY) menuFlick.contentY = top;
    else if (bottom > menuFlick.contentY + menuFlick.height)
      menuFlick.contentY = bottom - menuFlick.height;
  }

  function closeMenuOrPanel() {
    if (root.menu !== "") { root.closeMenu(); return; }
    root.panelOpen = false;
  }

  // Ctrl+V: read a PNG from the Wayland clipboard, shrink it to the server's
  // 2000x2000 limit and keep it as base64. Empty output means the clipboard
  // holds no image, so the editor's native text paste runs instead.
  Process {
    id: pasteImageProc
    property string base64: ""
    command: ["sh", "-c",
      "if command -v magick >/dev/null 2>&1; then " +
      "wl-paste -t image/png 2>/dev/null | magick png:- -resize '2000x2000>' png:- 2>/dev/null | base64 -w0; " +
      "else wl-paste -t image/png 2>/dev/null | base64 -w0; fi"]
    stdout: StdioCollector {
      // handle here (not onExited): the collector owns the bytes, and the
      // process may exit before the pipe is fully drained
      onStreamFinished: {
        const b64 = text.trim();
        pasteImageProc.base64 = b64;
        if (b64 !== "") root.addPendingImage(b64);
        else if (root.pasteFallbackText) hiddenInput.paste();   // no image → text paste
        else root.showToast("no image in clipboard");
      }
    }
  }

  // ---------- voice (whisper.cpp STT) ----------
  // mic pill in the input row: records via pw-record (16k mono s16), then
  // transcribes with whisper-cli into the real editor (hiddenInput) at the
  // caret, so the user can edit before sending.
  property string sttState: "idle"    // idle | rec | stt
  property int recSecs: 0
  property bool sttCancel: false      // panel closed mid-recording: discard
  readonly property string micWav: "/tmp/opencode-chat-mic.wav"
  readonly property string sttModel: Quickshell.env("HOME")
      + "/.local/share/whisper/ggml-small.bin"

  function startRec() {
    if (root.sttState !== "idle" || recProc.running || sttProc.running) return;
    root.sttCancel = false;
    recProc.running = true;
  }

  function stopRec() {
    if (root.sttState !== "rec" || !recProc.running) return;
    recProc.running = false;          // onExited → transcribe
  }

  function transcribe() {
    sttProc.out = "";
    sttProc.running = true;
  }

  function finishStt(code) {
    root.sttState = "idle";
    const t = (sttProc.out || "").replace(/\s+/g, " ").trim();
    if (t === "") {
      root.showToast(code !== 0 ? "stt failed (exit " + code + ")" : "nothing captured");
      return;
    }
    // insert at the caret of the real editor (mirrors into the popup field)
    const at = hiddenInput.cursorPosition;
    const pad = hiddenInput.text !== "" && at > 0
        && hiddenInput.text.charAt(at - 1) !== " " ? " " : "";
    hiddenInput.insert(at, pad + t);
    hiddenInput.cursorPosition = at + (pad + t).length;
    // auto-send: the transcription is the message
    if (!root.busy && !root.sending) root.send();
  }

  Process {
    id: recProc
    command: ["pw-record", "--rate", "16000", "--channels", "1",
              "--format", "s16", root.micWav]
    onStarted: { root.sttState = "rec"; root.recSecs = 0; recTimer.start(); }
    onExited: {
      recTimer.stop();
      if (root.sttCancel) { root.sttCancel = false; root.sttState = "idle"; return; }
      root.transcribe();
    }
  }

  Process {
    id: sttProc
    property string out: ""
    command: ["whisper-cli", "-m", root.sttModel, "-l", "pt", "-np", "-nt",
              "-f", root.micWav]
    stdout: SplitParser {
      onRead: data => sttProc.out += data + "\n"
    }
    onStarted: root.sttState = "stt"
    onExited: code => root.finishStt(code)
  }

  Timer {
    id: recTimer
    interval: 1000
    repeat: true
    onTriggered: root.recSecs += 1
  }

  // ---------- pill ----------
  Text {
    id: label
    anchors.centerIn: parent
    text: "󰆍"
    font.family: Theme.font
    font.bold: true
    font.pixelSize: 14
    color: root.busy ? Theme.live
         : root.panelOpen ? Theme.accent
         : (mouse.containsMouse ? Theme.accent : Theme.text)
    Behavior on color { ColorAnimation { duration: 200 } }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      root.panelOpen = !root.panelOpen;
      if (root.panelOpen) root.ensureService();
    }
  }

  Tip {
    target: root
    shown: mouse.containsMouse
    text: "intelligence central"
  }

  // keyboard: the chat input field lives in the popup window, but the
  // compositor's keyboard focus sits on the BAR surface right after the
  // pill's click (OnDemand grab) — and the bar has nothing editable, so
  // keys would be dropped. This hidden TextInput in the bar window takes
  // active focus when the panel opens and does the actual editing; the
  // popup's visible field mirrors it (both directions, so typing directly
  // into the popup after clicking it — which moves compositor focus to
  // the popup surface — also stays in sync).
  property bool inputSyncing: false

  TextInput {
    id: hiddenInput
    width: 0
    height: 0
    opacity: 0
    focus: root.panelOpen
    color: "transparent"

    onTextChanged: if (!root.inputSyncing) {
      root.inputSyncing = true;
      if (root.mode === "translate") translateBox.sourceText = text;
      // while a search menu is open the query belongs to the menu's field,
      // NOT the chat input (no duplicate typing in both)
      else if (root.menuSearchOpen) {
        menuSearchField.text = text;
        menuSearchField.cursorPosition = text.length;
      } else inputField.text = text;
      root.inputSyncing = false;
      if (root.mode === "chat") {
        if (root.menuSearchOpen) root.menuSel = 0;
        else root.updateFinder();
      }
    }
    onCursorPositionChanged: if (!root.inputSyncing) {
      root.inputSyncing = true;
      if (root.mode === "translate") translateBox.setCursorPos(cursorPosition);
      else inputField.cursorPosition = cursorPosition;
      root.inputSyncing = false;
    }
    // the chat's TextEdits never hold the (compositor) keyboard — the bar
    // does. Forward copy from here to whichever message has a selection
    Keys.onPressed: event => {
      // Escape closes the open menu (or the panel). Handled here as well as
      // via onEscapePressed so it works whichever surface holds the keyboard.
      if (event.key === Qt.Key_Escape) {
        event.accepted = true;
        if (root.formCancelText()) return;
        root.closeMenuOrPanel();
        return;
      }
      if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier)
          && root.selEdit) {
        root.selEdit.copy();
        root.showCopyToast();
        event.accepted = true;
        return;
      }
      // Ctrl+V: attach a clipboard image when there is one, else paste text
      if (root.mode === "chat" && root.formTextTarget === null
          && event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)) {
        root.pasteFromClipboard(true);
        event.accepted = true;
        return;
      }
      // list menus (models/agents/sessions): arrows move the selection
      if (root.menuSearchable()
          && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier))) {
        if (event.key === Qt.Key_Down) { root.menuMove(1); event.accepted = true; return; }
        if (event.key === Qt.Key_Up) { root.menuMove(-1); event.accepted = true; return; }
      }
      // @-mention finder: arrows move the selection, Enter picks it
      if (root.menu === "files" && root.fileHits.length > 0) {
        if (event.key === Qt.Key_Down) { root.finderMove(1); event.accepted = true; return; }
        if (event.key === Qt.Key_Up) { root.finderMove(-1); event.accepted = true; return; }
      }
    }
    // Enter only sends in the CHAT tab — otherwise a leftover draft would
    // be submitted from the calculator (which has no text field of its own)
    Keys.onReturnPressed: {
      if (root.formCommitText()) return;
      if (root.menuPickSelected()) return;
      if (root.mode === "translate") translateBox.translate();
      else if (root.mode === "chat" && !root.finderPickSelected()) root.send();
    }
    Keys.onEnterPressed: {
      if (root.formCommitText()) return;
      if (root.menuPickSelected()) return;
      if (root.mode === "translate") translateBox.translate();
      else if (root.mode === "chat" && !root.finderPickSelected()) root.send();
    }
    Keys.onEscapePressed: {
      if (root.formCancelText()) return;
      root.closeMenuOrPanel();
    }
  }

  // (keyboard diagnostics removed — the overlay reaches the panel directly)

  // ---------- panel ----------
  //
  // Pomodoro-style dropdown: a separate full-screen Catcher window takes
  // click-outside duty (with its own release shield), and the panel itself
  // is a PopupWindow anchored below the pill. Keyboard: the BAR holds
  // exclusive keyboard while any panel is open (Bar.qml focusable) —
  // claiming keyboard on the panel window itself makes Hyprland treat it
  // as modal and drop every pointer press until the next motion event,
  // so it must stay keyboard-less.
  Catcher {
    active: root.panelOpen
    onClicked: root.panelOpen = false
  }

  PopupWindow {
    id: panel

    // stays mapped briefly while closing so the fade/slide can play
    visible: root.panelOpen || hideAnim.running
    color: "transparent"
    implicitWidth: panelContent.width
    implicitHeight: panelContent.height

    Timer { id: hideAnim; interval: 220 }

    // Open-side work lives in root.panelShown(), called from
    // root.onPanelOpenChanged. Doing it here would miss the rapid
    // close→reopen case: `visible` stays true (hideAnim is stopped), so this
    // signal never fires and the panel would come back with no stream.
    onVisibleChanged: {
      if (visible) return;
      // panel closed mid-recording: discard the take
      if (root.sttState !== "idle") {
        root.sttCancel = true;
        recProc.running = false;
      }
    }

    anchor {
      window: root.QsWindow.window
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
    }

    anchor.onAnchoring: {
      // pin the panel's TOP-LEFT corner at (pillRight - 660, pillBottom + 6):
      // for the 660-wide chat panel this right-aligns its right edge with
      // the pill's right edge (as before), and — because the anchor is the
      // top-left corner — tab resizes never move the origin; the panel
      // only shrinks/grows from its right and bottom edges
      const p = root.mapToItem(null, 0, 0);
      anchor.rect.x = p.x + 2 + root.width - 660;
      anchor.rect.y = p.y + root.height + 6;
      anchor.rect.width = 1;
      anchor.rect.height = 1;
    }

    Rectangle {
      id: panelContent
      x: 0
      y: 0
      // fixed panel size for all tabs — resizing the popup per tab proved
      // janky, so everything lives in the same dropdown
      width: 660
      height: 700
      color: Theme.bg
      radius: 6
      border.color: Theme.border
      border.width: 1
      // open/close: fade + drop-in (same motion as the player/pomodoro
      // dropdowns); the popup stays mapped for 220ms on close (hideAnim)
      opacity: root.panelOpen ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
      transform: Translate {
        y: root.panelOpen ? 0 : -8
        Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      }

      // chat is empty (and no menu open) → TUI-style centered prompt
      property bool empty: root.mode === "chat" && chatModel.count === 0
                           && root.menu === "" && root.pendingImages.length === 0
                           && !root.chatLoading

      // catch-all: Escape bubbling up from any focused child of the overlay
      Keys.onEscapePressed: root.closeMenuOrPanel()

      Column {
        anchors.fill: parent
        anchors.margins: 10
        anchors.bottomMargin: 0   // input row is a floating sibling below
        spacing: 8

        // ----- header -----
        Row {
          id: headerRow
          width: parent.width
          height: 26
          spacing: 8

          // central tabs: chat / translate / calculator
          Row {
            id: tabRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            Repeater {
              model: [
                { id: "chat", icon: "󰆍" },
                { id: "translate", icon: "\uf1ab" },
                { id: "calc", icon: "\uf1ec" }
              ]

              delegate: Rectangle {
                required property var modelData

                readonly property bool cur: root.mode === modelData.id
                width: 24; height: 20; radius: 5
                color: cur ? Theme.hover
                     : tabMa.containsMouse ? Theme.hover : "transparent"
                Behavior on color { ColorAnimation { duration: 200 } }
                scale: cur ? 1 : (tabMa.containsMouse ? 1.04 : 1)
                Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                Text {
                  anchors.centerIn: parent
                  text: parent.modelData.icon
                  font.family: Theme.font
                  font.pixelSize: 12
                  color: parent.cur ? Theme.accent : Theme.muted
                }

                MouseArea {
                  id: tabMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.mode = parent.modelData.id
                }
              }
            }
          }

          // session title — click for the session list. Width accounts for
          // every sibling (incl. the stop button, which appears mid-turn)
          // so the header never overflows the panel edge
          Text {
            id: titleText
            anchors.verticalCenter: parent.verticalCenter
            visible: root.mode === "chat"
            width: parent.width - tabRow.width
                   - costText.width
                   - modelBtn.width - agentBtn.width - newBtn.width - 40
                   - (stopBtn.visible ? stopBtn.width + 8 : 0)
            text: root.session ? (root.session.title || "opencode") : "opencode — new chat"
            font.family: Theme.font
            font.bold: true
            font.pixelSize: 12
            color: Theme.accent
            elide: Text.ElideRight

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.menu === "sessions" ? root.closeMenu() : root.openMenu("sessions")
            }
          }

          Text {
            id: costText
            anchors.verticalCenter: parent.verticalCenter
            visible: root.mode === "chat"
            text: root.session && root.session.cost > 0
                  ? "$" + root.session.cost.toFixed(2) : ""
            font.family: Theme.font
            font.pixelSize: 10
            color: Theme.muted
          }

          // model chip — click for the model list
          Rectangle {
            id: modelBtn
            anchors.verticalCenter: parent.verticalCenter
            visible: root.mode === "chat"
            width: modelText.implicitWidth + 14
            height: 22
            radius: 5
            color: modelMa.containsMouse ? Theme.hover : Theme.surface
            Behavior on color { ColorAnimation { duration: 200 } }
            Text {
              id: modelText
              anchors.centerIn: parent
              // a not-yet-created chat has no session.model — show the model
              // it will be created with instead of a bare placeholder
              text: root.session && root.session.model ? root.session.model.id
                    : root.lastModel ? root.lastModel.id : "model"
              font.family: Theme.font
              font.pixelSize: 10
              color: Theme.text
            }
            MouseArea {
              id: modelMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.menu === "models" ? root.closeMenu() : root.openMenu("models")
            }
          }

          // agent chip — click for the agent list
          Rectangle {
            id: agentBtn
            anchors.verticalCenter: parent.verticalCenter
            visible: root.mode === "chat"
            width: agentText.implicitWidth + 14
            height: 22
            radius: 5
            color: agentMa.containsMouse ? Theme.hover : Theme.surface
            Behavior on color { ColorAnimation { duration: 200 } }
            Text {
              id: agentText
              anchors.centerIn: parent
              text: root.session && root.session.agent ? root.session.agent
                    : root.lastAgent !== "" ? root.lastAgent : "agent"
              font.family: Theme.font
              font.pixelSize: 10
              color: Theme.text
            }
            MouseArea {
              id: agentMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.menu === "agents" ? root.closeMenu() : root.openMenu("agents")
            }
          }

          Rectangle {
            id: newBtn
            anchors.verticalCenter: parent.verticalCenter
            visible: root.mode === "chat"
            width: 22; height: 22; radius: 5
            color: newChatMa.containsMouse ? Theme.hover : Theme.surface
            Behavior on color { ColorAnimation { duration: 200 } }
            scale: newChatMa.containsMouse ? 1.07 : 1
            Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            Text {
              anchors.centerIn: parent
              text: "\uf067"          // plus — the old oct glyph overflowed the 22px chip
              font.family: Theme.font
              font.pixelSize: 11
              color: Theme.text
            }
            MouseArea {
              id: newChatMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.newChat()
            }
          }

          Rectangle {
            id: stopBtn
            anchors.verticalCenter: parent.verticalCenter
            width: 22; height: 22; radius: 5
            visible: (root.busy || root.sending) && root.mode === "chat"
            color: stopMa.containsMouse ? Theme.hover : Theme.surface
            Behavior on color { ColorAnimation { duration: 200 } }
            Text {
              anchors.centerIn: parent
              text: "\uf04d"
              font.family: Theme.font
              font.pixelSize: 11
              color: Theme.err
            }
            MouseArea {
              id: stopMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.interrupt()
            }
          }
        }

        // ----- error line -----
        Text {
          id: errorLine
          transform: Translate { x: root.swipeOfs }
          width: parent.width
          height: root.error !== "" && root.mode === "chat" ? implicitHeight : 0
          visible: height > 0
          clip: true
          Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
          text: root.error
          font.family: Theme.font
          font.pixelSize: 10
          color: Theme.err
          elide: Text.ElideRight
        }

        // ----- chat history (anchored to the bottom like a real chat) -----
        Flickable {
          id: chatView
          transform: Translate { x: root.swipeOfs }
          width: parent.width
          height: root.mode === "chat"
              ? parent.height - headerRow.height - menuBox.height
                - errorLine.height - permBanner.height - formBanner.height
                - inputRow.height - 8 * 5 - 10
              : 0
          clip: true
          contentWidth: width
          contentHeight: chatCol.implicitHeight + (height > chatCol.implicitHeight
            ? chatCol.y : 0)
          // hidden while history loads, so the chunked rebuild is not seen as
          // content assembling itself; it fades in once complete
          opacity: root.chatLoading ? 0 : 1
          Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

          // chat flow: messages hug the bottom; history scrolls up.
          // `rebuilding` guards pinned: during a model rebuild contentY is
          // clamped (contentHeight collapses), which must NOT flip pinned
          property bool pinned: true

          onContentYChanged: if (!root.rebuilding) pinned = contentY >= contentHeight - height - 24
          onContentHeightChanged: if (pinned) Qt.callLater(stick)

          function stick() {
            if (!pinned) return;
            contentY = Math.max(0, contentHeight - height);
          }

          Column {
            id: chatCol
            width: chatView.width
            y: Math.max(0, chatView.height - implicitHeight)
            spacing: 8

            Repeater {
              model: chatModel

              delegate: Item {
                id: msgDel
                required property string key
                required property string kind
                required property string text
                required property string name
                required property string state
                // toolIn carries the raw input object (pretty-printed lazily)
                required property var toolIn
                required property string toolOut
                // diff was used but never declared, so the tool diff/input never
                // actually rendered — declare the role to bind it
                required property string diff
                required property bool live
                readonly property bool open: root.expanded[key] === true
                width: chatView.width
                height: msgRect.implicitHeight + 4

                Rectangle {
                  id: msgRect
                  anchors.right: msgDel.kind === "user" ? parent.right : undefined
                  anchors.left: msgDel.kind === "user" ? undefined : parent.left
                  anchors.leftMargin: msgDel.kind === "tool" || msgDel.kind === "reasoning" ? 14 : 0
                  width: {
                    if (msgDel.kind === "assistant") return parent.width - 16;
                    if (msgDel.kind === "user")
                      return Math.min(parent.width - 20, userMeasure.implicitWidth + 20);
                    return parent.width - 30;
                  }
                  implicitHeight: {
                    if (msgDel.kind === "user") return userText.contentHeight + 14;
                    if (msgDel.kind === "assistant") return asstText.contentHeight + 8;
                    if (msgDel.open)
                      return foldHead.implicitHeight + 6 + foldCol.implicitHeight + 14;
                    return foldHead.implicitHeight + 8;
                  }
                  radius: 8
                  color: msgDel.kind === "user" ? Theme.surface : "transparent"
                  border.width: msgDel.kind === "user" ? 1 : 0
                  border.color: Theme.border

                  // invisible measure: TextEdit has no content-hugging width,
                  // this sizes the user bubble
                  Text {
                    id: userMeasure
                    visible: false
                    width: Math.min(chatView.width - 60, implicitWidth)
                    text: msgDel.text
                    textFormat: Text.PlainText
                    font.family: Theme.font
                    font.pixelSize: 12
                  }

                  SelText {
                    id: userText
                    visible: msgDel.kind === "user"
                    anchors.centerIn: parent
                    width: userMeasure.width
                    height: contentHeight
                    text: msgDel.text
                    textFormat: TextEdit.PlainText
                    font.pixelSize: 12
                    onSelectedTextChanged: if (selectedText !== "") root.selEdit = userText
                    onCopied: root.showCopyToast()
                  }

                  SelText {
                    id: asstText
                    visible: msgDel.kind === "assistant"
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: contentHeight
                    // rendered to a controlled RichText subset (spacing,
                    // code blocks, tables) — see renderMarkdown
                    textFormat: TextEdit.RichText
                    text: root.renderMarkdown(msgDel.text, !msgDel.live)
                    font.pixelSize: 12
                    color: Theme.accent
                    onSelectedTextChanged: if (selectedText !== "") root.selEdit = asstText
                    onCopied: root.showCopyToast()
                  }

                  // foldout header (tool / reasoning)
                  Text {
                    id: foldHead
                    visible: msgDel.kind === "tool" || msgDel.kind === "reasoning"
                    anchors.top: parent.top
                    anchors.topMargin: 4
                    text: (msgDel.open ? "▾ " : "▸ ")
                        + (msgDel.kind === "tool" ? "⚒ " + msgDel.name
                             + (msgDel.state !== "" ? " · " + msgDel.state : "")
                           : "✦ reasoning")
                    font.family: Theme.font
                    font.pixelSize: 10
                    color: msgDel.kind === "reasoning" ? Theme.muted
                         : (msgDel.state.indexOf("error") !== -1 ? Theme.err : Theme.muted)
                    opacity: 0.9

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.toggleFold(msgDel.key)
                    }
                  }

                  // foldout body
                  Column {
                    id: foldCol
                    visible: (msgDel.kind === "tool" || msgDel.kind === "reasoning")
                             && msgDel.open
                    anchors.top: foldHead.bottom
                    anchors.topMargin: 6
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.right: parent.right
                    spacing: 4

                    SelText {
                      id: toolInEdit
                      // with a diff shown, the raw JSON input only duplicates
                      // it and clutters the foldout
                      visible: !!msgDel.toolIn && msgDel.diff === ""
                      width: parent.width
                      height: contentHeight
                      // materialize (and pretty-print) only while it is open
                      text: msgDel.open ? root.toolInputText(msgDel.toolIn) : ""
                      textFormat: TextEdit.PlainText
                      font.pixelSize: 9
                      color: Theme.idleText
                      onSelectedTextChanged: if (selectedText !== "") root.selEdit = toolInEdit
                      onCopied: root.showCopyToast()
                    }

                    // reasoning text lives in `text` (tools use toolOut)
                    SelText {
                      id: reasoningEdit
                      visible: msgDel.kind === "reasoning" && msgDel.text !== ""
                      width: parent.width
                      height: contentHeight
                      text: msgDel.open ? msgDel.text : ""
                      textFormat: TextEdit.PlainText
                      font.pixelSize: 9
                      color: Theme.muted
                      onSelectedTextChanged: if (selectedText !== "") root.selEdit = reasoningEdit
                      onCopied: root.showCopyToast()
                    }

                    // colored unified diff (edit/patch tools)
                    SelText {
                      id: diffEdit
                      visible: msgDel.diff !== ""
                      width: parent.width
                      height: contentHeight
                      // renderDiff is not free — skip it while collapsed
                      text: msgDel.open ? renderDiff(msgDel.diff) : ""
                      textFormat: TextEdit.RichText
                      font.pixelSize: 9
                      color: Theme.text
                      onSelectedTextChanged: if (selectedText !== "") root.selEdit = diffEdit
                      onCopied: root.showCopyToast()
                    }

                    SelText {
                      id: toolOutEdit
                      visible: msgDel.toolOut !== ""
                      width: parent.width
                      height: contentHeight
                      text: !msgDel.open || msgDel.toolOut === "" ? ""
                          : msgDel.toolOut.length > 4000
                            ? msgDel.toolOut.slice(0, 4000) + " …"
                            : msgDel.toolOut
                      textFormat: TextEdit.PlainText
                      font.pixelSize: 9
                      color: msgDel.kind === "reasoning" ? Theme.muted : Theme.text
                      onSelectedTextChanged: if (selectedText !== "") root.selEdit = toolOutEdit
                      onCopied: root.showCopyToast()
                    }
                  }
                }
              }
            }

            // thinking indicator while the assistant turn streams
            Text {
              visible: root.busy
              text: "◌ thinking…"
              font.family: Theme.font
              font.pixelSize: 11
              color: Theme.muted
              SequentialAnimation on opacity {
                running: root.busy
                loops: Animation.Infinite
                NumberAnimation { to: 0.35; duration: 600 }
                NumberAnimation { to: 1; duration: 600 }
              }
            }
          }
        }

        // ----- menus (sessions / models / agents / commands / files) -----
        Rectangle {
          id: menuBox
          transform: Translate { x: root.swipeOfs }
          width: parent.width
          height: root.menu !== "" && root.mode === "chat"
              ? Math.min(200, menuCol.implicitHeight + 12) : 0
          visible: height > 0
          radius: 6
          color: Theme.surface
          border.color: Theme.border
          border.width: 1
          clip: true
          Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

          Flickable {
            id: menuFlick
            anchors.fill: parent
            contentWidth: width
            contentHeight: menuCol.implicitHeight + 12
            interactive: contentHeight > height
            clip: true

            Connections {
              target: root
              function onMenuChanged() { menuFlick.contentY = 0; root.menuSel = 0; }
            }

            // keep the keyboard-selected list row in view
            Connections {
              target: root
              function onMenuSelChanged() { root.ensureMenuSelVisible(); }
            }

            // keep the keyboard-selected finder hit in view
            Connections {
              target: root
              function onFileSelChanged() {
                if (root.menu !== "files") return;
                const rowH = 26;
                const top = root.fileSel * rowH;
                const bottom = top + rowH;
                if (top < menuFlick.contentY) menuFlick.contentY = top;
                else if (bottom > menuFlick.contentY + menuFlick.height)
                  menuFlick.contentY = bottom - menuFlick.height;
              }
            }

            Column {
              id: menuCol
              x: 6
              y: 6
              width: menuFlick.width - 12
              spacing: 2

            // search row for the list menus. This mirrors the single real
            // editor (the bar's hiddenInput) BOTH ways: if the popup happens
            // to hold the keyboard this field is typed into directly,
            // otherwise the bar's editor is and the text lands here. (A
            // read-only field would swallow the keys when the popup has
            // focus, which is what made search look dead.)
            Rectangle {
              visible: root.menu === "models" || root.menu === "agents"
                    || root.menu === "sessions"
              width: menuCol.width - 4
              height: 24
              radius: 4
              color: Theme.bg
              border.color: Theme.border
              border.width: 1
              Text {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: "\uf002"
                font.family: Theme.font
                font.pixelSize: 10
                color: Theme.muted
              }
              // a bare TextInput, not a TextField: the Control's inner
              // contentItem was consuming Escape before the Keys handlers
              TextInput {
                id: menuSearchField
                anchors.left: parent.left
                anchors.leftMargin: 20
                anchors.right: parent.right
                anchors.rightMargin: 26
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                color: Theme.accent
                font.family: Theme.font
                font.pixelSize: 10
                selectionColor: Theme.hover
                selectedTextColor: Theme.accent
                // grab QML focus while a list menu is open, so a popup that
                // holds the keyboard types straight into this field
                focus: root.menuSearchOpen && root.panelOpen
                cursorVisible: root.menuSearchOpen
                cursorDelegate: Item {
                  implicitWidth: 2
                  Rectangle {
                    anchors.fill: parent
                    radius: 1
                    color: Theme.accent
                    SequentialAnimation on opacity {
                      running: root.menu === "models" || root.menu === "agents"
                            || root.menu === "sessions"
                      loops: Animation.Infinite
                      NumberAnimation { to: 1; duration: 600 }
                      NumberAnimation { to: 0; duration: 600 }
                    }
                  }
                }
                // typed here: keep the bar's editor in sync (single source),
                // but not the chat input — the draft stays parked there
                onTextEdited: {
                  root.inputSyncing = true;
                  if (hiddenInput.text !== text) {
                    hiddenInput.text = text;
                    hiddenInput.cursorPosition = text.length;
                  }
                  root.inputSyncing = false;
                  root.menuSel = 0;
                }
                // one handler with BeforeItem priority so Escape/Enter are
                // caught before any default editing behaviour
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: event => {
                  if (event.key === Qt.Key_Escape) {
                    event.accepted = true;
                    root.closeMenu();
                  } else if (event.key === Qt.Key_Backspace && text === "") {
                    // backspace on an empty query closes (Escape-lite)
                    event.accepted = true;
                    root.closeMenu();
                  } else if (event.key === Qt.Key_Down) {
                    event.accepted = true;
                    root.menuMove(1);
                  } else if (event.key === Qt.Key_Up) {
                    event.accepted = true;
                    root.menuMove(-1);
                  } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    event.accepted = true;
                    root.menuPickSelected();
                  }
                }
              }
              Text {
                anchors.left: parent.left
                anchors.leftMargin: 20
                anchors.right: menuSearchClose.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                visible: menuSearchField.text === ""
                text: root.menu === "models" ? "search models…  (↑↓ · Enter)"
                    : root.menu === "agents" ? "search agents…  (↑↓ · Enter)"
                    : "search chats…  (↑↓ · Enter)"
                color: Theme.idleText
                font.family: Theme.font
                font.pixelSize: 10
                elide: Text.ElideRight
              }

              // close affordance. Escape is not delivered to this popup
              // surface (the compositor keeps it for the popup grab), so a
              // click target is the reliable way out.
              Rectangle {
                id: menuSearchClose
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                width: 18; height: 18; radius: 4
                color: menuSearchCloseMa.containsMouse ? Theme.hover : "transparent"
                Behavior on color { ColorAnimation { duration: 150 } }
                Text {
                  anchors.centerIn: parent
                  text: "\uf00d"
                  font.family: Theme.font
                  font.pixelSize: 10
                  color: menuSearchCloseMa.containsMouse ? Theme.err : Theme.muted
                }
                MouseArea {
                  id: menuSearchCloseMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.closeMenu()
                }
              }
            }

            // file finder results
            Repeater {
              model: root.menu === "files" ? root.fileHits : []

              Rectangle {
                id: fileRow
                required property var modelData
                required property int index
                readonly property bool sel: index === root.fileSel
                width: menuCol.width - 4
                height: 24
                radius: 4
                color: sel ? Theme.hover
                     : fileMa.containsMouse ? Theme.hover : "transparent"
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.right: parent.right
                  anchors.rightMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  text: (fileRow.modelData.type === "directory"
                         ? "\uf07b  " : "\uf15b  ") + fileRow.modelData.path
                  font.family: Theme.font
                  font.pixelSize: 10
                  color: fileRow.sel ? Theme.accent : Theme.text
                  elide: Text.ElideMiddle
                }
                MouseArea {
                  id: fileMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.fileSel = fileRow.index
                  onClicked: root.pickFile(fileRow.modelData)
                }
              }
            }

            // sessions menu (searchable: the input filters by title/agent).
            // Filtering is inlined so the binding reads inputField.text /
            // sessionList directly and re-evaluates on every keystroke.
            Repeater {
              id: sessionsRep
              model: {
                if (root.menu !== "sessions") return [];
                const q = menuSearchField.text.trim().toLowerCase();
                if (q === "") return root.sessionList;
                return root.sessionList.filter(s =>
                  root.sessionLabel(s).toLowerCase().indexOf(q) !== -1
                  || (s.agent || "").toLowerCase().indexOf(q) !== -1);
              }

              Rectangle {
                id: sesRow
                required property var modelData
                required property int index
                readonly property bool cur: root.session && root.session.id === modelData.id
                readonly property bool running: root.activeSessions[modelData.id] !== undefined
                width: menuCol.width - 4
                height: 24
                radius: 4
                // a handler (not a MouseArea) so hovering the ✕ child does
                // not report the row as un-hovered and hide the button
                HoverHandler { id: sesHover }
                color: (index === root.menuSel || sesHover.hovered)
                       ? Theme.hover : "transparent"
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - 118
                  // running agents get a live dot, the open one a filled dot;
                  // untitled sessions show a friendly label, never the ses_ id
                  text: (parent.cur ? "● " : parent.running ? "◌ " : "")
                        + root.sessionLabel(parent.modelData)
                  font.family: Theme.font
                  font.pixelSize: 10
                  font.bold: parent.cur
                  color: parent.cur ? Theme.accent
                       : parent.running ? Theme.live : Theme.text
                  elide: Text.ElideRight
                }
                Text {
                  anchors.right: sesDel.left
                  anchors.rightMargin: 6
                  anchors.verticalCenter: parent.verticalCenter
                  text: parent.running ? "running" : (parent.modelData.agent || "")
                  font.family: Theme.font
                  font.pixelSize: 9
                  color: parent.running ? Theme.live : Theme.muted
                }
                MouseArea {
                  id: sesMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.menuSel = index
                  onClicked: root.switchSession(parent.modelData)
                }
                // delete (hover only) — clears empty/abandoned chats, which
                // otherwise pile up in the picker as untitled rows
                Rectangle {
                  id: sesDel
                  anchors.right: parent.right
                  anchors.rightMargin: 4
                  anchors.verticalCenter: parent.verticalCenter
                  width: 18; height: 18; radius: 4
                  visible: sesHover.hovered
                  color: sesDelMa.containsMouse ? Theme.hover : "transparent"
                  Behavior on color { ColorAnimation { duration: 150 } }
                  Text {
                    anchors.centerIn: parent
                    text: "\uf00d"
                    font.family: Theme.font
                    font.pixelSize: 10
                    color: sesDelMa.containsMouse ? Theme.err : Theme.muted
                  }
                  MouseArea {
                    id: sesDelMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.deleteSession(sesRow.modelData)
                  }
                }
              }
            }

            // models menu (searchable: name / provider / id)
            Repeater {
              id: modelsRep
              model: {
                if (root.menu !== "models") return [];
                const q = menuSearchField.text.trim().toLowerCase();
                if (q === "") return root.models;
                return root.models.filter(m =>
                  (m.name || "").toLowerCase().indexOf(q) !== -1
                  || (m.providerID || "").toLowerCase().indexOf(q) !== -1
                  || (m.id || "").toLowerCase().indexOf(q) !== -1);
              }

              Rectangle {
                required property var modelData
                required property int index
                readonly property bool cur: root.session && root.session.model
                    && root.session.model.id === modelData.id
                width: menuCol.width - 4
                height: 24
                radius: 4
                color: (index === root.menuSel || modMa.containsMouse)
                       ? Theme.hover : "transparent"
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.right: provText.left
                  anchors.rightMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  text: (parent.cur ? "● " : "") + parent.modelData.name
                  font.family: Theme.font
                  font.pixelSize: 10
                  font.bold: parent.cur
                  color: parent.cur ? Theme.accent : Theme.text
                  elide: Text.ElideRight
                }
                // provider on the right, dim, so the list scans by model name
                Text {
                  id: provText
                  anchors.right: parent.right
                  anchors.rightMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  text: parent.modelData.providerID
                  font.family: Theme.font
                  font.pixelSize: 9
                  color: Theme.muted
                }
                MouseArea {
                  id: modMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.menuSel = index
                  onClicked: root.switchModel(parent.modelData)
                }
              }
            }

            // agents menu (searchable)
            Repeater {
              id: agentsRep
              model: {
                if (root.menu !== "agents") return [];
                const q = menuSearchField.text.trim().toLowerCase();
                if (q === "") return root.agents;
                return root.agents.filter(a =>
                  (a.name || "").toLowerCase().indexOf(q) !== -1
                  || (a.id || "").toLowerCase().indexOf(q) !== -1);
              }

              Rectangle {
                required property var modelData
                required property int index
                readonly property bool cur: root.session && root.session.agent === modelData.id
                width: menuCol.width - 4
                height: 24
                radius: 4
                color: (index === root.menuSel || agMa.containsMouse)
                       ? Theme.hover : "transparent"
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.right: parent.right
                  anchors.rightMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  text: (parent.cur ? "● " : "") + parent.modelData.name
                  font.family: Theme.font
                  font.pixelSize: 10
                  font.bold: parent.cur
                  color: parent.cur ? Theme.accent : Theme.text
                  elide: Text.ElideRight
                }
                MouseArea {
                  id: agMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.menuSel = index
                  onClicked: root.switchAgent(parent.modelData)
                }
              }
            }

            // commands menu (for "/")
            Repeater {
              model: {
                if (root.menu !== "commands") return [];
                const q = inputField.text.slice(1).toLowerCase();
                return root.commands.filter(c =>
                  q === "" || c.name.toLowerCase().indexOf(q) !== -1);
              }

              Rectangle {
                required property var modelData
                width: menuCol.width - 4
                height: 24
                radius: 4
                color: cmdMa.containsMouse ? Theme.hover : "transparent"
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - 16
                  text: "/" + parent.modelData.name
                      + (parent.modelData.description !== ""
                         ? "  —  " + parent.modelData.description : "")
                  font.family: Theme.font
                  font.pixelSize: 10
                  color: Theme.text
                  elide: Text.ElideRight
                }
                MouseArea {
                  id: cmdMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    inputField.text = "/" + parent.modelData.name + " ";
                    inputField.cursorPosition = inputField.text.length;
                    root.menu = "";
                    root.focusPanelField();
                  }
                }
              }
            }

            // empty-filter hint for the searchable menus
            Text {
              visible: (root.menu === "models" || root.menu === "agents"
                     || root.menu === "sessions")
                     && menuSearchField.text.trim() !== ""
                     && (root.menu === "models" ? modelsRep.count
                         : root.menu === "agents" ? agentsRep.count
                         : sessionsRep.count) === 0
              width: menuCol.width - 4
              height: 24
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              text: "nenhum resultado"
              font.family: Theme.font
              font.pixelSize: 10
              color: Theme.muted
            }
            }
          }
        }

        // ----- permission banner -----
        Rectangle {
          id: permBanner
          transform: Translate { x: root.swipeOfs }
          width: parent.width
          height: root.pendingPerm && root.mode === "chat" ? 46 : 0
          visible: height > 0
          clip: true
          Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
          radius: 6
          color: Theme.surface
          border.color: Theme.border
          border.width: 1

          Text {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 220
            text: root.pendingPerm
                ? "permission: " + root.pendingPerm.action
                  + " — " + (root.pendingPerm.resources || []).join(", ")
                : ""
            font.family: Theme.font
            font.pixelSize: 10
            color: Theme.text
            elide: Text.ElideRight
          }

          Row {
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            Repeater {
              model: root.pendingPerm
                  ? [{ l: "once", v: "once" }, { l: "always", v: "always" }, { l: "✕", v: "reject" }]
                  : []

              Rectangle {
                required property var modelData
                width: permLabel.implicitWidth + 14
                height: 24
                radius: 5
                color: permMa.containsMouse ? Theme.hover : Theme.bg
                Behavior on color { ColorAnimation { duration: 200 } }
                Text {
                  id: permLabel
                  anchors.centerIn: parent
                  text: parent.modelData.l
                  font.family: Theme.font
                  font.pixelSize: 10
                  font.bold: parent.modelData.v !== "reject"
                  color: parent.modelData.v === "reject" ? Theme.err : Theme.accent
                }
                MouseArea {
                  id: permMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.permReply(parent.modelData.v)
                }
              }
            }
          }
        }

        // ----- select questions (forms) -----
        Rectangle {
          id: formBanner
          transform: Translate { x: root.swipeOfs }
          width: parent.width
          height: root.pendingForms.length > 0 && root.mode === "chat"
              ? Math.min(320, formCol.implicitHeight + 16) : 0
          visible: height > 0
          clip: true
          Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
          radius: 6
          color: Theme.surface
          border.color: Theme.border
          border.width: 1

          Flickable {
            id: formFlick
            anchors.fill: parent
            contentWidth: width
            contentHeight: formCol.implicitHeight + 16
            interactive: contentHeight > height
            clip: true

            Column {
              id: formCol
              x: 8
              y: 8
              width: formFlick.width - 16
              spacing: 10

              Repeater {
                model: root.pendingForms

                Column {
                  id: formBox
                  required property var modelData
                  width: formCol.width
                  spacing: 6

                  Row {
                    width: parent.width
                    spacing: 6

                    Text {
                      width: parent.width - closeForm.width - 6
                      text: formBox.modelData.title || "question"
                      font.family: Theme.font
                      font.bold: true
                      font.pixelSize: 11
                      color: Theme.accent
                      elide: Text.ElideRight
                    }

                    Rectangle {
                      id: closeForm
                      width: 22; height: 20; radius: 4
                      color: closeFormMa.containsMouse ? Theme.hover : Theme.bg
                      Behavior on color { ColorAnimation { duration: 150 } }
                      Text {
                        anchors.centerIn: parent
                        text: "✕"
                        font.family: Theme.font
                        font.pixelSize: 10
                        color: Theme.err
                      }
                      MouseArea {
                        id: closeFormMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.formCancel(formBox.modelData)
                      }
                    }
                  }

                  Repeater {
                    model: formBox.modelData.fields

                    Column {
                      id: fieldBox
                      required property var modelData
                      width: formBox.width
                      spacing: 5
                      // conditional fields (Form.When) hide until their
                      // dependencies are answered; Column skips invisible kids
                      visible: root.formFieldVisible(formBox.modelData, fieldBox.modelData)

                      Text {
                        width: parent.width
                        text: (fieldBox.modelData.title || fieldBox.modelData.key)
                              + (fieldBox.modelData.required ? "  *" : "")
                        font.family: Theme.font
                        font.pixelSize: 10
                        color: Theme.text
                        wrapMode: Text.WordWrap
                      }

                      Text {
                        width: parent.width
                        visible: text !== ""
                        text: fieldBox.modelData.description || ""
                        font.family: Theme.font
                        font.pixelSize: 9
                        color: Theme.muted
                        wrapMode: Text.WordWrap
                      }

                      // boolean yes/no
                      Row {
                        visible: fieldBox.modelData.type === "boolean"
                        spacing: 5
                        Repeater {
                          model: [{ l: "yes", v: true }, { l: "no", v: false }]
                          Rectangle {
                            required property var modelData
                            readonly property bool on: root.formAnswer(formBox.modelData.id,
                                                                        fieldBox.modelData.key) === modelData.v
                            width: boolLabel.implicitWidth + 16
                            height: 22; radius: 4
                            color: on ? Theme.accent
                                 : boolMa.containsMouse ? Theme.hover : Theme.bg
                            Behavior on color { ColorAnimation { duration: 150 } }
                            Text {
                              id: boolLabel
                              anchors.centerIn: parent
                              text: modelData.l
                              font.family: Theme.font
                              font.pixelSize: 10
                              color: on ? Theme.deep : Theme.text
                            }
                            MouseArea {
                              id: boolMa
                              anchors.fill: parent
                              hoverEnabled: true
                              cursorShape: Qt.PointingHandCursor
                              onClicked: root.formSetAnswer(formBox.modelData.id,
                                                            fieldBox.modelData.key, modelData.v)
                            }
                          }
                        }
                      }

                      // options: single or multi select
                      Flow {
                        visible: (fieldBox.modelData.options || []).length > 0
                        width: parent.width
                        spacing: 5
                        Repeater {
                          model: fieldBox.modelData.options || []
                          Rectangle {
                            required property var modelData
                            readonly property bool on: root.formOptionSelected(formBox.modelData,
                                                                               fieldBox.modelData, modelData)
                            width: optLabel.implicitWidth + 16
                            height: 22; radius: 4
                            color: on ? Theme.accent
                                 : optMa.containsMouse ? Theme.hover : Theme.bg
                            Behavior on color { ColorAnimation { duration: 150 } }
                            Text {
                              id: optLabel
                              anchors.centerIn: parent
                              text: modelData.label
                              font.family: Theme.font
                              font.pixelSize: 10
                              color: on ? Theme.deep : Theme.text
                            }
                            MouseArea {
                              id: optMa
                              anchors.fill: parent
                              hoverEnabled: true
                              cursorShape: Qt.PointingHandCursor
                              onClicked: root.formToggleOption(formBox.modelData,
                                                               fieldBox.modelData, modelData)
                            }
                          }
                        }
                      }

                      // free text / custom answer, typed in the main editor
                      Rectangle {
                        id: typeBtn
                        visible: ((fieldBox.modelData.type === "string"
                                   || fieldBox.modelData.type === "number"
                                   || fieldBox.modelData.type === "integer")
                                  && (fieldBox.modelData.options || []).length === 0)
                                 || fieldBox.modelData.custom === true
                        readonly property bool active: root.formTextTarget !== null
                            && root.formTextTarget.formID === formBox.modelData.id
                            && root.formTextTarget.key === fieldBox.modelData.key
                        width: Math.min(formBox.width, typeLabel.implicitWidth + 16)
                        height: 22; radius: 4
                        color: active ? Theme.accent
                             : typeMa.containsMouse ? Theme.hover : Theme.bg
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Text {
                          id: typeLabel
                          width: parent.width - 16
                          anchors.centerIn: parent
                          text: {
                            if (typeBtn.active) return "typing… (Enter to set)";
                            const v = root.formAnswer(formBox.modelData.id, fieldBox.modelData.key);
                            return (typeof v === "string" && v !== "")
                                   ? ("✎ " + v) : "✎ type answer…";
                          }
                          font.family: Theme.font
                          font.pixelSize: 10
                          color: typeBtn.active ? Theme.deep : Theme.text
                          elide: Text.ElideRight
                        }
                        MouseArea {
                          id: typeMa
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.formBeginText(formBox.modelData, fieldBox.modelData)
                        }
                      }

                      // external: a link out (auth page, docs, …). There is
                      // nothing to answer here — open it in the browser.
                      Rectangle {
                        id: extBtn
                        visible: fieldBox.modelData.type === "external"
                        readonly property string url: fieldBox.modelData.url || ""
                        width: Math.min(formBox.width, extLabel.implicitWidth + 16)
                        height: 22; radius: 4
                        color: extMa.containsMouse ? Theme.hover : Theme.bg
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Text {
                          id: extLabel
                          width: parent.width - 16
                          anchors.centerIn: parent
                          text: "↗ " + (fieldBox.modelData.title || "abrir link")
                          font.family: Theme.font
                          font.pixelSize: 10
                          color: Theme.text
                          elide: Text.ElideRight
                        }
                        MouseArea {
                          id: extMa
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            if (extBtn.url !== "")
                              Quickshell.execDetached(["xdg-open", extBtn.url]);
                          }
                        }
                      }
                    }
                  }

                  Rectangle {
                    width: submitFormLabel.implicitWidth + 20
                    height: 24; radius: 4
                    color: submitFormMa.containsMouse ? Theme.hover : Theme.accent
                    Behavior on color { ColorAnimation { duration: 150 } }
                    Text {
                      id: submitFormLabel
                      anchors.centerIn: parent
                      text: "answer"
                      font.family: Theme.font
                      font.bold: true
                      font.pixelSize: 10
                      color: Theme.deep
                    }
                    MouseArea {
                      id: submitFormMa
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.formSubmit(formBox.modelData)
                    }
                  }
                }
              }
            }
          }
        }

      }
      // ----- input row -----
      // floats: glides up to the middle of the panel when the chat is
      // empty (TUI-style centered prompt), docks to the bottom otherwise
      Rectangle {
        id: inputRow
        transform: Translate { x: root.swipeOfs }
        x: 10
        width: parent.width - 20
        visible: root.mode === "chat"
        y: panelContent.empty ? 44 + (parent.height - 120) / 2
                              : parent.height - 48   // 10px bottom margin
        height: 38
        Behavior on y { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
        radius: 6
        color: Theme.surface
        border.color: inputField.activeFocus || hiddenInput.activeFocus
                     ? Theme.muted : Theme.border
        border.width: 1

        TextField {
          id: inputField
          anchors.left: parent.left
          anchors.leftMargin: 10
          anchors.right: pasteBtn.left
          anchors.rightMargin: 4
          anchors.verticalCenter: parent.verticalCenter
          background: null
          placeholderText: root.formTextTarget !== null
              ? "answer: " + root.formTextTarget.title + " …"
              : root.sttState === "rec"
              ? "● recording " + Math.floor(root.recSecs / 60) + ":"
                + String(root.recSecs % 60).padStart(2, "0")
                + " — mic again to stop"
              : root.sttState === "stt" ? "◌ transcribing…"
              : root.busy ? "opencode is working…"
              : "ask opencode…  (@file · /command · Ctrl+V image)"
          placeholderTextColor: Theme.idleText
          color: Theme.accent
          font.family: Theme.font
          font.pixelSize: 12
          selectionColor: Theme.hover
          selectedTextColor: Theme.accent
          // disabled while a search menu owns the keyboard (it shows the
          // parked draft, dimmed)
          enabled: !root.busy && !root.sending && !root.menuSearchOpen
          wrapMode: TextInput.Wrap
          // the popup window is keyboard-less — the bar's hiddenInput is
          // the real editor, so this field never gets real active focus
          // (and with it, no caret). Mirror the cursor position and fake
          // the blinking caret here while the panel is open.
          cursorVisible: root.panelOpen && root.mode === "chat"
                         && !root.busy && !root.sending
          cursorDelegate: Item {
            implicitWidth: 2
            Rectangle {
              anchors.fill: parent
              radius: 1
              color: Theme.accent
              SequentialAnimation on opacity {
                running: root.panelOpen && root.mode === "chat"
                       && !root.busy && !root.sending
                loops: Animation.Infinite
                NumberAnimation { to: 1; duration: 600 }
                NumberAnimation { to: 0; duration: 600 }
              }
            }
          }
          onTextEdited: root.updateFinder()
          onTextChanged: if (!root.inputSyncing) {
            root.inputSyncing = true;
            hiddenInput.text = text;
            root.inputSyncing = false;
          }
          onCursorPositionChanged: if (!root.inputSyncing) {
            root.inputSyncing = true;
            hiddenInput.cursorPosition = cursorPosition;
            root.inputSyncing = false;
          }
          // only ever submit from the chat tab (same guard as hiddenInput)
          Keys.onReturnPressed: if (!root.formCommitText()
                                    && !root.menuPickSelected()
                                    && root.mode === "chat"
                                    && !root.finderPickSelected()) root.send()
          Keys.onEnterPressed: if (!root.formCommitText()
                                   && !root.menuPickSelected()
                                   && root.mode === "chat"
                                   && !root.finderPickSelected()) root.send()
          Keys.onUpPressed: root.menuSearchable() ? root.menuMove(-1) : root.finderMove(-1)
          Keys.onDownPressed: root.menuSearchable() ? root.menuMove(1) : root.finderMove(1)
          Keys.onEscapePressed: event => {
            event.accepted = true;   // don't let the panel Shortcut also fire
            if (root.formCancelText()) return;
            root.closeMenuOrPanel();
          }
        }

        // attach clipboard image
        Rectangle {
          id: pasteBtn
          anchors.right: micBtn.left
          anchors.rightMargin: 4
          anchors.verticalCenter: parent.verticalCenter
          width: 28; height: 26; radius: 5
          color: pasteMa.containsMouse ? Theme.hover : Theme.bg
          Behavior on color { ColorAnimation { duration: 200 } }
          scale: pasteMa.containsMouse ? 1.07 : 1
          Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

          Text {
            anchors.centerIn: parent
            text: "\uf03e"
            font.family: Theme.font
            font.pixelSize: 11
            color: Theme.text
          }

          MouseArea {
            id: pasteMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.pasteFromClipboard(false)
          }
        }

        Rectangle {
          id: micBtn
          anchors.right: sendBtn.left
          anchors.rightMargin: 4
          anchors.verticalCenter: parent.verticalCenter
          width: 28; height: 26; radius: 5
          color: micMa.containsMouse && root.sttState === "idle"
                 ? Theme.hover : Theme.bg
          Behavior on color { ColorAnimation { duration: 200 } }
          scale: micMa.containsMouse ? 1.07 : 1
          Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

          Text {
            anchors.centerIn: parent
            text: root.sttState === "rec" ? "\uf111"
                : root.sttState === "stt" ? "◌" : "\uf130"
            font.family: Theme.font
            font.pixelSize: root.sttState === "stt" ? 12 : 11
            color: root.sttState === "rec" ? Theme.err
                 : root.sttState === "stt" ? Theme.live : Theme.text
            // pulsing dot while recording
            SequentialAnimation on opacity {
              running: root.sttState === "rec"; loops: Animation.Infinite
              NumberAnimation { to: 0.25; duration: 500 }
              NumberAnimation { to: 1; duration: 500 }
            }
          }

          MouseArea {
            id: micMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.sttState === "idle" ? root.startRec() : root.stopRec()
          }
        }

        Rectangle {
          id: sendBtn
          anchors.right: parent.right
          anchors.rightMargin: 6
          anchors.verticalCenter: parent.verticalCenter
          width: 28; height: 26; radius: 5
          color: sendMa.containsMouse ? Theme.hover : Theme.bg
          Behavior on color { ColorAnimation { duration: 200 } }
          scale: sendMa.containsMouse ? 1.07 : 1
          Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
          Text {
            anchors.centerIn: parent
            text: root.busy || root.sending ? "\uf04d" : "➤"
            font.family: Theme.font
            font.pixelSize: 12
            color: root.busy || root.sending ? Theme.err : Theme.live
          }
          MouseArea {
            id: sendMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.busy || root.sending ? root.interrupt() : root.send()
          }
        }
      }
      // ----- attached clipboard images (chips above the input row) -----
      Row {
        id: imageChips
        transform: Translate { x: root.swipeOfs }
        x: inputRow.x
        y: inputRow.y - 34
        spacing: 6
        opacity: visible ? 1 : 0
        visible: root.mode === "chat" && root.pendingImages.length > 0
                 && root.menu === ""
        Behavior on y { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        Repeater {
          model: root.pendingImages

          Rectangle {
            id: chip
            required property var modelData
            required property int index
            width: chipRow.implicitWidth + 18
            height: 28
            radius: 5
            color: Theme.surface
            border.color: Theme.border
            border.width: 1

            Row {
              id: chipRow
              anchors.centerIn: parent
              spacing: 6

              Image {
                width: 20; height: 20
                anchors.verticalCenter: parent.verticalCenter
                source: root.imageUri(chip.modelData)
                sourceSize: Qt.size(40, 40)
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "[Image " + (chip.index + 1) + "]"
                font.family: Theme.font
                font.pixelSize: 10
                color: Theme.text
              }

              Item {
                width: 12; height: 12
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  anchors.centerIn: parent
                  text: "\uf00d"
                  font.family: Theme.font
                  font.pixelSize: 10
                  color: delMa.containsMouse ? Theme.err : Theme.muted
                }

                MouseArea {
                  id: delMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.removePendingImage(chip.index)
                }
              }
            }
          }
        }
      }

      // ----- empty state (TUI-style) -----
      Item {
        id: emptyState
        transform: Translate { x: root.swipeOfs }
        x: 10
        width: parent.width - 20
        y: panelContent.empty ? inputRow.y - 122 : inputRow.y
        height: 120
        visible: panelContent.empty
        opacity: panelContent.empty ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        Column {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 8

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "󰆍"
            font.family: Theme.font
            font.pixelSize: 40
            color: Theme.muted
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "ask opencode"
            font.family: Theme.font
            font.bold: true
            font.pixelSize: 15
            color: Theme.accent
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "@file mention  ·  /command  ·  Ctrl+V image  ·  mic for voice"
            font.family: Theme.font
            font.pixelSize: 10
            color: Theme.muted
          }
        }
      }

      // ----- history loading (session switch / first load) -----
      Text {
        id: chatLoadingLabel
        transform: Translate { x: root.swipeOfs }
        anchors.horizontalCenter: parent.horizontalCenter
        y: inputRow.y - 56
        visible: root.chatLoading && root.mode === "chat"
        text: "◌ loading chat…"
        font.family: Theme.font
        font.pixelSize: 11
        color: Theme.muted
      }

      // ----- translate / calculator tabs -----
      Item {
        id: modeBody
        transform: Translate { x: root.swipeOfs }
        x: 10
        y: headerRow.height + 16
        width: parent.width - 20
        height: parent.height - headerRow.height - 26
        visible: root.mode !== "chat"
        opacity: root.mode !== "chat" ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        IntelTranslate {
          id: translateBox
          anchors.fill: parent
          visible: root.mode === "translate"
          panelActive: root.panelOpen && root.mode === "translate"
          // popup field edited directly (compositor focus moved there) →
          // mirror back into the bar's real editor
          onSourceTextChanged: if (root.mode === "translate" && !root.inputSyncing) {
            root.inputSyncing = true;
            hiddenInput.text = translateBox.sourceText;
            root.inputSyncing = false;
          }
          onCursorMoved: pos => {
            if (!root.inputSyncing) {
              root.inputSyncing = true;
              hiddenInput.cursorPosition = pos;
              root.inputSyncing = false;
            }
          }
          onCopyRequested: text => {
            if (text !== "") Quickshell.execDetached(["wl-copy", text]);
            root.showToast("copied");
          }
        }

        Calc {
          id: calcBox
          anchors.centerIn: parent
          width: 420
          height: 540
          visible: root.mode === "calc"
          onCopyRequested: text => {
            if (text !== "") Quickshell.execDetached(["wl-copy", text]);
            root.showToast("copied");
          }
        }
      }

      // ----- jump to latest -----
      // floats over the chat, above the input row; shown once the user
      // scrolled away from the bottom (pinned went false)
      Rectangle {
        id: jumpBtn
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 12
        anchors.bottomMargin: 54     // input row (38) + gap
        z: 5
        visible: opacity > 0
        opacity: (!chatView.pinned && root.panelOpen && root.mode === "chat") ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        width: 30
        height: 22
        radius: 5
        color: jumpMa.containsMouse ? Theme.hover : Theme.surface
        border.color: Theme.border
        border.width: 1

        Text {
          anchors.centerIn: parent
          text: "\uf103"           // angle-double-down
          font.family: Theme.font
          font.pixelSize: 11
          color: Theme.text
        }

        MouseArea {
          id: jumpMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            chatView.pinned = true;
            chatView.stick();
          }
        }
      }

      // ----- copied toast -----
      Rectangle {
        id: copyToast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 52
        z: 10
        width: toastText.implicitWidth + 20
        height: 22
        radius: 5
        color: Theme.surface
        border.color: Theme.border
        border.width: 1
        opacity: toastTimer.running ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

        Text {
          id: toastText
          anchors.centerIn: parent
          text: "copied to clipboard"
          font.family: Theme.font
          font.bold: true
          font.pixelSize: 10
          color: Theme.text
        }

        Timer {
          id: toastTimer
          interval: 1400
        }
      }

      // Escape is handled by an application-wide Shortcut on the root (below)
    }
  }

  // Escape closes the open menu, or the panel when no menu is open. Layer
  // surfaces do not reliably map onto Qt's "active window", which made a
  // window-scoped Shortcut silently do nothing — application scope works.
  Shortcut {
    sequence: "Escape"
    context: Qt.ApplicationShortcut
    onActivated: root.closeMenuOrPanel()
  }

  onPanelOpenChanged: {
    if (panelOpen) {          // open: cancel any pending close so the
      hideAnim.stop();        // fade-in plays from fully transparent
      panelShown();           // connect + reload (also on a rapid reopen,
      return;                 // where PopupWindow.visible never changed)
    }
    hideAnim.restart();       // close: keep mapped while fading out
    root.closeMenu();
    activePoll.stop();
    // the SSE stream deliberately keeps running while closed: it feeds the
    // "turn finished" desktop notification and keeps the model warm
  }

  // tab switch: the bar's hiddenInput is the single real editor — point
  // it at the newly active tab's field (both directions stay in sync)
  onModeChanged: {
    root.closeMenu();         // a finder/menu from the old tab must not linger
    // tab swipe: jump the bodies to the side (instant), then glide to 0
    const t = mode === "chat" ? 0 : mode === "translate" ? 1 : 2;
    const dir = t > prevTab ? 1 : -1;
    prevTab = t;
    swipeBehavior.enabled = false;
    swipeOfs = dir * 48;
    swipeBehavior.enabled = true;
    Qt.callLater(() => root.swipeOfs = 0);
    // the bar's hiddenInput is the single real editor — point
    // it at the newly active tab's field (both directions stay in sync)
    root.inputSyncing = true;
    hiddenInput.text = mode === "translate" ? translateBox.sourceText
                                            : inputField.text;
    root.inputSyncing = false;
    if (panelOpen) root.focusPanelField();
  }

  // fallback polling only when the SSE stream is not delivering
  Timer {
    interval: 50
    repeat: true
    running: root.panelOpen && (root.busy || root.sending) && !root.streamLive
    onTriggered: {
      root.loadMessages();
      root.loadPerms();
      root.loadForms();
      // stream-dead escape: a missed execution-end must not wedge us busy
      if (root.busy && Date.now() - root.lastChangeMs > 30000) root.busy = false;
    }
  }

  // slow safety poll while a turn is in flight: reloads so the message
  // reconciliation converges, and ends a stalled turn locally if its
  // execution-end event was missed (a stream reconnect drops history and
  // the server never replays it)
  Timer {
    interval: 3000
    repeat: true
    running: root.panelOpen && root.busy && root.streamLive
    onTriggered: {
      root.loadMessages();
      if (root.busy && root.turnStartMs > root.execEndMs
          && Date.now() - root.lastChangeMs > 60000) {
        root.execEndMs = Date.now();
        root.busy = false;
      }
    }
  }

  // chat model: SSE deltas update individual items incrementally
  ListModel { id: chatModel }
}
