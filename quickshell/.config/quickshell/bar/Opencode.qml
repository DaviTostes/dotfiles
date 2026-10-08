import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls.Basic
import "../hyprconf"

// opencode — native chat panel (no kitty window at all).
//
// Talks to the opencode HTTP service (the same background server the TUI
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
//   GET  /api/info                                service up? (v2; /api/health older)
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
//   POST /api/session/{id}/permission/{pid}/reply {decision: once|always|reject}
//   GET  /api/fs/find?query=&type=file            @-mention file finder
//   GET  /api/agent /api/model /api/command       switcher contents
//   GET  /api/event                               SSE event stream
Pill {
  id: root

  // ---------- panel ----------
  property bool panelOpen: false
  // panelExpanded: the dropdown grows to a large, screen-centered window
  // (chatbot style). Toggled from the header button; Escape collapses it
  // back first. NB: `expanded` is taken by the foldout map below.
  property bool panelExpanded: false
  // one-shot: open straight into panelExpanded (set by openExpanded())
  property bool pendingExpanded: false
  // standalone: this instance is a full-mode-only chat hosted outside a bar
  // (its own FloatingWindow) so it can be open at the same time as the bar's
  // docked intelligence central. The pill/docked dropdown are unused.
  property bool standalone: false
  // panel fade (0 hidden, 1 shown). Driven by explicit animations so an
  // expand/collapse can fade the panel out, snap the surface to the other
  // size/position, then fade back in. Animating the surface size every frame
  // instead makes the compositor reallocate the buffer each frame and drops
  // the whole panel to ~15fps.
  property real panelFade: 0
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
  property string sideQuery: ""       // full-mode history rail filter box
  property bool sidebarOpen: true     // full-mode history rail shown/collapsed
  // models / agents / sessions take the keyboard over as a search box
  readonly property bool menuSearchOpen: root.menu === "models"
      || root.menu === "agents" || root.menu === "sessions"

  // ---------- service ----------
  property string svcUrl: ""
  property string svcPw: ""
  property bool svcUp: false
  property int svcTries: 0
  property real lastSpawnMs: 0    // throttle duplicate `opencode serve` spawns

  // ---------- chat state ----------
  property var session: null      // Session.Info or null
  property var sessionList: []
  property var activeSessions: ({})  // sessionID -> true while a turn is running
  // The chat HISTORY (which sessions are panel-owned) is shared via
  // OpencodeShared, but the CURRENT chat is per-instance: the docked panel and
  // the standalone window can show different conversations at once.
  property bool newChatPending: false  // "+" pressed, session not created yet
  property var agents: []
  property var models: []
  property var commands: []
  property var fileHits: []       // @-mention finder hits: {path, type}
  property int fileSel: 0         // keyboard-selected finder hit
  property int finderSeq: 0       // guards against out-of-order finder replies
  property string finderQuery: "" // latest @-token, requested after a debounce
  property bool finderBusy: false // request in flight (drives the menu hint)
  property var pendingImages: []  // clipboard images awaiting send: {name, b64}
  property int imageSeq: 0        // monotonic, so chip names never collide
  property bool pasteFallbackText: true  // Ctrl+V falls back to text paste
  property var pendingForms: []   // pending select-questions (Form.Info)
  property var formAnswers: ({})  // formID -> { fieldKey: answer }
  property var formTextTarget: null  // { formID, key, title, form } while typing an answer
  property var expanded: ({})     // key -> bool, for tool/reasoning foldouts
  property bool sending: false
  property bool busy: false       // assistant turn in flight
  property bool toolRunning: false // newest part is a running tool (robot's tool)
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
  property real turnEndMs: 0      // last observed turn end (grace for late message writes)
  property real lastChangeMs: Date.now()  // last visible message-list change
  property string prevTopKey: ""          // newest message identity at previous load
  property real lastDeltaMs: 0            // last streaming token received
  property bool clearBusyNextLoad: false  // panel (re)opened: all-complete ⇒ idle
  property bool rebuilding: false         // chatModel rebuild in progress (guards scroll state)
  property bool chatLoading: false        // switching chats: history still arriving
  // raw message cache (newest-first) per session, so later reloads can fetch
  // only the newest page instead of re-paging the whole history. Sid-keyed:
  // a different session starts fresh.
  property var msgCache: []
  property string msgCacheSid: ""
  property int msgLoadSeq: 0              // supersedes in-flight paginated loads
  property bool msgPaginating: false      // full-history pagination in flight
  property bool msgReloadPending: false   // a load was asked for mid-pagination
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
  // Qt.btoa(string) is deprecated and floods the log on every request, so the
  // Basic-auth Base64 of the (ASCII) "opencode:<password>" credentials is
  // built directly here.
  function b64ascii(s) {
    const C = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let out = "";
    for (let i = 0; i < s.length; i += 3) {
      const b0 = s.charCodeAt(i) & 0xff;
      const has1 = i + 1 < s.length, has2 = i + 2 < s.length;
      const b1 = has1 ? s.charCodeAt(i + 1) & 0xff : 0;
      const b2 = has2 ? s.charCodeAt(i + 2) & 0xff : 0;
      out += C[b0 >> 2];
      out += C[((b0 & 3) << 4) | (b1 >> 4)];
      out += has1 ? C[((b1 & 15) << 2) | (b2 >> 6)] : "=";
      out += has2 ? C[b2 & 63] : "=";
    }
    return out;
  }

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
    x.setRequestHeader("Authorization", "Basic " + root.b64ascii("opencode:" + root.svcPw));
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
    // arm the watchdog at connect time, not only on the first byte: a curl
    // that connects but then receives nothing (half-open/hung server) would
    // otherwise leave streamLive stuck true forever, which disables the
    // fallback polls and freezes the panel.
    watchdog.restart();
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
            root.turnEndMs = Date.now();
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
        if (mine) {
          root.busy = false; root.execEndMs = Date.now();
          root.turnEndMs = Date.now(); refreshSoon();
        }
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
        if (mine) {
          root.busy = false; root.execEndMs = Date.now();
          root.turnEndMs = Date.now(); refreshSoon();
        }
        return;
      case "session.error":
        if (mine) {
          root.busy = false;
          root.execEndMs = Date.now();
          root.turnEndMs = Date.now();
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
  // Every row entering the ListModel goes through here, so the key index and
  // text map stay in lockstep and — more importantly — every role is coerced
  // to the type the model pinned. ListModel rejects (or silently drops) a
  // value whose type does not match the role's first-seen type, and an
  // `undefined` from a missing field is not a supported variant at all
  // ("Can't create role for unsupported data type"). `toolIn` is normalised
  // to its String form by loadMessages because tool inputs are maps.
  function modelRow(d) {
    return {
      key: d.key === undefined ? "" : String(d.key),
      kind: d.kind === undefined ? "" : String(d.kind),
      text: d.text === undefined || d.text === null ? "" : String(d.text),
      name: d.name === undefined || d.name === null ? "" : String(d.name),
      state: d.state === undefined || d.state === null ? "" : String(d.state),
      toolIn: d.toolIn === undefined || d.toolIn === null ? "" : String(d.toolIn),
      toolOut: d.toolOut === undefined || d.toolOut === null ? "" : String(d.toolOut),
      diff: d.diff === undefined || d.diff === null ? "" : String(d.diff),
      live: d.live === true
    };
  }

  function modelAppend(d) {
    const k = d.key + "|" + d.kind;
    root.modelKeyMap[k] = root.modelKeys.length;
    root.modelKeys.push(k);
    root.textByKey[k] = d.text === undefined ? "" : d.text;
    chatModel.append(root.modelRow(d));
  }

  // insert at a specific position, shifting the key->index map from there on
  // (ListModel.insert reindexes entries, so the map must follow)
  function modelInsert(i, d) {
    const k = d.key + "|" + d.kind;
    chatModel.insert(i, root.modelRow(d));
    const keys = root.modelKeys.slice();
    keys.splice(i, 0, k);
    root.modelKeys = keys;
    const map = Object.assign({}, root.modelKeyMap);
    for (let j = i; j < keys.length; j++) map[keys[j]] = j;
    root.modelKeyMap = map;
    root.textByKey[k] = d.text === undefined ? "" : d.text;
  }

  // The key of a row changed in place (a new message got its server id): move
  // the index maps so deltas keep resolving, without recreating the row.
  function renameModelKey(i, newKey) {
    const oldKey = root.modelKeys[i];
    if (oldKey === undefined || oldKey === newKey) return;
    const keys = root.modelKeys.slice();
    keys[i] = newKey;
    root.modelKeys = keys;
    const map = Object.assign({}, root.modelKeyMap);
    delete map[oldKey];
    map[newKey] = i;
    root.modelKeyMap = map;
    // carry the accumulated text across (the streaming deltas arrived under
    // the old, id-less key)
    if (root.textByKey[oldKey] !== undefined && root.textByKey[newKey] === undefined)
      root.textByKey[newKey] = root.textByKey[oldKey];
    delete root.textByKey[oldKey];
    chatModel.setProperty(i, "key", newKey.slice(0, newKey.lastIndexOf("|")));
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
    // while the chat is hidden behind the "loading" state a bigger batch is
    // free (nothing is painted mid-build), so a long session opens sooner
    const budget = root.chatLoading ? 64 : root.rebuildChunkSize;
    while (root.rebuildAt < q.length && n < budget) {
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
    // (re)probe the service as well: a stale `svcUp` after a server restart
    // would otherwise leave the panel with no SSE stream (and no live turn
    // updates) until the pill was clicked again
    if (root.svcUp) root.connectStream();
    else root.checkService();
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

  // open the panel straight in the large, centered (chatbot) mode. Recorded
  // as a pending wish so onPanelOpenChanged can snap there before the window
  // is ever painted (setting panelExpanded afterwards would flash docked).
  function openExpanded() {
    root.pendingExpanded = true;
    root.panelOpen = true;
  }

  // The docked <-> full swap that used to live here is gone: the full chat is
  // now the standalone `opencodeFull` instance (shell.qml), so this component
  // never expands or collapses while open — it only opens/closes. `standalone`
  // instances are the ones that open straight into full mode.

  // focus the single real editor (the bar's hiddenInput) and mirror the
  // active tab's field into it. In full mode the floating window has normal
  // compositor focus, so the visible field takes focus directly instead.
  function focusPanelField() {
    if (!root.panelOpen) return;
    root.inputSyncing = true;
    hiddenInput.text = root.mode === "translate" ? translateBox.sourceText
                     : root.mode === "calc" ? calcBox.draft
                     : inputField.text;
    root.inputSyncing = false;
    root.focusChatEditor();
  }

  // Focus whichever editor owns the keyboard: the visible field in full mode
  // (real window, normal focus), the bar's hidden editor when docked.
  function focusChatEditor() {
    if (!root.panelOpen) return;
    if (root.panelExpanded) {
      if (root.mode === "calc") { if (calcBox) calcBox.focusEntry(); return; }
      if (inputField) inputField.forceActiveFocus();
      return;
    }
    hiddenInput.forceActiveFocus();
  }

  Timer {
    id: refocusTimer
    interval: 250
    onTriggered: if (root.panelOpen) root.focusChatEditor();
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

  // The service is up when its info probe answers. opencode v2 dropped
  // GET /api/health (it now 404s), so probing it made the widget believe the
  // service was down: it never marked svcUp, never called connectStream() and
  // therefore never opened the SSE stream — the panel then only refreshed on
  // open/close (and never learned a turn ended). Probe /api/info, falling back
  // to /api/health for older servers.
  function checkService() {
    if (root.svcUrl === "") return respawnService();
    const up = () => {
      root.svcUp = true;
      root.svcTries = 0;         // recovered: allow future respawns again
      root.error = "";
      loadSession();
      loadExtras();
      connectStream();
    };
    api("GET", "/api/info", null, okInfo => {
      if (okInfo) return up();
      api("GET", "/api/health", null, okHealth => {
        if (okHealth) return up();
        root.svcUp = false;
        respawnService();
      });
    });
  }

  function respawnService() {
    // ensureService() resets svcTries on every pill click, so without this
    // throttle each open of a genuinely-down service spawned another
    // `opencode serve`. One spawn per 5s is enough to auto-start it.
    const now = Date.now();
    if (root.svcTries === 0 && now - root.lastSpawnMs > 5000) {
      Quickshell.execDetached(["opencode", "serve", "--service"]);
      root.lastSpawnMs = now;
    }
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

  Timer {
    id: retryTimer
    interval: 1200
    // reload() forces a fresh disk read; its onLoaded then runs readService()
    onTriggered: svcFile.reload()
  }

  // ---------- data loaders ----------
  // one place owns the session list + the running-session map; it runs on
  // service connect, on panel open and whenever the server reports the list
  // changed (session.created/moved/deleted). `parentID=null` keeps subagent
  // child sessions out of the picker — they are not chats you pick.
  function loadSession() {
    api("GET", "/api/session/active", null, (okA, a) => {
      root.activeSessions = (okA && a && a.data) ? a.data : {};
      api("GET", "/api/session?limit=200&parentID=null", null, (ok, data) => {
        if (!ok || !data || !data.data) return;
        OpencodeShared.prune(data.data);
        // the picker and the auto-pick only ever see panel-owned chats; the
        // full server list is used above to prune dead ids
        const own = data.data.filter(s => OpencodeShared.panelSessions[s.id]);
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
    root.turnEndMs = 0;
    root.lastChangeMs = Date.now();
    root.prevTopKey = "";
    root.clearBusyNextLoad = false;
    root.toolRunning = false;
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

  // ---------- full-mode history rail ----------
  // The rail lists the SAME panel-owned chats as the sessions menu (never the
  // TUI/other integrations), newest first, filtered by the rail's search box.
  function sideFilteredSessions() {
    const q = root.sideQuery.trim().toLowerCase();
    if (q === "") return root.sessionList;
    return root.sessionList.filter(s =>
      root.sessionLabel(s).toLowerCase().indexOf(q) !== -1
      || (s.agent || "").toLowerCase().indexOf(q) !== -1);
  }

  // bucket the filtered chats into Claude/ChatGPT-style date sections. One
  // function on purpose: the Repeater binds to root.sideGroups() and QML
  // re-evaluates it whenever sessionList / sideQuery change.
  function sideGroups() {
    const t0 = new Date();
    t0.setHours(0, 0, 0, 0);
    const base = t0.getTime();
    const day = 86400000;
    const groups = [
      { label: "Today", items: [] },
      { label: "Yesterday", items: [] },
      { label: "Previous 7 days", items: [] },
      { label: "Previous 30 days", items: [] },
      { label: "Older", items: [] }
    ];
    for (const s of root.sideFilteredSessions()) {
      const t = s.time || {};
      const ts = t.updated || t.created || 0;
      let gi = 4;
      if (ts >= base) gi = 0;
      else if (ts >= base - day) gi = 1;
      else if (ts >= base - 7 * day) gi = 2;
      else if (ts >= base - 30 * day) gi = 3;
      groups[gi].items.push(s);
    }
    return groups.filter(g => g.items.length > 0);
  }

  function sideClearQuery() {
    root.sideQuery = "";
    if (sideSearch) sideSearch.text = "";
  }

  function sideNewChat() {
    root.sideClearQuery();
    root.newChat();
  }

  function sideSwitch(s) {
    root.sideClearQuery();
    root.switchSession(s);
    // switchSession only refocuses when it closes a menu; clicking the rail
    // must hand the keyboard back to the chat editor explicitly
    root.focusChatEditor();
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
        .map(a => ({ id: a.id, name: a.name, description: a.description || "" }));
    });
    api("GET", "/api/model", null, (ok, d) => {
      root.models = (ok && d && d.data ? d.data : [])
        .map(m => {
          const caps = m.capabilities || {};
          const c = (m.cost && m.cost[0]) || null;
          return {
            id: m.modelID,
            providerID: m.providerID,
            name: m.name || m.modelID,
            image: !!(caps.input && caps.input.indexOf("image") >= 0),
            tools: !!caps.tools,
            variants: (m.variants || []).map(v => v.id),
            costIn: c ? c.input : 0,
            costOut: c ? c.output : 0
          };
        })
        // provider-grouped order so the picker's sections are stable
        .sort((a, b) => a.providerID.localeCompare(b.providerID)
                     || a.name.localeCompare(b.name));
    });
    api("GET", "/api/command", null, (ok, d) => {
      root.commands = (ok && d && d.data ? d.data : [])
        .map(c => ({ name: c.name, description: c.description || "" }));
    });
  }

  // ---------- model / agent labels + variants ----------
  // the session model ref ({id, providerID, variant}) or the last one used
  function modelRef() {
    return (root.session && root.session.model) ? root.session.model
         : root.lastModel;
  }

  function modelObjFor(ref) {
    if (!ref) return null;
    return root.models.find(m => m.id === ref.id && m.providerID === ref.providerID)
        || root.models.find(m => m.id === ref.id) || null;
  }

  function currentModelObj() { return root.modelObjFor(root.modelRef()); }

  // friendly name for the composer chip, never the raw id when we know it
  function modelChipLabel() {
    const ref = root.modelRef();
    if (!ref) return "model";
    const m = root.modelObjFor(ref);
    let label = m ? m.name : ref.id;
    if (ref.variant && ref.variant !== "default") label += " · " + ref.variant;
    return label;
  }

  function currentVariants() {
    const m = root.currentModelObj();
    return m ? m.variants : [];
  }

  function currentVariant() {
    const ref = root.modelRef();
    return (ref && ref.variant) ? ref.variant : "default";
  }

  function agentChipLabel() {
    const id = (root.session && root.session.agent) ? root.session.agent
             : root.lastAgent;
    if (!id) return "agent";
    const a = root.agents.find(x => x.id === id);
    return a ? a.name : id;
  }

  // capability / cost cue line under a model name
  function modelMeta(m) {
    const parts = [m.providerID];
    if (m.image) parts.push("img");
    if (m.tools) parts.push("tools");
    if (m.variants && m.variants.length) parts.push("reason");
    if (m.costIn > 0 || m.costOut > 0)
      parts.push("$" + m.costIn + "/" + m.costOut);
    return parts.join("  ·  ");
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

  // Pretty-print a tool input as a String. ListModel pins each role's type
  // from the first value it receives ("Can't assign to existing role … of
  // different type"), and tool inputs arrive as maps, lists or plain strings
  // depending on the tool — so the model stores the string form only.
  // Called once per tool part on a reload, which JSON.stringify handles fine.
  function toolInputText(v) {
    if (v === null || v === undefined || v === "") return "";
    if (typeof v === "string") return v;
    try {
      if (!Array.isArray(v) && typeof v === "object"
          && Object.keys(v).length === 0) return "";
      return JSON.stringify(v, null, 1);
    } catch (e) { return ""; }
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

  // opencode is waiting on the user: a select-question (form) or a permission
  // request needs an answer or the turn stalls forever. One notification per
  // question, only while the panel is closed (open = you can see it), and
  // deduplicated across monitors by a shared key.
  function notifyAsk(key, title, body) {
    if (key === "" || Notifs.lastOpencodeAskKey === key) return;
    Notifs.lastOpencodeAskKey = key;
    const t = title || "opencode — pergunta";
    Quickshell.execDetached(["notify-send", "-u", "normal", "-a", "opencode",
                             t, body || "o opencode está esperando sua resposta"]);
  }

  // Reconcile the model with `desired` by key instead of wiping it. Used when
  // the linear prefix broke but the change is still "same chat, a part was
  // inserted": the usual case while a turn streams, because a delta can reach
  // us before the server persists the part (or the server reorders
  // reasoning/text). Returns false unless merging is provably safe; anything
  // else (session switch, removals, real reorder) must rebuild.
  //
  // Safe means: every row on screen is either present in `desired` (so it gets
  // updated in place) or sits in an unbroken run at the very end whose keys
  // `desired` does not contain at all — the "streamed ahead of the server"
  // tail. That guarantees an insert can never duplicate or shadow a row.
  function mergeShape(desired) {
    const mCount = chatModel.count;
    if (mCount === 0) return false;

    // 1. how many rows on screen are also in `desired`? They must be a prefix
    //    of the model: once a row is "unknown to the server", everything after
    //    it must be unknown too (else it is a reorder, not a trailing tail).
    const want = {};
    for (const d of desired) want[d.key + "|" + d.kind] = true;

    let known = 0;
    while (known < mCount) {
      const it = chatModel.get(known);
      if (!want[it.key + "|" + it.kind]) break;
      known++;
    }
    for (let j = known; j < mCount; j++) {
      const it = chatModel.get(j);
      if (want[it.key + "|" + it.kind]) return false;   // unknown, then known again
    }

    // 2. the known rows must appear in `desired` in the SAME order, and the
    //    rows of `desired` missing from the model are the inserts.
    const modelAt = i => chatModel.get(i).key + "|" + chatModel.get(i).kind;
    const inserts = [];
    let mi = 0;
    for (let di = 0; di < desired.length; di++) {
      if (mi < known && modelAt(mi) === desired[di].key + "|" + desired[di].kind) {
        mi++;
      } else {
        inserts.push(di);
      }
    }
    if (mi !== known) return false;   // known rows finished early → out of order

    // 3. apply: insert the missing rows in FORWARD order, then refresh the
    //    shared ones. The trailing unknowns (streamed-ahead tail) are left
    //    exactly as they are. Inserting back-to-front (the old code) put an
    //    insert whose desired index is >= `known` AFTER that tail, e.g.
    //    [A, X] + desired [A, B, C] became [A, B, X, C] instead of
    //    [A, B, C, X]; forward inserts land before the tail as intended.
    for (let i = 0; i < inserts.length; i++)
      root.modelInsert(inserts[i], desired[inserts[i]]);

    for (let di = 0, mj = 0; di < desired.length && mj < chatModel.count; ) {
      const it = chatModel.get(mj);
      if (it.key === desired[di].key && it.kind === desired[di].kind) {
        const d = desired[di];
        if (it.text !== d.text) {
          chatModel.setProperty(mj, "text", d.text);
          root.textByKey[d.key + "|" + d.kind] = d.text;
        }
        if (it.name !== d.name) chatModel.setProperty(mj, "name", d.name);
        if (it.state !== d.state) chatModel.setProperty(mj, "state", d.state);
        if (it.toolIn !== d.toolIn) chatModel.setProperty(mj, "toolIn", d.toolIn);
        if (it.toolOut !== d.toolOut) chatModel.setProperty(mj, "toolOut", d.toolOut);
        if (it.diff !== d.diff) chatModel.setProperty(mj, "diff", d.diff);
        if (it.live && !d.live) chatModel.setProperty(mj, "live", false);
        di++; mj++;
      } else {
        di++;
      }
    }
    return true;
  }

  // The message endpoint pages (default 50, newest-first) with a cursor. Only
  // ever fetching the first page made the returned window SLIDE as the chat
  // grew: the model's oldest rows fell out of `desired`, the common prefix
  // broke at row 0 and mergeShape bailed, so every tool update rebuilt the
  // whole chat (the "loading chat" flash). So the first load of a session
  // pages through the WHOLE history into `msgCache`; later loads fetch just
  // the newest page and merge it with the cached older messages.
  function loadMessages() {
    if (!root.session) return;
    const sid = root.session.id;
    // A full-history pagination for THIS session is still in flight: a second
    // load would see an empty cache, fetch only page 1 and freeze the history
    // there. Remember it and re-run once the pagination finishes.
    if (root.msgPaginating && root.msgCacheSid === sid) {
      root.msgReloadPending = true;
      return;
    }
    const fresh = root.msgCacheSid !== sid;   // new session → full history
    if (fresh) {
      root.msgCache = [];
      root.msgCacheSid = sid;
      root.msgPaginating = true;
      root.msgReloadPending = false;
    }
    const seq = ++root.msgLoadSeq;
    const raw = [];
    const done = () => {
      root.msgPaginating = false;
      if (root.msgReloadPending) {
        root.msgReloadPending = false;
        root.loadMessages();     // a request raced the pagination: re-fetch
      }
    };
    const fetchPage = cursor => {
      if (seq !== root.msgLoadSeq) return;    // superseded by a newer load
      const q = "?limit=200"
          + (cursor ? "&cursor=" + encodeURIComponent(cursor) : "");
      api("GET", "/api/session/" + sid + "/message" + q, null, (ok, data, status) => {
        if (seq !== root.msgLoadSeq) return;
        // the displayed session was deleted elsewhere (TUI, another panel):
        // drop it and let loadSession pick a live one instead of showing a
        // permanently frozen history
        if (status === 404 && root.session && root.session.id === sid) {
          root.session = null;
          root.modelClear();
          root.resetTurnState();
          done();
          root.loadSession();
          return;
        }
        if (!ok || !data || !data.data) { root.chatLoading = false; done(); return; }
        for (const m of data.data) raw.push(m);
        const next = data.cursor && data.cursor.next;
        if (next && fresh) { fetchPage(next); return; }  // keep paging the history
        // raw is newest-first. On a later load it is only the newest page:
        // splice it on top of the cached older messages (overlap by id).
        let merged;
        if (fresh || raw.length === 0) {
          merged = raw.slice();
        } else {
          const lastId = raw[raw.length - 1].id;
          let idx = -1;
          for (let i = 0; i < root.msgCache.length; i++)
            if (root.msgCache[i].id === lastId) { idx = i; break; }
          if (idx < 0) {
            // the newest page no longer overlaps the cache (more than a page
            // of messages arrived since it was built): re-page the whole
            // history instead of dropping everything older than this page
            root.msgCacheSid = "";
            done();
            root.loadMessages();
            return;
          }
          merged = raw.concat(root.msgCache.slice(idx + 1));
        }
        root.msgCache = merged;
        root.applyMessages(sid, merged);
        done();
      });
    };
    fetchPage(null);
  }

  function applyMessages(sid, raw) {
    if (!root.session || root.session.id !== sid) return;  // switched mid-flight
    const wasPinned = chatView.pinned;
    // rebuild atomically: intermediate contentHeight collapses clamp
    // contentY and would clobber the pinned/scroll state mid-rebuild
    root.rebuilding = true;
    let deferred = false;   // structural rebuild handed to rebuildTimer
    try {
      // `raw` is newest-first; chat order is oldest-first. Walk it backwards
      // instead of copying + reversing the whole array.
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
            if (c.type === "text" && ((c.text || "").trim() !== "" || !done)) {
              // a live part is kept even while empty: dropping it made the
              // row pop in mid-list when the first token landed, which broke
              // the common prefix and forced a structural rebuild (the
              // "loading chat" flash on every tool update)
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
                key: key, kind: "tool",
                // tool rows render through the fold-out, never as plain text,
                // but the role MUST be present: a missing `text` makes the
                // in-place update below write `undefined` into the ListModel,
                // and Qt rejects that variant ("Can't create role for
                // unsupported data type") every single reload.
                text: "", name: name,
                state: (st.status || "") + (st.title ? " · " + st.title : running ? " · running…" : ""),
                // Keep the raw input; it is only pretty-printed when the
                // fold-out is opened (see toolInputText). Normalised to a
                // String here: ListModel pins a role's type from its first
                // value, and a tool input can be a map, a list or a string
                // ("Can't assign to existing role 'toolIn' of different
                // type" rejected every later write of another shape).
                toolIn: toolInputText(st.input),
                toolOut: toolOutText(st),
                diff: diff,
                live: false
              });
            }
          }
        }
      }

      // the newest part drives the little robot's tool: a running tool shows a
      // wrench instead of the hammer
      const lastD = desired.length ? desired[desired.length - 1] : null;
      root.toolRunning = !!(lastD && lastD.kind === "tool"
          && /running|streaming/.test(lastD.state));

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

      // A brand-new assistant message can briefly have NO id server-side, and
      // the key is built from it — so when the id is assigned the row's key
      // changes with the same position and kind. Treat that single trailing
      // row as a rename instead of a structural change: otherwise every id
      // assignment rebuilt the whole chat (the "everything reloads" flicker).
      let renameTail = prefix;
      if (!wasBuilding && prefix < n && prefix === chatModel.count - 1
          && prefix === desired.length - 1
          && chatModel.get(prefix).kind === desired[prefix].kind) {
        renameTail = prefix + 1;
        const it = chatModel.get(prefix);
        const d = desired[prefix];
        // move the streamed state to the new key before it is dropped
        root.renameModelKey(prefix, d.key + "|" + d.kind);
        if ((root.textByKey[d.key + "|" + d.kind] || "").length < (it.text || "").length)
          root.textByKey[d.key + "|" + d.kind] = it.text;
      }
      prefix = renameTail;

      // `chatModel.count > 0` keeps an empty model (a fresh switch, which
      // arrives here already cleared) on the structural path: the append-only
      // path leaves `rebuilding` clear, and a multi-frame append would flip
      // `pinned` off between chunks so the final stick-to-end is dropped.
      //
      // `staleTail`: a trailing "streamed ahead of the server" row is only
      // legitimate while a turn is in flight (or just after it ended, before
      // the server persists it). If the server list is shorter than the model
      // and nothing is running, those extra rows are stale (a message removed
      // elsewhere) and must be dropped by a rebuild — the in-place path and
      // mergeShape would otherwise keep them forever.
      const staleTail = !wasBuilding && !root.busy && !root.sending
          && Date.now() - root.turnEndMs > 2000
          && desired.length < chatModel.count;
      const inPlace = !wasBuilding && !staleTail && chatModel.count > 0
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
          if (it.diff !== d.diff) chatModel.setProperty(i, "diff", d.diff);          // `live` only ever settles true → false (part finished)
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
      } else if (!wasBuilding && !staleTail && root.mergeShape(desired)) {
        // the prefix broke but this is still the same chat with a part
        // inserted (a delta landed before the server persisted it): merge in
        // place instead of clearing the whole model — clearing made every
        // update look like a full chat reload
        root.chatLoading = false;
      } else {
        // genuinely different shape (session switch, removals, reorder): clear
        // and rebuild across frames. Only blank the chat when there was
        // nothing on screen — that is an actual chat switch, and the "loading"
        // state belongs to it.
        if (!wasBuilding && chatModel.count === 0) root.chatLoading = true;
        root.startRebuild(desired);
        deferred = true;
      }

      // busy reconciliation: an incomplete assistant message anywhere means
      // a step is in flight → busy. Clearing is left to the per-step `finish`
      // events (the message list can't tell "between steps" from "turn done"),
      // but an all-complete history also means idle whenever nothing can be
      // observed live — the panel is closed, or the SSE stream is down, so a
      // missed execution-end must not wedge the turn busy forever.
      //
      // `turnEndMs` is a short grace: `step.ended` already set busy=false, and
      // the message list can lag one reload behind, so an incomplete message
      // arriving right after the turn end must not flip `busy` back on.
      //
      // An incomplete assistant message is only evidence of a LIVE turn if we
      // saw the turn start (`turnStartMs > 0`) or the message was updated
      // recently. A stale incomplete message (a turn aborted/errored in a past
      // session, reopened later) must NOT force busy: `turnEndMs` is 0 after a
      // reset, so the old check kept the input disabled and "thinking…" on
      // forever, and the slow poll could not clear it (it requires a known
      // turn start).
      const inc = raw.find(m =>
        m.type === "assistant" && !(m.time && m.time.completed));
      const incTs = inc && inc.time ? (inc.time.updated || inc.time.created || 0) : 0;
      const incFresh = incTs > 0 && Date.now() - incTs < 30000;
      const turnLive = !!inc && (root.turnStartMs > 0 || incFresh);
      if (turnLive) {
        if (Date.now() - root.turnEndMs > 1500) root.busy = true;
      } else if (inc) {
        // stale incomplete: not a live turn, so it must not wedge busy
        root.busy = false;
        root.clearBusyNextLoad = false;
      } else if (!root.panelOpen || root.clearBusyNextLoad
                 || (!root.streamLive && Date.now() - root.turnStartMs > 2000)) {
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
  }

  function loadPerms() {
    if (!root.session) return;
    const sid = root.session.id;
    api("GET", "/api/session/" + sid + "/permission", null, (ok, data) => {
      if (!root.session || root.session.id !== sid) return;  // switched
      const perm = (ok && data && data.data && data.data.length)
          ? data.data[data.data.length - 1] : null;
      root.pendingPerm = perm;
      // a permission request blocks the turn until answered — notify when the
      // panel is closed so it is not silently stuck
      if (perm && !root.panelOpen)
        root.notifyAsk("perm:" + perm.id, "opencode — permissão",
                       perm.action + " — " + (perm.resources || []).join(", "));
    });
  }

  function permReply(reply) {
    if (!root.pendingPerm) return;
    const sid = root.session.id, pid = root.pendingPerm.id;
    root.pendingPerm = null;
    api("POST", "/api/session/" + sid + "/permission/" + pid + "/reply",
        { decision: reply }, () => root.loadPerms());
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
      // a question appeared while the panel was closed: ping the desktop
      // (the form stays pending until it is answered)
      if (!root.panelOpen && list.length > 0) {
        const f = list[list.length - 1];
        root.notifyAsk("form:" + f.id,
                       "opencode — " + (f.title || "pergunta"),
                       root.sessionLabel(root.session));
      }
      // seed/clean the answers map for the forms currently pending
      const ans = Object.assign({}, root.formAnswers);
      for (const f of list) if (!(f.id in ans)) ans[f.id] = {};
      for (const k in ans) if (!list.some(f => f.id === k)) delete ans[k];
      root.formAnswers = ans;
      // a form being typed into can be answered/cancelled from another
      // monitor: drop the text target so Enter cannot reply to a dead form
      if (root.formTextTarget
          && !list.some(f => f.id === root.formTextTarget.formID)) {
        root.formTextTarget = null;
        inputField.text = "";
        hiddenInput.text = "";
      }
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
    root.focusChatEditor();
    // closing any menu must not restore a parked draft into this field
    if (root.menu !== "") root.menu = "";
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
    inputField.text = "";
    hiddenInput.text = "";
    root.focusChatEditor();
  }

  // user picked a chat (picker / rail): show it in THIS panel and remember it
  // in the shared history
  function switchSession(s) {
    root.session = s;
    root.newChatPending = false;
    if (s && s.id) OpencodeShared.remember(s.id);   // opened here → panel owns it
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
      OpencodeShared.forget(s.id);
      root.loadSession();
    });
  }

  // `variant` is an optional reasoning-effort id; `keepOpen` leaves the picker
  // open (used when changing effort so the levels stay visible)
  function switchModel(m, variant, keepOpen) {
    const ref = { id: m.id, providerID: m.providerID };
    if (variant) ref.variant = variant;
    root.lastModel = ref;
    OpencodeShared.touchModel(ref);   // remember for the picker's Recent group
    if (!root.session) { if (!keepOpen) root.closeMenu(); return; }  // applied on creation
    api("POST", "/api/session/" + root.session.id + "/model",
        { model: ref }, ok => {
          if (ok && root.session)
            root.session = Object.assign({}, root.session, { model: ref });
          if (!keepOpen) root.closeMenu();
        });
  }

  // change the reasoning effort of the current model
  function switchVariant(v) {
    const m = root.currentModelObj();
    if (m) root.switchModel(m, v, true);
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
    root.turnEndMs = Date.now();
    api("POST", "/api/session/" + root.session.id + "/interrupt", {}, () => {});
  }

  // parse trailing "@path" tokens into file attachments. A path with spaces
  // (very common here: "Telegram Desktop/…", "FICHA - … .docx") is inserted
  // quoted — @"a b/c.pdf" — so the token survives the whitespace split, and
  // the URI is percent-encoded per path segment because the server reads the
  // attachment straight from it (a raw space or `#` comes back as a 400).
  function collectFiles(text) {
    const files = [];
    const dir = root.session && root.session.location
        ? root.session.location.directory : Quickshell.env("HOME");
    const home = Quickshell.env("HOME");
    const re = /(^|\s)@(?:"([^"]+)"?|([^\s,;]+))/g;
    let m;
    while ((m = re.exec(text)) !== null) {
      const quoted = m[2] !== undefined;
      const tok = quoted ? m[2] : m[3];
      let abs;
      if (tok.startsWith("/")) abs = tok;
      else if (tok.startsWith("~/")) abs = home + tok.slice(1);
      else abs = dir + "/" + tok;
      const uri = "file://" + abs.split("/").map(encodeURIComponent).join("/");
      files.push({ uri: uri, name: tok });
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
      OpencodeShared.remember(data.data.id);   // the panel owns this chat
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
        inputField.text = text;      // keep the draft so it can be fixed
        return;
      }
      const run = sid => api("POST", "/api/session/" + sid + "/command",
          { command: name, text: args }, (ok, d, status) => {
            root.sending = false;
            if (!ok) {
              root.error = "command failed (" + status + ")";
              inputField.text = text;
            } else { root.busy = true; root.turnStartMs = Date.now(); root.loadMessages(); }
          });
      // a command also needs a session: materialise the pending new chat
      if (root.session) run(root.session.id);
      else createSession(text.slice(0, 60), run);
      return;
    }

    const files = collectFiles(text);
    for (const img of root.pendingImages)
      files.push({ uri: root.imageUri(img), name: img.name });
    // images are cleared only once the prompt is accepted, so a failed send
    // does not drop attachments the user would have to re-add by hand
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
              // keep the draft (and the images, cleared only on success)
              // so a failed send is not lost
              inputField.text = text;
              return;
            }
            root.pendingImages = [];
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
      root.finderBusy = false;
      if (root.menu === "files") root.menu = "";
      return;
    }
    // "/" at start with no space yet → command menu
    if (text.length > 0 && text[0] === "/" && text.indexOf(" ") === -1) {
      finderTimer.stop();
      root.fileHits = [];
      root.finderBusy = false;
      root.menu = "commands";
      return;
    }
    // trailing @token → file finder (works before a session exists too).
    // A quoted token (@"a b" or an open @"a b) matches too, so a folder with
    // spaces keeps the finder scoped to it after it is picked. The leading
    // (^|\s) matches collectFiles, so a trailing "@" in an email-like token
    // (foo@bar) does not open the finder.
    const m = text.match(/(^|\s)@(?:"([^"]*)"?|([^\s,;]*))$/);
    if (m) {
      const q = m[2] !== undefined ? m[2] : m[3];
      if (q.length === 0) {
        finderTimer.stop();
        root.finderSeq++;          // cancel any in-flight reply
        root.fileHits = [];
        root.finderBusy = false;
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
    root.finderBusy = false;
    if (root.menu === "files") root.menu = "";
  }

  function runFinder() {
    if (root.menu !== "files" || root.finderQuery === "") return;
    const q = root.finderQuery;
    const seq = ++root.finderSeq;
    root.finderBusy = true;
    api("GET", "/api/fs/find?query=" + encodeURIComponent(q)
        + "&limit=12", null, (ok, data) => {
      if (seq !== root.finderSeq) return;   // a newer query superseded this one
      root.finderBusy = false;
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
    const m = text.match(/@(?:"[^"]*"?|[^\s,;]*)$/);
    if (m) {
      const dir = root.session && root.session.location
          ? root.session.location.directory : Quickshell.env("HOME");
      let rel = path;
      if (rel.indexOf(dir + "/") === 0) rel = rel.slice(dir.length + 1);
      const isDir = type === "directory";
      // the finder returns directories with a trailing "/" already — strip it
      // before re-adding exactly one, else picking a directory typed "//"
      const inner = isDir ? rel.replace(/\/+$/, "") + "/" : rel;
      // quote paths with spaces/commas so the @token survives collectFiles'
      // whitespace split; files get a trailing space so the mention ends,
      // directories keep the finder open scoped to that folder
      const token = /[\s,;]/.test(inner) ? '@"' + inner + '"' : "@" + inner;
      inputField.text = text.slice(0, m.index) + token + (isDir ? "" : " ");
      inputField.cursorPosition = inputField.text.length;
    }
    root.menu = type === "directory" ? "files" : "";
    root.focusChatEditor();
    if (type === "directory") root.updateFinder();
  }

  function toggleFold(key) {
    const e = Object.assign({}, root.expanded);
    e[key] = !e[key];
    root.expanded = e;
  }

  // ---------- list menus (models / agents / sessions) ----------
  // These open a search box inside the panel overlay; the bar's hiddenInput
  // mirror keeps both editors in sync whichever has the keyboard.
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

  // the models the user recently picked, resolved to catalog entries
  function recentModelObjs() {
    const out = [];
    for (const ref of OpencodeShared.recentModels) {
      const m = root.modelObjFor(ref);
      if (m && !out.some(x => x.id === m.id && x.providerID === m.providerID))
        out.push(m);
    }
    return out;
  }

  // flat list — the keyboard selection indexes this and it must match the
  // visual order of modelGroups(). Recents come first while not searching.
  function filteredModels() {
    if (root.menu !== "models") return [];
    const list = root.models.filter(root.modelMatches);
    if (root.menuQuery() !== "") return list;
    const recents = root.recentModelObjs();
    if (recents.length === 0) return list;
    const rest = list.filter(m =>
      !recents.some(r => r.id === m.id && r.providerID === m.providerID));
    return recents.concat(rest);
  }

  // Group for rendering. Each item carries its FLAT index so the keyboard
  // selection never relies on object identity: indexOf() on QML modelData is
  // not reference-stable, which made every row share one selection (and all
  // highlight on hover).
  function modelGroups() {
    if (root.menu !== "models") return [];
    const list = root.filteredModels();
    const groups = [];
    let i = 0;
    if (root.menuQuery() === "") {
      const n = Math.min(root.recentModelObjs().length, list.length);
      if (n > 0) {
        const items = [];
        for (; i < n; i++) items.push({ m: list[i], i: i });
        groups.push({ provider: "Recent", items: items });
      }
    }
    let cur = null;
    for (; i < list.length; i++) {
      const m = list[i];
      if (!cur || cur.provider !== m.providerID) {
        cur = { provider: m.providerID, items: [] };
        groups.push(cur);
      }
      cur.items.push({ m: m, i: i });
    }
    return groups;
  }

  function filteredAgents() {
    if (root.menu !== "agents") return [];
    const q = root.menuQuery();
    if (q === "") return root.agents;
    return root.agents.filter(a =>
      (a.name || "").toLowerCase().indexOf(q) !== -1
      || (a.id || "").toLowerCase().indexOf(q) !== -1
      || (a.description || "").toLowerCase().indexOf(q) !== -1);
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
      root.inputSyncing = true;
      hiddenInput.text = "";
      menuSearchField.text = "";
      root.inputSyncing = false;
    }
    root.menu = name;
    root.menuSel = 0;
    // always open at the top (the list is not scrolled to the active item)
    menuFlick.contentY = 0;
    if (root.panelOpen) root.focusChatEditor();
  }

  function closeMenu() {
    if (root.menu === "") return;
    root.menu = "";
    root.menuSel = 0;
    root.inputSyncing = true;
    menuSearchField.text = "";
    // the bar's editor goes back to the draft shown in the field. This
    // mirrors the FIELD (not a parked copy): the finder/menu edits the field
    // in place, and trusting a parked copy here dropped an @file mention that
    // was picked while a menu was open.
    hiddenInput.text = inputField.text;
    root.inputSyncing = false;
    // hand the keyboard back to the chat editor
    if (root.panelOpen) root.focusChatEditor();
  }

  // keep the keyboard-selected row in view (the search row is first)
  // Keep the keyboard-selected row in view. Row heights differ per menu
  // (sessions 24, agents 36, models 34 + a provider header), so the offset is
  // computed per menu rather than assuming one row height.
  function ensureMenuSelVisible() {
    if (!root.menuSearchable()) return;
    let top = 26;               // the search row (24) + spacing
    let rowH = 26;
    if (root.menu === "models") {
      rowH = 36;                // 34 row + 2 spacing
      // walk the groups so every section header is counted (including Recent)
      outer: for (const g of root.modelGroups()) {
        top += 26;              // header
        for (const it of g.items) {
          if (it.i === root.menuSel) break outer;
          top += rowH;
        }
      }
    } else if (root.menu === "agents") {
      rowH = 38;                // 36 row + 2 spacing
      top += root.menuSel * rowH;
    } else {
      top += root.menuSel * rowH;
    }
    const bottom = top + rowH;
    if (top < menuFlick.contentY) menuFlick.contentY = top;
    else if (bottom > menuFlick.contentY + menuFlick.height)
      menuFlick.contentY = bottom - menuFlick.height;
  }

  function closeMenuOrPanel() {
    if (root.menu !== "") { root.closeMenu(); return; }
    // Escape closes the panel (the standalone full window included) — there is
    // no docked<->full step any more
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

  // abort an in-flight recording OR transcription (panel closed mid-voice).
  // Both processes are stopped: closing during the transcribe phase used to
  // only clear `recProc`, so whisper kept running and finishStt() auto-sent
  // the transcript while the panel was closed.
  function cancelStt() {
    if (root.sttState === "idle") return;
    root.sttCancel = true;
    if (recProc.running) recProc.running = false;
    if (sttProc.running) sttProc.running = false;
  }

  function finishStt(code) {
    root.sttState = "idle";
    // cancelled (panel closed / mic toggled off mid-transcribe): discard
    if (root.sttCancel) { root.sttCancel = false; return; }
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
    // soft blink while a turn is running
    SequentialAnimation on opacity {
      running: root.busy
      loops: Animation.Infinite
      NumberAnimation { to: 0.45; duration: 480; easing.type: Easing.InOutSine }
      NumberAnimation { to: 1; duration: 480; easing.type: Easing.InOutSine }
    }
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
  // keys would be dropped. This hidden editor in the bar window takes
  // active focus when the panel opens and does the actual editing; the
  // popup's visible field mirrors it (both directions, so typing directly
  // into the popup after clicking it — which moves compositor focus to
  // the popup surface — also stays in sync).
  //
  // It is a TextEdit (not a TextInput) so Shift+Enter can insert a real
  // newline: a single-line TextInput would drop it, and the draft would lose
  // its line breaks on the next keystroke.
  property bool inputSyncing: false

  // Enter sends; Shift+Enter inserts a newline. Shared by the hidden editor
  // and the visible field so it behaves the same whichever surface holds the
  // keyboard. In a search menu Enter picks the row and Shift+Enter is a no-op
  // (a single-line query has no use for a line break).
  function handleReturnKey(event) {
    if (event.modifiers & Qt.ShiftModifier) {
      event.accepted = true;
      // only the free-form chat / form-answer editor gets line breaks; a
      // search menu (models/agents/sessions/commands/files) is single-line
      if (root.menuSearchOpen || root.mode !== "chat" || root.menu !== "") return;
      const at = hiddenInput.cursorPosition;
      root.inputSyncing = true;
      hiddenInput.insert(at, "\n");
      hiddenInput.cursorPosition = at + 1;
      root.inputSyncing = false;
      inputField.text = hiddenInput.text;
      inputField.cursorPosition = at + 1;
      if (root.mode === "chat") root.updateFinder();
      return;
    }
    event.accepted = true;
    if (root.formCommitText()) return;
    if (root.menuPickSelected()) return;
    if (root.mode === "translate") translateBox.translate();
    else if (root.mode === "calc") root.calcSubmit();
    else if (root.mode === "chat" && !root.finderPickSelected()) root.send();
  }

  // calc tab: evaluate the echoed line, then clear the bar's real editor
  function calcSubmit() {
    calcBox.submit();
    root.inputSyncing = true;
    hiddenInput.text = "";
    root.inputSyncing = false;
  }

  // calc tab: walk the submitted-line history and mirror the recalled line
  // into the bar's real editor (both surfaces stay in sync)
  function calcHistory(dir) {
    if (dir < 0) calcBox.historyPrev();
    else calcBox.historyNext();
    root.inputSyncing = true;
    hiddenInput.text = calcBox.draft;
    hiddenInput.cursorPosition = calcBox.draft.length;
    root.inputSyncing = false;
  }

  TextEdit {
    id: hiddenInput
    width: 0
    height: 0
    opacity: 0
    // docked only: in full mode the visible field owns the keyboard
    focus: root.panelOpen && !root.panelExpanded
    color: "transparent"
    textFormat: TextEdit.PlainText
    wrapMode: TextEdit.NoWrap

    onTextChanged: if (!root.inputSyncing) {
      root.inputSyncing = true;
      if (root.mode === "translate") translateBox.sourceText = text;
      else if (root.mode === "calc") calcBox.draft = text;
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
      else if (root.mode === "calc") calcBox.setCursorPos(cursorPosition);
      else inputField.cursorPosition = cursorPosition;
      root.inputSyncing = false;
    }
    // the chat's TextEdits never hold the (compositor) keyboard — the bar
    // does. Forward copy from here to whichever message has a selection.
    // BeforeItem so the menu arrows below beat the TextEdit's caret motion.
    Keys.priority: Keys.BeforeItem
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
      // Ctrl+N: start a new chat (the header "+" button was removed)
      if (root.mode === "chat" && root.formTextTarget === null
          && event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier)) {
        root.newChat();
        event.accepted = true;
        return;
      }
      // Ctrl+M: open the model picker (composer-level control)
      if (root.mode === "chat" && event.key === Qt.Key_M
          && (event.modifiers & Qt.ControlModifier)) {
        root.menu === "models" ? root.closeMenu() : root.openMenu("models");
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
      // calc tab: ↑/↓ recall submitted lines, Ctrl+L wipes the transcript
      if (root.mode === "calc") {
        if (event.key === Qt.Key_L && (event.modifiers & Qt.ControlModifier)) {
          calcBox.clearScreen();
          event.accepted = true;
          return;
        }
        if (!(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier))) {
          if (event.key === Qt.Key_Up) { root.calcHistory(-1); event.accepted = true; return; }
          if (event.key === Qt.Key_Down) { root.calcHistory(1); event.accepted = true; return; }
        }
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
    // Enter sends / Shift+Enter inserts a newline (see handleReturnKey).
    // Enter also evaluates in the translate / calc tabs.
    Keys.onReturnPressed: event => root.handleReturnKey(event)
    Keys.onEnterPressed: event => root.handleReturnKey(event)
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
    // only the docked dropdown is click-outside-to-close; the full mode is a
    // real window (a fullscreen catcher layer would sit above it)
    active: root.panelOpen && !root.panelExpanded
    onClicked: root.panelOpen = false
  }

  // ---- panel motion --------------------------------------------------------
  // Open/close drives `panelFade` (and a little scale) instead of the window
  // geometry. Only opacity/transform change per frame, so the compositor keeps
  // the surface buffer as-is and the animation stays smooth.
  ParallelAnimation {
    id: showAnim
    NumberAnimation {
      target: root; property: "panelFade"
      from: 0; to: 1; duration: 190; easing.type: Easing.OutCubic
    }
    NumberAnimation {
      target: panelContent; property: "scale"
      from: 0.97; to: 1; duration: 230; easing.type: Easing.OutCubic
    }
  }
  ParallelAnimation {
    id: hideAnimFx
    NumberAnimation {
      target: root; property: "panelFade"
      to: 0; duration: 160; easing.type: Easing.OutCubic
    }
    NumberAnimation {
      target: panelContent; property: "scale"
      to: 0.97; duration: 200; easing.type: Easing.OutCubic
    }
  }
  // Full mode is a real toplevel, not a layer-shell popup: Hyprland manages it
  // like any floating window (belongs to the workspace it was opened on, can
  // be moved/resized, takes focus normally). The single panelContent is
  // reparented into it while expanded, so the UI and all its state are shared
  // with the docked dropdown.
  FloatingWindow {
    id: fullWin
    title: "opencode"
    color: "transparent"
    // initial size; the content fills whatever size the window ends up with
    implicitWidth: panel.expandedW
    implicitHeight: panel.expandedH
    visible: (root.panelOpen && root.panelExpanded) || fullHideAnim.running
    Timer { id: fullHideAnim; interval: 260 }
    // the compositor can close the window itself (Hyprland killactive / a
    // close request): mirror that into the QML state, otherwise panelOpen
    // stays true and the next toggle only flips it back to false — needing
    // two keypresses to reopen
    onClosed: root.panelOpen = false
    onVisibleChanged: {
      if (visible)
        Qt.callLater(() => { if (inputField) inputField.forceActiveFocus(); });
      else if (!root.panelOpen) root.cancelStt();
    }
  }

  PopupWindow {
    id: panel

    // stays mapped briefly while closing so the fade/slide can play; unused in
    // full mode (the content is reparented into fullWin)
    visible: (root.panelOpen && !root.panelExpanded) || hideAnim.running
    color: "transparent"
    implicitWidth: panelContent.width
    implicitHeight: panelContent.height

    // expanded (chatbot-style) size: as large as the screen comfortably
    // allows, with a minimum so a tiny/unknown screen still works. Kept as
    // explicit properties so the anchor can target the FINAL size before the
    // surface has resized (see onAnchoring).
    readonly property int collapsedW: 660
    readonly property int collapsedH: 700
    readonly property int expandedW: {
      const sw = panel.screen ? panel.screen.width : 0;
      return Math.max(640, Math.min(1080, (sw > 0 ? sw : 1920) - 120));
    }
    readonly property int expandedH: {
      const sh = panel.screen ? panel.screen.height : 0;
      return Math.max(480, Math.min(940, (sh > 0 ? sh : 1080) - 140));
    }

    // ---------- placement ----------
    // The surface is positioned by its CENTER and snapped (never tweened):
    // expanding/collapsing fades the panel out, snaps here, and fades back
    // in. `anchorCX/CY` still exist as the single source of the target so
    // onAnchoring stays trivial, and so opening can snap before first paint.
    property real anchorCX: 0
    property real anchorCY: 0
    onAnchorCXChanged: if (visible) anchor.updateAnchor()
    onAnchorCYChanged: if (visible) anchor.updateAnchor()
    onImplicitWidthChanged: if (visible) anchor.updateAnchor()
    onImplicitHeightChanged: if (visible) anchor.updateAnchor()

    // where the panel's CENTER should sit: the monitor middle when expanded,
    // the pill's box when docked
    function targetCenter() {
      if (root.panelExpanded)
        return { x: (panel.screen ? panel.screen.width : 1920) / 2,
                 y: (panel.screen ? panel.screen.height : 1080) / 2 };
      // docked: the pill lives in the right side bar, so open the panel to its
      // LEFT, top-aligned with the pill and clamped to the screen
      const p = root.mapToItem(null, 0, 0);
      const sh = panel.screen ? panel.screen.height : 1080;
      const h = panel.collapsedH;
      const w = panel.collapsedW;
      const top = Math.max(0, Math.min(p.y, sh - h));
      return { x: (p.x - 6 - w) + w / 2, y: top + h / 2 };
    }

    // set the center target (always a snap — the surface geometry is only
    // ever changed while the panel is transparent)
    function applyTargetCenter() {
      const t = panel.targetCenter();
      panel.anchorCX = t.x;
      panel.anchorCY = t.y;
    }

    Component.onCompleted: panel.applyTargetCenter()
    onScreenChanged: panel.applyTargetCenter()

    Timer { id: hideAnim; interval: 260 }

    // Open-side work lives in root.panelShown(), called from
    // root.onPanelOpenChanged. Doing it here would miss the rapid
    // close→reopen case: `visible` stays true (hideAnim is stopped), so this
    // signal never fires and the panel would come back with no stream.
    onVisibleChanged: {
      if (visible) return;
      // only a real close cancels the take; a docked<->full reparent also
      // hides this window while the panel stays open, and must not drop it
      if (!root.panelOpen) root.cancelStt();
    }
    // the compositor closed the popup: keep the QML state in sync (see fullWin)
    onClosed: root.panelOpen = false

    anchor {
      window: root.QsWindow.window
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
    }

    anchor.onAnchoring: {
      // place the panel by its CENTER (anchorCX/CY, set by applyTargetCenter)
      // minus half the current size. Size and center are only ever changed
      // while the panel is faded out, so this never needs to be smooth.
      anchor.rect.x = Math.round(panel.anchorCX - panelContent.width / 2);
      anchor.rect.y = Math.round(panel.anchorCY - panelContent.height / 2);
      anchor.rect.width = 1;
      anchor.rect.height = 1;
    }

    Rectangle {
      id: panelContent
      x: 0
      y: 0
      // Two fixed sizes (dropdown / expanded) — SNAPPED, never tweened: the
      // size is only ever set while the window is transparent. Animating the
      // size would resize the surface every frame, which makes the compositor
      // reallocate the buffer each frame (~15fps).
      width: root.panelExpanded
          ? (fullWin.width > 0 ? fullWin.width : panel.expandedW)
          : panel.collapsedW
      height: root.panelExpanded
          ? (fullWin.height > 0 ? fullWin.height : panel.expandedH)
          : panel.collapsedH
      color: Theme.bg
      radius: root.panelExpanded ? 12 : 6
      Behavior on radius { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
      border.color: Theme.border
      border.width: 1
      // open/close and the docked<->expanded swap both drive `panelFade`
      // (animated in root); the panel slides down slightly and scales a hair
      // so it drops out of the bar instead of blinking. The window stays
      // mapped for hideAnim while closing.
      opacity: root.panelFade
      scale: 1
      // grow from the bar edge when docked, from the middle when expanded
      transformOrigin: root.panelExpanded ? Item.Center : Item.Top
      transform: Translate {
        y: root.panelOpen ? 0 : -12
        Behavior on y { NumberAnimation { duration: 230; easing.type: Easing.OutCubic } }
      }

      // chat is empty (and no menu open) → TUI-style centered prompt
      property bool empty: root.mode === "chat" && chatModel.count === 0
                           && root.menu === "" && root.pendingImages.length === 0
                           && !root.chatLoading

      // full-mode chat-history rail (see the sidebar below). It is available
      // ONLY in the large window's chat tab — the docked dropdown never gets
      // it. `sidebarOpen` is the user toggle (header button); `sidebarW` is
      // what the layout insets by, 0 while docked, collapsed or off the chat
      // tab, so every other mode keeps its original full-width layout.
      // Capped at 244px and always leaving ≥360px for the chat, so a manually
      // shrunk full window can never push the chat area negative.
      readonly property bool sidebarAvailable:
          root.panelExpanded && root.mode === "chat"
      readonly property bool sidebarVisible:
          sidebarAvailable && root.sidebarOpen
      // NOTE: writable (not readonly) so the Behavior below can animate it
      property real sidebarW:
          sidebarVisible ? Math.min(244, Math.max(0, width - 360)) : 0
      // slide the rail in/out instead of snapping; the surface size is fixed
      // so animating the internal layout is safe (unlike the window geometry)
      Behavior on sidebarW { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

      // catch-all: Escape bubbling up from any focused child of the overlay
      Keys.onEscapePressed: root.closeMenuOrPanel()

      // ----- full-mode chat history rail -----
      // Claude/ChatGPT-style: only in the big window, the panel's own chats
      // stacked by recency with a filter box and a new-chat action. The main
      // column is inset by `sidebarW`, so this rail owns the left edge.
      Rectangle {
        id: sidebar
        // stays "visible" while the rail is available so the width/opacity
        // animation is actually seen; opacity handles the open/close
        visible: panelContent.sidebarAvailable
        opacity: panelContent.sidebarVisible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        x: 0
        y: 0
        width: panelContent.sidebarW
        height: parent.height
        color: Theme.sidebar
        topLeftRadius: panelContent.radius
        bottomLeftRadius: panelContent.radius
        topRightRadius: 0
        bottomRightRadius: 0

        // hairline seam against the chat surface
        Rectangle {
          anchors.right: parent.right
          width: 1
          height: parent.height
          color: Theme.border
        }

        // new chat — full-width row, the rail's primary action
        Rectangle {
          id: newChatSide
          anchors.top: parent.top
          anchors.topMargin: 10
          anchors.left: parent.left
          anchors.leftMargin: 10
          anchors.right: parent.right
          anchors.rightMargin: 10
          height: 32
          radius: 6
          color: newSideMa.containsMouse || root.newChatPending
                 ? Theme.hover : "transparent"
          Behavior on color { ColorAnimation { duration: 150 } }
          scale: newSideMa.pressed ? 0.97 : (newSideMa.containsMouse ? 1.02 : 1)
          Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

          Row {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf067"
              font.family: Theme.font
              font.pixelSize: 11
              color: root.newChatPending ? Theme.accent : Theme.text
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "New chat"
              font.family: Theme.font
              font.pixelSize: 11
              color: root.newChatPending ? Theme.accent : Theme.text
            }
          }

          MouseArea {
            id: newSideMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.sideNewChat()
          }
        }

        // filter box
        Rectangle {
          id: sideSearchBox
          anchors.top: newChatSide.bottom
          anchors.topMargin: 10
          anchors.left: parent.left
          anchors.leftMargin: 10
          anchors.right: parent.right
          anchors.rightMargin: 10
          height: 28
          radius: 6
          color: Theme.bg
          border.color: sideSearch.activeFocus ? Theme.muted : Theme.border
          border.width: 1
          Behavior on border.color { ColorAnimation { duration: 150 } }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf002"
            font.family: Theme.font
            font.pixelSize: 10
            color: Theme.muted
          }

          TextInput {
            id: sideSearch
            anchors.left: parent.left
            anchors.leftMargin: 24
            anchors.right: sideClear.left
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            text: ""
            color: Theme.accent
            font.family: Theme.font
            font.pixelSize: 10
            selectionColor: Theme.hover
            selectedTextColor: Theme.accent
            clip: true
            onTextEdited: root.sideQuery = text
            // before the TextInput's own editing so Up/Down/Escape/Enter are
            // caught here (the rail is a real window, so it holds the keys)
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: event => {
              if (event.key === Qt.Key_Escape) {
                event.accepted = true;
                root.sideClearQuery();
                root.focusChatEditor();
              } else if (event.key === Qt.Key_Down) {
                event.accepted = true;
                sideFlick.contentY = Math.min(sideFlick.contentY + 34,
                    Math.max(0, sideList.implicitHeight - sideFlick.height));
              } else if (event.key === Qt.Key_Up) {
                event.accepted = true;
                sideFlick.contentY = Math.max(0, sideFlick.contentY - 34);
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                event.accepted = true;
                const l = root.sideFilteredSessions();
                if (l.length > 0) root.sideSwitch(l[0]);
              }
            }
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: 24
            anchors.right: sideClear.left
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            visible: sideSearch.text === ""
            text: "Search chats…"
            color: Theme.idleText
            font.family: Theme.font
            font.pixelSize: 10
            elide: Text.ElideRight
          }

          Rectangle {
            id: sideClear
            anchors.right: parent.right
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            width: 18; height: 18; radius: 4
            visible: sideSearch.text !== ""
            color: sideClearMa.containsMouse ? Theme.hover : "transparent"
            Behavior on color { ColorAnimation { duration: 150 } }

            Text {
              anchors.centerIn: parent
              text: "\uf00d"
              font.family: Theme.font
              font.pixelSize: 10
              color: sideClearMa.containsMouse ? Theme.err : Theme.muted
            }

            MouseArea {
              id: sideClearMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.sideClearQuery();
                sideSearch.forceActiveFocus();
              }
            }
          }
        }

        // history list: date section header + one row per chat
        Flickable {
          id: sideFlick
          anchors.top: sideSearchBox.bottom
          anchors.topMargin: 8
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.leftMargin: 6
          anchors.rightMargin: 4
          anchors.bottomMargin: 6
          contentWidth: width
          contentHeight: sideList.implicitHeight
          clip: true
          interactive: contentHeight > height
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: sideList
            width: sideFlick.width
            spacing: 2

            Repeater {
              model: root.sideGroups()

              Column {
                id: sideGroup
                required property var modelData
                width: sideList.width
                spacing: 1

                Text {
                  width: parent.width
                  height: 24
                  leftPadding: 8
                  verticalAlignment: Text.AlignVCenter
                  text: sideGroup.modelData.label
                  font.family: Theme.font
                  font.pixelSize: 9
                  font.bold: true
                  color: Theme.muted
                  elide: Text.ElideRight
                }

                Repeater {
                  model: sideGroup.modelData.items

                  Rectangle {
                    id: sideRow
                    required property var modelData
                    readonly property bool cur: root.session
                        && root.session.id === sideRow.modelData.id
                    readonly property bool running:
                        root.activeSessions[sideRow.modelData.id] !== undefined
                    width: sideGroup.width
                    height: 30
                    radius: 6
                    color: (sideRow.cur || sideHover.hovered
                            || sideRowMa.containsMouse)
                           ? Theme.hover : "transparent"
                    Behavior on color { ColorAnimation { duration: 150 } }
                    // slight slide-in on hover
                    property real slide: sideHover.hovered ? 2 : 0
                    transform: Translate { x: sideRow.slide }
                    Behavior on slide { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

                    // HoverHandler (not MouseArea hover) so hovering the ✕
                    // child never reports the row as un-hovered
                    HoverHandler { id: sideHover }

                    // the open chat gets an accent bar on the left
                    Rectangle {
                      visible: sideRow.cur
                      anchors.left: parent.left
                      anchors.leftMargin: 2
                      anchors.verticalCenter: parent.verticalCenter
                      width: 3; height: 16; radius: 1.5
                      color: Theme.accent
                    }

                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: 8
                      anchors.right: parent.right
                      anchors.rightMargin: sideDel.visible ? 30 : 8
                      anchors.verticalCenter: parent.verticalCenter
                      // running agents get a live dot, the open one a filled
                      // dot; untitled chats never show the raw ses_ id
                      text: (sideRow.cur ? "● " : sideRow.running ? "◌ " : "")
                            + root.sessionLabel(sideRow.modelData)
                      font.family: Theme.font
                      font.pixelSize: 10
                      font.bold: sideRow.cur
                      color: sideRow.cur ? Theme.accent
                           : sideRow.running ? Theme.live : Theme.text
                      elide: Text.ElideRight
                    }

                    MouseArea {
                      id: sideRowMa
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.sideSwitch(sideRow.modelData)
                    }

                    Rectangle {
                      id: sideDel
                      anchors.right: parent.right
                      anchors.rightMargin: 6
                      anchors.verticalCenter: parent.verticalCenter
                      width: 20; height: 20; radius: 4
                      visible: sideHover.hovered
                      color: sideDelMa.containsMouse ? Theme.hover : "transparent"
                      Behavior on color { ColorAnimation { duration: 150 } }

                      Text {
                        anchors.centerIn: parent
                        text: "\uf00d"
                        font.family: Theme.font
                        font.pixelSize: 10
                        color: sideDelMa.containsMouse ? Theme.err : Theme.muted
                      }

                      MouseArea {
                        id: sideDelMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.deleteSession(sideRow.modelData)
                      }
                    }
                  }
                }
              }
            }

            // empty rail: no chats yet, or nothing matching the filter
            Text {
              visible: root.sideFilteredSessions().length === 0
              width: sideList.width
              height: 44
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              text: root.sideQuery !== "" ? "none found" : "no chats yet"
              font.family: Theme.font
              font.pixelSize: 10
              color: Theme.muted
            }
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.margins: 10
        anchors.leftMargin: panelContent.sidebarW + 10
        anchors.bottomMargin: 0   // input row is a floating sibling below
        spacing: 8

        // ----- header -----
        Row {
          id: headerRow
          width: parent.width
          height: 26
          spacing: 8

          // history-rail toggle: only exists in the big window's chat tab, so
          // it is the open/close control for `root.sidebarOpen` (hidden while
          // docked, where the rail is never available)
          Rectangle {
            id: sidebarBtn
            anchors.verticalCenter: parent.verticalCenter
            visible: root.panelExpanded && root.mode === "chat"
            width: 24; height: 20; radius: 5
            color: sidebarMa.containsMouse ? Theme.hover : "transparent"
            Behavior on color { ColorAnimation { duration: 200 } }
            scale: sidebarMa.pressed ? 0.86 : (sidebarMa.containsMouse ? 1.04 : 1)
            Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

            Text {
              anchors.centerIn: parent
              text: "\uf0c9"          // bars — open/close the history rail
              font.family: Theme.font
              font.pixelSize: 12
              color: root.sidebarOpen ? Theme.accent : Theme.muted
            }

            MouseArea {
              id: sidebarMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.sidebarOpen = !root.sidebarOpen
            }
          }

          // central tabs: chat / translate / calculator.
          // Hidden in full mode — that window is chat-only.
          Item {
            id: tabWrap
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.panelExpanded
            width: tabRow.width
            height: 20

            // sliding highlight behind the active tab (segmented-control feel)
            Rectangle {
              id: tabIndicator
              width: 24; height: 20; radius: 5
              color: Theme.hover
              x: (root.mode === "chat" ? 0
                  : root.mode === "translate" ? 1 : 2) * (width + tabRow.spacing)
              Behavior on x { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
            }

            Row {
              id: tabRow
              spacing: 4

              Repeater {
                model: [
                  { id: "chat", icon: "󰆍" },
                  { id: "translate", icon: "\uf1ab" },
                  { id: "calc", icon: "\uf1ec" },
                ]

                delegate: Rectangle {
                  required property var modelData

                  readonly property bool cur: root.mode === modelData.id
                  width: 24; height: 20; radius: 5
                  // the sliding indicator draws the active background; the
                  // delegate only tints on hover
                  color: tabMa.containsMouse ? Theme.hover : "transparent"
                  Behavior on color { ColorAnimation { duration: 200 } }
                  scale: tabMa.pressed ? 0.88 : (cur ? 1 : (tabMa.containsMouse ? 1.06 : 1))
                  Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                  Text {
                    anchors.centerIn: parent
                    text: parent.modelData.icon
                    font.family: Theme.font
                    font.pixelSize: 12
                    color: parent.cur ? Theme.accent : Theme.muted
                    Behavior on color { ColorAnimation { duration: 200 } }
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
          }

          // session title — click for the session list. Width accounts for
          // every sibling (incl. the stop button, which appears mid-turn)
          // so the header never overflows the panel edge
          Text {
            id: titleText
            anchors.verticalCenter: parent.verticalCenter
            visible: root.mode === "chat"
            width: parent.width - (tabRow.visible ? tabRow.width : 0)
                   - costText.width
                   - modelBtn.width - agentBtn.width
                   - 56
                   - (sidebarBtn.visible ? sidebarBtn.width + 8 : 0)
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
            scale: modelMa.pressed ? 0.95 : (modelMa.containsMouse ? 1.05 : 1)
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            Text {
              id: modelText
              anchors.centerIn: parent
              // friendly model name (with the reasoning variant), never the raw
              // id when the picker knows it
              text: root.modelChipLabel()
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
            scale: agentMa.pressed ? 0.95 : (agentMa.containsMouse ? 1.05 : 1)
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            Text {
              id: agentText
              anchors.centerIn: parent
              // friendly agent name, not the raw id
              text: root.agentChipLabel()
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
        // A ListView, not a Repeater in a Column: a Repeater instantiates a
        // delegate for EVERY row of the model, and each row carries several
        // selectable TextEdits (rich-text markdown, colored diffs, tool I/O).
        // With a long chat that is thousands of live TextEdits, held resident
        // even while the panel is closed (~600MB here). A ListView only keeps
        // the visible rows (+ cacheBuffer) alive.
        Item {
          id: chatArea
          transform: Translate { x: root.swipeOfs }
          width: parent.width
          height: root.mode === "chat"
              ? parent.height - headerRow.height - menuBox.height
                - errorLine.height - permBanner.height - formBanner.height
                - inputRow.height - 10
                // Column spacing only applies between VISIBLE children; the
                // old hardcoded 8*5 reserved four gaps that are hidden in the
                // normal case, leaving ~32px of dead space above the input
                - 8 * (1 + (errorLine.visible ? 1 : 0) + (menuBox.visible ? 1 : 0)
                       + (permBanner.visible ? 1 : 0) + (formBanner.visible ? 1 : 0))
              : 0

          ListView {
            id: chatView
            // hug the bottom: while the history fits it shrinks to the content
            // and sits at the bottom; past that it fills the area and scrolls
            anchors.bottom: parent.bottom
            width: parent.width
            // contentHeight can depend on the viewport (delegate sizes are
            // estimated until laid out), so binding height straight to it
            // makes Qt report a binding loop. Read it into a plain property
            // on contentHeightChanged instead — that breaks the cycle.
            property real wantedHeight: 0
            height: Math.min(parent.height, wantedHeight)
            clip: true
            spacing: 8
            model: chatModel

            // hidden while history loads, so the chunked rebuild is not seen
            // as content assembling itself; it fades in once complete
            opacity: root.chatLoading ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

            // chat flow: messages hug the bottom; history scrolls up.
            // `rebuilding` guards pinned: during a model rebuild contentY is
            // clamped (contentHeight collapses), which must NOT flip pinned
            property bool pinned: true

            // A ListView's contentHeight is only an ESTIMATE until every
            // delegate is created (and can overshoot the real end by a lot),
            // so "at the end" must come from atYEnd, which Qt computes from
            // the laid-out content. Computing it as contentY >= contentHeight
            // - height said "not at the end" while the last row was visibly
            // flush at the bottom — that un-pinned us and lit the jump button.
            onContentYChanged: {
              if (root.rebuilding) return;
              if (atYEnd) pinned = true;                   // truly at the end
              else if (flicking || dragging) pinned = false;  // user scrolled up
            }
            onMovementStarted: if (!root.rebuilding) pinned = atYEnd
            onMovementEnded: if (!root.rebuilding) pinned = atYEnd
            onFlickStarted: if (!root.rebuilding) pinned = atYEnd
            onFlickEnded: if (!root.rebuilding) pinned = atYEnd
            onContentHeightChanged: {
              wantedHeight = contentHeight;
              if (pinned) Qt.callLater(stick);
            }

            // positionViewAtEnd() forces the LAST delegate into existence and
            // lands on the REAL end (contentY = contentHeight - height would
            // overshoot into the estimate's empty tail).
            function stick() {
              if (!pinned) return;
              positionViewAtEnd();
            }

            delegate: Item {
              id: msgDel
              required property string key
              required property string kind
              required property string text
              required property string name
              required property string state
              // already pretty-printed JSON (normalised in loadMessages);
              // see toolInputText for why it is not kept as an object
              required property string toolIn
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

                // soft pulse behind the assistant message that is streaming,
                // so the "live" one is obvious at a glance
                Rectangle {
                  visible: msgDel.kind === "assistant" && msgDel.live
                  anchors.fill: parent
                  radius: 8
                  color: Theme.surface
                  opacity: 0.08
                  SequentialAnimation on opacity {
                    running: visible
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.32; duration: 750; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 0.08; duration: 750; easing.type: Easing.InOutSine }
                  }
                }

                // invisible measure: TextEdit has no content-hugging width,
                // this sizes the user bubble
                Text {
                  id: userMeasure
                  visible: false
                  width: Math.min(chatView.width - 60, implicitWidth)
                  text: msgDel.text
                  textFormat: Text.PlainText
                  font.family: Theme.font
                  font.pixelSize: 13
                }

                SelText {
                  id: userText
                  visible: msgDel.kind === "user"
                  anchors.centerIn: parent
                  width: userMeasure.width
                  height: contentHeight
                  text: msgDel.text
                  textFormat: TextEdit.PlainText
                  font.pixelSize: 13
                  onSelectedTextChanged: if (selectedText !== "") root.selEdit = userText
                  Component.onDestruction: if (root.selEdit === userText) root.selEdit = null
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
                  font.pixelSize: 13
                  color: Theme.accent
                  onSelectedTextChanged: if (selectedText !== "") root.selEdit = asstText
                  Component.onDestruction: if (root.selEdit === asstText) root.selEdit = null
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
                    text: msgDel.open ? msgDel.toolIn : ""
                    textFormat: TextEdit.PlainText
                    font.pixelSize: 9
                    color: Theme.idleText
                    onSelectedTextChanged: if (selectedText !== "") root.selEdit = toolInEdit
                    Component.onDestruction: if (root.selEdit === toolInEdit) root.selEdit = null
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
                    Component.onDestruction: if (root.selEdit === reasoningEdit) root.selEdit = null
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
                    Component.onDestruction: if (root.selEdit === diffEdit) root.selEdit = null
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
                    Component.onDestruction: if (root.selEdit === toolOutEdit) root.selEdit = null
                    onCopied: root.showCopyToast()
                  }
                }
              }
            }

            // a little robot hard at work while the assistant turn streams.
            // Its expression reflects the turn: a hammer for text, a wrench
            // while a tool runs, and a dead red robot on error.
            footer: Item {
              id: workerScene
              // stays up while a turn runs, and while an error is showing so
              // the dead robot is actually seen
              visible: root.busy || root.error !== ""
              width: chatView.width
              height: 20
              readonly property bool errored: root.error !== ""

              // spinning cog
              Text {
                id: cog
                x: 34; y: 5
                text: "󰒓"
                font.family: Theme.font
                font.pixelSize: 12
                color: workerScene.errored ? Theme.err : Theme.muted
                opacity: workerScene.errored ? 0.45 : 1
                Behavior on opacity { NumberAnimation { duration: 200 } }
                transformOrigin: Item.Center
                NumberAnimation on rotation {
                  running: root.busy && !workerScene.errored
                  loops: Animation.Infinite
                  from: 0; to: 360; duration: 2800
                }
              }

              // the little robot, bobbing (dead + still on error)
              Text {
                id: robot
                x: 8; y: 4
                text: workerScene.errored ? "󱚡" : "󰚩"
                font.family: Theme.font
                font.pixelSize: 14
                color: workerScene.errored ? Theme.err : Theme.live
                Behavior on color { ColorAnimation { duration: 200 } }
                property real bob: 0
                transform: Translate { y: robot.bob }
                SequentialAnimation on bob {
                  running: root.busy && !workerScene.errored
                  loops: Animation.Infinite
                  NumberAnimation { to: -2.5; duration: 300; easing.type: Easing.OutQuad }
                  NumberAnimation { to: 0; duration: 300; easing.type: Easing.InQuad }
                  PauseAnimation { duration: 180 }
                }
              }

              // the tool: a hammer for text, a wrench while a tool runs
              Text {
                id: hammer
                x: 18; y: 1
                text: root.toolRunning ? "󰖷" : "󰣪"
                font.family: Theme.font
                font.pixelSize: 12
                color: root.toolRunning ? Theme.accent2 : Theme.accent
                visible: !workerScene.errored
                transformOrigin: Item.BottomLeft
                SequentialAnimation on rotation {
                  running: root.busy && !workerScene.errored
                  loops: Animation.Infinite
                  NumberAnimation { to: -32; duration: 240; easing.type: Easing.OutCubic }
                  NumberAnimation { to: 14; duration: 180; easing.type: Easing.InCubic }
                  PauseAnimation { duration: 260 }
                }
              }

              // sparks fly on each hit
              Text {
                id: spark
                x: 26; y: 9
                text: "󰶳"
                font.family: Theme.font
                font.pixelSize: 9
                color: Theme.live
                visible: !workerScene.errored
                opacity: 0
                SequentialAnimation on opacity {
                  running: root.busy && !workerScene.errored
                  loops: Animation.Infinite
                  PauseAnimation { duration: 420 }
                  NumberAnimation { to: 1; duration: 70 }
                  NumberAnimation { to: 0; duration: 150 }
                  PauseAnimation { duration: 320 }
                }
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
              ? Math.min(root.panelExpanded ? 400 : 260, menuCol.implicitHeight + 12) : 0
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
                // rows are 24px + 2px spacing, preceded by the 18px finder
                // header — the old math ignored the header and used 26 as the
                // row height, scrolling the selection out of alignment
                const rowH = 26, headerH = 18, rowInner = 24;
                const top = headerH + root.fileSel * rowH;
                const bottom = top + rowInner;
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

            // reasoning effort (model variants) for the active model. Kept at
            // the top of the model list so it is visible without scrolling.
            Row {
              visible: root.menu === "models" && root.currentVariants().length > 0
              width: menuCol.width - 4
              height: 26
              spacing: 4

              Text {
                text: "effort"
                height: parent.height
                verticalAlignment: Text.AlignVCenter
                font.family: Theme.font
                font.pixelSize: 9
                color: Theme.muted
              }

              Repeater {
                model: root.menu === "models" ? root.currentVariants() : []

                Item {
                  required property var modelData
                  width: vLabel.implicitWidth + 16
                  height: parent.height

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: 20
                    radius: 4
                    color: root.currentVariant() === modelData ? Theme.accent
                         : vMa.containsMouse ? Theme.hover : Theme.bg
                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                      id: vLabel
                      anchors.centerIn: parent
                      text: modelData
                      font.family: Theme.font
                      font.pixelSize: 9
                      color: root.currentVariant() === modelData ? Theme.deep : Theme.text
                    }
                  }

                  MouseArea {
                    id: vMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.switchVariant(modelData)
                  }
                }
              }
            }

            // file finder: header that doubles as the loading/empty state
            // (the menu is never a blank box) + the result rows
            Text {
              visible: root.menu === "files"
              width: menuCol.width - 4
              height: root.menu === "files" ? 18 : 0
              leftPadding: 8
              verticalAlignment: Text.AlignVCenter
              text: root.finderBusy ? "\uf002  buscando…"
                  : root.fileHits.length === 0
                    ? "\uf002  nenhum arquivo — tente outro nome"
                    : "\uf002  " + root.fileHits.length
                      + (root.fileHits.length === 1 ? " resultado" : " resultados")
                      + "  ·  ↑↓ · Enter"
              font.family: Theme.font
              font.pixelSize: 9
              color: root.finderBusy ? Theme.live : Theme.muted
              elide: Text.ElideRight
            }

            Repeater {
              model: root.menu === "files" ? root.fileHits : []

              Rectangle {
                id: fileRow
                required property var modelData
                required property int index
                readonly property bool sel: index === root.fileSel
                readonly property bool dir: modelData.type === "directory"
                width: menuCol.width - 4
                height: 24
                radius: 4
                color: sel ? Theme.hover
                     : fileMa.containsMouse ? Theme.hover : "transparent"
                scale: fileMa.pressed ? 0.97 : 1
                Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: 150 } }
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.right: fileRow.dir ? kindText.left : parent.right
                  anchors.rightMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  text: (fileRow.dir ? "\uf07b  " : "\uf15b  ") + fileRow.modelData.path
                  font.family: Theme.font
                  font.pixelSize: 10
                  color: fileRow.sel ? Theme.accent : Theme.text
                  elide: Text.ElideMiddle
                }
                // directories only: picking one keeps the finder open, so say so
                Text {
                  id: kindText
                  anchors.right: parent.right
                  anchors.rightMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  visible: fileRow.dir
                  text: "pasta"
                  font.family: Theme.font
                  font.pixelSize: 9
                  color: fileRow.sel ? Theme.muted : Theme.idleText
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
                scale: sesMa.pressed ? 0.97 : 1
                Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
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

            // models menu (searchable): grouped by provider, with capability /
            // cost cues and a fixed check column on the active model
            Repeater {
              id: modelsRep
              model: root.modelGroups()

              Column {
                id: modelGroup
                required property var modelData
                width: menuCol.width - 4
                spacing: 2

                // provider section header
                Text {
                  width: parent.width
                  height: 24
                  leftPadding: 8
                  verticalAlignment: Text.AlignVCenter
                  text: modelGroup.modelData.provider
                  font.family: Theme.font
                  font.pixelSize: 9
                  font.bold: true
                  color: Theme.muted
                  elide: Text.ElideRight
                }

                Repeater {
                  model: modelGroup.modelData.items

                  Rectangle {
                    id: modRow
                    required property var modelData   // { m: model, i: flat index }
                    readonly property var entry: modRow.modelData.m
                    readonly property int flatIndex: modRow.modelData.i
                    readonly property bool cur: root.session && root.session.model
                        && root.session.model.id === modRow.entry.id
                        && root.session.model.providerID === modRow.entry.providerID
                    width: modelGroup.width
                    height: 34
                    radius: 4
                    color: (modRow.flatIndex === root.menuSel || modMa.containsMouse)
                           ? Theme.hover : "transparent"
                    scale: modMa.pressed ? 0.98 : 1
                    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                    Column {
                      anchors.left: parent.left
                      anchors.leftMargin: 8
                      anchors.right: modCheck.left
                      anchors.rightMargin: 6
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: 1

                      Text {
                        width: parent.width
                        text: modRow.entry.name
                        font.family: Theme.font
                        font.pixelSize: 10
                        font.bold: modRow.cur
                        color: modRow.cur ? Theme.accent : Theme.text
                        elide: Text.ElideRight
                      }
                      Text {
                        width: parent.width
                        text: root.modelMeta(modRow.entry)
                        font.family: Theme.font
                        font.pixelSize: 8
                        color: Theme.muted
                        elide: Text.ElideRight
                      }
                    }

                    // fixed-width check column so rows never shift
                    Text {
                      id: modCheck
                      anchors.right: parent.right
                      anchors.rightMargin: 8
                      anchors.verticalCenter: parent.verticalCenter
                      width: 12
                      horizontalAlignment: Text.AlignHCenter
                      text: modRow.cur ? "✓" : ""
                      font.family: Theme.font
                      font.pixelSize: 11
                      color: Theme.accent
                    }

                    MouseArea {
                      id: modMa
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onEntered: root.menuSel = modRow.flatIndex
                      onClicked: root.switchModel(modRow.entry)
                    }
                  }
                }
              }
            }

            // agents menu (searchable): name + description, active check
            Repeater {
              id: agentsRep
              model: root.filteredAgents()

              Rectangle {
                id: agRow
                required property var modelData
                required property int index
                readonly property bool cur: root.session && root.session.agent === agRow.modelData.id
                width: menuCol.width - 4
                height: 36
                radius: 4
                color: (index === root.menuSel || agMa.containsMouse)
                       ? Theme.hover : "transparent"
                scale: agMa.pressed ? 0.98 : 1
                Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                Column {
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.right: agCheck.left
                  anchors.rightMargin: 6
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 1

                  Text {
                    width: parent.width
                    text: agRow.modelData.name
                    font.family: Theme.font
                    font.pixelSize: 10
                    font.bold: agRow.cur
                    color: agRow.cur ? Theme.accent : Theme.text
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    visible: agRow.modelData.description !== ""
                    text: agRow.modelData.description
                    font.family: Theme.font
                    font.pixelSize: 8
                    color: Theme.muted
                    elide: Text.ElideRight
                  }
                }

                // fixed-width check column so rows never shift
                Text {
                  id: agCheck
                  anchors.right: parent.right
                  anchors.rightMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  width: 12
                  horizontalAlignment: Text.AlignHCenter
                  text: agRow.cur ? "✓" : ""
                  font.family: Theme.font
                  font.pixelSize: 11
                  color: Theme.accent
                }

                MouseArea {
                  id: agMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.menuSel = index
                  onClicked: root.switchAgent(agRow.modelData)
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
                scale: cmdMa.pressed ? 0.97 : 1
                Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
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
                     && root.menuCount() === 0
              width: menuCol.width - 4
              height: 24
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              text: "no matches"
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
      // Docked to the panel's bottom edge (anchors.bottom), so a growing
      // draft expands UPWARD and the chat above it shrinks — chatView's
      // height subtracts inputRow.height, keeping the two from overlapping.
      // An empty chat lifts the row toward the middle (TUI-style centered
      // prompt) via `lift`, a visual-only Translate: `y` stays the docked
      // value so the floating siblings can still anchor to it.
      Rectangle {
        id: inputRow
        // full width while chatting; capped + centered while empty
        // (chatbot-style narrow prompt). Both are inset by the full-mode
        // history rail so they never slide under it.
        width: panelContent.empty
               ? Math.min(parent.width - panelContent.sidebarW - 20, 640)
               : parent.width - panelContent.sidebarW - 20
        x: panelContent.empty
           ? panelContent.sidebarW
             + (parent.width - panelContent.sidebarW - width) / 2
           : panelContent.sidebarW + 10
        Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        visible: root.mode === "chat"
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 10
        height: Math.max(38, Math.min(158, inputField.height + 18))
        // where the row should sit: middle when empty, docked otherwise
        readonly property real targetY: panelContent.empty
            ? 44 + (parent.height - 120 - (height - 38)) / 2
            : parent.height - 10 - height
        // extra vertical offset on top of the docked position; 0 when docked
        property real lift: targetY - (parent.height - 10 - height)
        // visual position (docked y + lift): what the siblings must follow
        readonly property real visualY: y + lift
        Behavior on lift { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        transform: Translate { x: root.swipeOfs; y: inputRow.lift }
        radius: 6
        color: Theme.surface
        border.color: inputField.activeFocus || hiddenInput.activeFocus
                     ? Theme.muted : Theme.border
        border.width: 1

        TextEdit {
          id: inputField
          anchors.left: parent.left
          anchors.leftMargin: 10
          anchors.right: pasteBtn.left
          anchors.rightMargin: 4
          // verticalCenter keeps a one-line draft at the row's middle; as it
          // grows the row grows with it (inputRow.height binds here) so the
          // field only ever fills the space it is given
          anchors.verticalCenter: parent.verticalCenter
          // Grows with the draft but never past the room it is given;
          // wrapMode keeps long lines inside the box instead of escaping it
          // (the old TextField never grew, so a long draft scrolled away on
          // a single invisible line). Past the cap the field scrolls itself
          // with the caret (see ensureCaretVisible).
          //
          // NB: a plain TextEdit top-aligns its text inside its own height,
          // so the height must equal the content's own height for the row's
          // verticalCenter above to actually centre the text/placeholder.
          // A fixed floor here (the old Math.max(20, …)) made a one-line
          // draft 20px tall inside a 38px row and drew it ~4px above the
          // middle, which is what pushed the placeholder off-centre.
          height: Math.min(contentHeight, 120)
          textFormat: TextEdit.PlainText
          color: Theme.accent
          font.family: Theme.font
          font.pixelSize: 12
          selectionColor: Theme.hover
          selectedTextColor: Theme.accent
          // disabled while a search menu owns the keyboard (it shows the
          // parked draft, dimmed)
          enabled: !root.busy && !root.sending && !root.menuSearchOpen
          // the Controls TextEdit defaults to WrapAnywhere; Wrap breaks on
          // word boundaries and still keeps long tokens inside the box
          wrapMode: TextEdit.Wrap
          // while the draft is longer than the box the caret must stay in
          // view — the bar's hiddenInput has no scrolling of its own.
          // `TextEdit.contentY` is read-only on a Controls TextEdit, so the
          // attached Flickable property is the one to move.
          function ensureCaretVisible() {
            if (contentHeight <= height) { Flickable.contentY = 0; return; }
            const r = cursorRectangle;
            if (r.y < Flickable.contentY) Flickable.contentY = Math.max(0, r.y - 2);
            else if (r.y + r.height > Flickable.contentY + height)
              Flickable.contentY = Math.min(contentHeight - height,
                                            r.y + r.height - height + 2);
          }
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
          // TextEdit has no placeholder of its own — draw the same hint the
          // old TextField showed, only while the draft is empty
          Text {
            anchors.fill: parent
            text: root.formTextTarget !== null
                ? "answer: " + root.formTextTarget.title + " …"
                : root.sttState === "rec"
                ? "● recording " + Math.floor(root.recSecs / 60) + ":"
                  + String(root.recSecs % 60).padStart(2, "0")
                  + " — mic again to stop"
                : root.sttState === "stt" ? "◌ transcribing…"
                : root.busy ? "opencode is working…"
                : "ask opencode…  (@file · /command · Ctrl+V image)"
            visible: inputField.text === ""
            color: Theme.idleText
            font.family: Theme.font
            font.pixelSize: 12
            elide: Text.ElideRight
          }
          onTextChanged: if (!root.inputSyncing) {
            root.inputSyncing = true;
            hiddenInput.text = text;
            root.inputSyncing = false;
            // typing straight into the popup field (the user clicked it, so
            // the compositor moved the keyboard here) must drive the @file /
            // slash menus too — the bar's hiddenInput is not the only path
            if (root.mode === "chat" && !root.menuSearchOpen) root.updateFinder();
          }
          onCursorPositionChanged: if (!root.inputSyncing) {
            root.inputSyncing = true;
            hiddenInput.cursorPosition = cursorPosition;
            root.inputSyncing = false;
          }
          // the caret moves as the mirror from the bar's editor updates, and
          // after send()/newChat() clear the field
          onContentHeightChanged: ensureCaretVisible()
          onCursorRectangleChanged: ensureCaretVisible()
          // arrows move the open @file / search menu selection. This surface
          // may hold the keyboard after a click into the popup (where the
          // bar's hiddenInput — the other nav path — does not receive keys),
          // so it has to handle them itself. BeforeItem so the caret does not
          // eat the event first; unhandled keys fall through to the caret.
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: event => {
            // Ctrl+N: new chat; Ctrl+M: model picker; Ctrl+V: clipboard image
            // / text paste; Up/Down: menu navigation. This field owns the
            // keyboard in full mode (hiddenInput is unfocused there), so the
            // handlers that live on hiddenInput are repeated here. Up/Down are
            // handled in this generic handler (not Keys.onUpPressed) so they
            // never race the specific key handlers.
            if (root.mode === "chat" && root.formTextTarget === null
                && event.key === Qt.Key_N
                && (event.modifiers & Qt.ControlModifier)) {
              root.newChat();
              event.accepted = true;
            } else if (root.mode === "chat" && event.key === Qt.Key_M
                && (event.modifiers & Qt.ControlModifier)) {
              root.menu === "models" ? root.closeMenu() : root.openMenu("models");
              event.accepted = true;
            } else if (root.mode === "chat" && root.formTextTarget === null
                && event.key === Qt.Key_V
                && (event.modifiers & Qt.ControlModifier)) {
              root.pasteFromClipboard(true);
              event.accepted = true;
            } else if ((event.key === Qt.Key_Down || event.key === Qt.Key_Up)
                && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier))) {
              const dir = event.key === Qt.Key_Down ? 1 : -1;
              if (root.menuSearchable()) { root.menuMove(dir); event.accepted = true; }
              else if (root.menu === "files" && root.fileHits.length > 0) {
                root.finderMove(dir); event.accepted = true;
              }
            }
          }
          // Enter sends / Shift+Enter newline, in case this surface holds the
          // keyboard (after a click into the popup) instead of the bar's editor
          Keys.onReturnPressed: event => root.handleReturnKey(event)
          Keys.onEnterPressed: event => root.handleReturnKey(event)
          Keys.onEscapePressed: event => {
            event.accepted = true;
            if (root.formCancelText()) return;
            root.closeMenuOrPanel();
          }
        }

        // attach clipboard image
        Rectangle {
          id: pasteBtn
          anchors.right: micBtn.left
          anchors.rightMargin: 4
          anchors.top: parent.top
          anchors.topMargin: 6
          width: 28; height: 26; radius: 5
          color: pasteMa.containsMouse ? Theme.hover : Theme.bg
          Behavior on color { ColorAnimation { duration: 200 } }
          scale: pasteMa.pressed ? 0.86 : (pasteMa.containsMouse ? 1.07 : 1)
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
          anchors.top: parent.top
          anchors.topMargin: 6
          width: 28; height: 26; radius: 5
          color: micMa.containsMouse && root.sttState === "idle"
                 ? Theme.hover : Theme.bg
          Behavior on color { ColorAnimation { duration: 200 } }
          scale: micMa.pressed ? 0.86 : (micMa.containsMouse ? 1.07 : 1)
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
          // pinned to the top-right of the row, not centered: a grown input
          // row must keep the buttons at the first text line
          anchors.top: parent.top
          anchors.topMargin: 6
          width: 28; height: 26; radius: 5
          // light up only when there is actually something to send
          readonly property bool canSend: !root.busy && !root.sending
              && (inputField.text.trim() !== "" || root.pendingImages.length > 0)
          color: sendMa.containsMouse ? Theme.hover
               : (canSend ? Theme.surface : Theme.bg)
          Behavior on color { ColorAnimation { duration: 200 } }
          scale: sendMa.pressed ? 0.86 : (sendMa.containsMouse ? 1.07 : (canSend ? 1.03 : 1))
          Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
          Text {
            anchors.centerIn: parent
            text: root.busy || root.sending ? "\uf04d" : "➤"
            font.family: Theme.font
            font.pixelSize: 12
            color: root.busy || root.sending ? Theme.err
                 : (sendBtn.canSend ? Theme.live : Theme.muted)
            Behavior on color { ColorAnimation { duration: 200 } }
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
      // own wrapping Row: with the input row grown by a multi-line draft the
      // chips would otherwise run off the panel's left edge
      Flickable {
        id: imageChips
        transform: Translate { x: root.swipeOfs }
        x: inputRow.x
        width: inputRow.width
        y: inputRow.visualY - 34
        height: 28
        contentWidth: chipsRow.implicitWidth
        contentHeight: height
        clip: true
        interactive: contentWidth > width
        opacity: visible ? 1 : 0
        visible: root.mode === "chat" && root.pendingImages.length > 0
                 && root.menu === ""
        Behavior on y { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        Row {
          id: chipsRow
          spacing: 6

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
      }

      // ----- empty state (TUI-style) -----
      Item {
        id: emptyState
        transform: Translate { x: root.swipeOfs }
        x: panelContent.sidebarW + 10
        width: parent.width - panelContent.sidebarW - 20
        // sits just above the input row's VISUAL top (visualY accounts for
        // the empty-state lift), so a grown draft never overlaps it
        y: panelContent.empty
           ? Math.max(headerRow.height + 12, inputRow.visualY - height - 6)
           : inputRow.visualY
        height: 120
        visible: panelContent.empty
        opacity: panelContent.empty ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        Column {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 8

          Text {
            id: emptyIcon
            anchors.horizontalCenter: parent.horizontalCenter
            // gentle float so the empty state feels alive
            property real bob: 0
            transform: Translate { y: emptyIcon.bob }
            SequentialAnimation on bob {
              running: panelContent.empty
              loops: Animation.Infinite
              NumberAnimation { to: -7; duration: 1700; easing.type: Easing.InOutSine }
              NumberAnimation { to: 0; duration: 1700; easing.type: Easing.InOutSine }
            }
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
        anchors.horizontalCenterOffset: panelContent.sidebarW / 2
        y: inputRow.visualY - inputRow.height - 18
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
          anchors.fill: parent
          visible: root.mode === "calc"
          panelActive: root.panelOpen && root.mode === "calc"
          // popup field edited directly (compositor focus moved there in full
          // mode) → mirror back into the bar's real editor
          onDraftChanged: if (root.mode === "calc" && !root.inputSyncing) {
            root.inputSyncing = true;
            hiddenInput.text = calcBox.draft;
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
      }

      // ----- jump to latest -----
      // floats over the chat, above the input row; shown once the user
      // scrolled away from the bottom (pinned went false)
      Rectangle {
        id: jumpBtn
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 12
        anchors.bottomMargin: inputRow.height + 16   // clears a grown input row
        z: 5
        visible: opacity > 0
        // springy entrance/exit
        property bool shown: !chatView.pinned && root.panelOpen && root.mode === "chat"
        opacity: shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        scale: shown ? 1 : 0.6
        Behavior on scale { NumberAnimation { duration: 280; easing.type: Easing.OutBack } }
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
        anchors.horizontalCenterOffset: panelContent.sidebarW / 2
        anchors.bottom: parent.bottom
        anchors.bottomMargin: inputRow.height + 14
        z: 10
        width: toastText.implicitWidth + 20
        height: 22
        radius: 5
        color: Theme.surface
        border.color: Theme.border
        border.width: 1
        opacity: toastTimer.running ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        // slide up + pop in instead of a plain fade
        property real rise: toastTimer.running ? 0 : 12
        transform: Translate { y: copyToast.rise }
        Behavior on rise { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        property real pop: toastTimer.running ? 1 : 0.85
        scale: pop
        Behavior on pop { NumberAnimation { duration: 240; easing.type: Easing.OutBack } }

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
  // Gated on panelOpen: two enabled application-scoped Escape shortcuts would
  // be treated as ambiguous and neither would fire (the launcher has one too,
  // enabled only while it is open). The standalone instance is a real focused
  // window and handles Escape through its own Keys handlers, and the bar's
  // shortcut is disabled while the standalone is open (Notifs.opencodeFullOpen)
  // so the two never collide.
  Shortcut {
    sequence: "Escape"
    context: Qt.ApplicationShortcut
    enabled: root.panelOpen && !root.standalone && !Notifs.opencodeFullOpen
    onActivated: root.closeMenuOrPanel()
  }

  // A standalone instance opens straight into full mode and never uses the
  // docked dropdown or the pill. Called by shell.qml's toggle/open.
  function openStandalone() {
    root.ensureService();
    root.openExpanded();
  }

  // re-fetch the list once the shared store has loaded (the first loadSession
  // may run before the remembered ids are read, which would filter everything
  // out). The current chat is NOT mirrored across panels.
  Connections {
    target: OpencodeShared
    function onPanelSessionsLoadedChanged() {
      if (OpencodeShared.panelSessionsLoaded) root.loadSession();
    }
  }

  onPanelOpenChanged: {
    // let the bar's docked panel know the standalone is up (Escape coordination)
    if (root.standalone) Notifs.opencodeFullOpen = root.panelOpen;
    if (panelOpen) {          // open: cancel any pending close so the
      hideAnim.stop();        // fade-in plays from fully transparent
      hideAnimFx.stop();
      // Reset the mode BEFORE the first paint. The window is not on screen
      // yet, so the reset is a snap and never flashes a move; SUPER+SHIFT+A
      // asks for expanded via pendingExpanded.
      const wantExpanded = root.pendingExpanded;
      root.pendingExpanded = false;
      // full mode is chat-only; opening straight into it (SUPER+SHIFT+A)
      // must not carry a translate/calc tab over
      if (wantExpanded && root.mode !== "chat") root.mode = "chat";
      root.panelExpanded = wantExpanded;
      panelContent.parent = wantExpanded ? fullWin.contentItem : panel.contentItem;
      panel.applyTargetCenter();
      root.panelFade = 0;
      showAnim.restart();     // fade + scale in
      panelShown();           // connect + reload (also on a rapid reopen,
      return;                 // where PopupWindow.visible never changed)
    }
    hideAnim.restart();       // close: keep mapped while fading out
    if (root.panelExpanded) fullHideAnim.restart();   // ...the floating window too
    showAnim.stop();
    hideAnimFx.restart();     // fade + scale out
    root.closeMenu();
    activePoll.stop();
    // the SSE stream deliberately keeps running while closed: it feeds the
    // "turn finished" desktop notification and keeps the model warm
    // NOTE: the size/mode is NOT reset here — the panel fades out at the size
    // it has, and the reset is snapped invisibly on the next open.
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
                     : mode === "calc" ? calcBox.draft
                     : inputField.text;
    root.inputSyncing = false;
    if (panelOpen) root.focusPanelField();
  }

  // fallback polling when the SSE stream is not delivering. It runs whenever
  // the panel is open and there is no stream — not only mid-turn — so a stream
  // that never connected (or died silently) can never leave the chat frozen
  // until the panel is reopened. Fast while a turn is in flight, slow when idle.
  Timer {
    interval: (root.busy || root.sending) ? 60 : 1200
    repeat: true
    running: root.panelOpen && !root.streamLive
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
      // end a stalled turn locally. `turnStartMs === 0` covers busy set by
      // message reconciliation with no observed `execution.started` (the
      // panel was reopened on a session left mid-turn) — that state could
      // otherwise never satisfy `turnStartMs > execEndMs`.
      if (root.busy && (root.turnStartMs > root.execEndMs || root.turnStartMs === 0)
          && Date.now() - root.lastChangeMs > 60000) {
        root.execEndMs = Date.now();
        root.busy = false;
      }
    }
  }

  // chat model: SSE deltas update individual items incrementally.
  //
  // ListModel pins each role's type from the first value it sees and then
  // refuses (or drops) later writes of another type, so every row is passed
  // through modelRow() — which coerces to the pinned types — instead of being
  // appended raw. Roles: all strings except `live`.
  ListModel { id: chatModel }
}
