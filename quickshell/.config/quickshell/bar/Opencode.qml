import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls.Basic

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
//   GET  /api/session                             list (newest first)
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
  property string menu: ""        // "" | "sessions" | "models" | "agents" | "commands" | "files"

  // ---------- service ----------
  property string svcUrl: ""
  property string svcPw: ""
  property bool svcUp: false
  property int svcTries: 0

  // ---------- chat state ----------
  property var session: null      // Session.Info or null
  property var sessionList: []
  property var agents: []
  property var models: []
  property var commands: []
  property var fileHits: []
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
  property string sseBuf: ""
  property string rawBuf: ""

  // keep plain XMLHttpRequest objects alive while a request is in flight
  property var inflight: []

  // ---------- Pomodoro palette ----------
  readonly property color cBg: "#161719"
  readonly property color cBorder: "#282a2e"
  readonly property color cSurface: "#1e2126"
  readonly property color cHover: "#282c33"
  readonly property color cText: "#a9afb8"
  readonly property color cMuted: "#5c6470"
  readonly property color cAccent: "#d3d9e0"
  readonly property color cDark: "#101216"
  readonly property color cLive: "#a6e3a1"
  readonly property color cIdleText: "#585f68"

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
    x.setRequestHeader("Authorization", "Basic " + Qt.btoa("opencode:" + root.svcPw));
    x.setRequestHeader("Content-Type", "application/json");
    x.send(body === null ? null : JSON.stringify(body));
  }

  // ---------- SSE stream ----------
  function connectStream() {
    if (root.svcUrl === "" || !root.panelOpen) return;
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

  function restartStream() {
    sseProc.running = false;
    connectStream();
  }

  function stopStream() {
    sseProc.running = false;
    root.streamLive = false;
  }

  function streamLine(chunk) {
    watchdog.restart();
    // SplitParser's segments are not reliably newline-aligned (chunks can
    // contain or start mid-line), so re-frame lines here from raw chunks.
    root.rawBuf += chunk;
    let nl;
    while ((nl = root.rawBuf.indexOf("\n")) !== -1) {
      const line = root.rawBuf.slice(0, nl).replace(/\r$/, "");
      root.rawBuf = root.rawBuf.slice(nl + 1);
      root.sseLine(line);
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
      root.streamLive = false;
      if (root.panelOpen && root.svcUp) streamRetry.restart();
    }
  }

  function handleEvent(ev) {
    const sid = root.session ? root.session.id : "";
    const d = ev.data || {};
    const mine = d.sessionID === sid;
    switch (ev.type) {
      // token-level chunks — applied directly, no reload
      case "session.text.delta":
        if (mine) applyDelta(d, "assistant");
        return;
      case "session.reasoning.delta":
        if (mine) applyDelta(d, "reasoning");
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
          } else {
            root.busy = true;
          }
          refreshSoon();
        }
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
          refreshSoon();
        }
        return;
      case "session.inbox.enqueued":
      case "session.inbox.delivered":
        if (mine) refreshSoon();
        return;
      case "permission.asked":
        root.loadPerms();
        refreshSoon();
        return;
      case "permission.replied":
        root.loadPerms();
        return;
      case "server.connected":
        root.streamLive = true;
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
    delete root.pendingDeltas[key + "|" + kind];
    for (let i = 0; i < chatModel.count; i++) {
      const it = chatModel.get(i);
      if (it.key !== key || it.kind !== kind) continue;
      if (d.text.length >= it.text.length) {
        chatModel.setProperty(i, "text", d.text);
      }
      chatModel.setProperty(i, "live", false);
      if (chatView.pinned) Qt.callLater(chatView.stick);
      return;
    }
    // part was never streamed to us — add it settled
    chatModel.append({ key: key, kind: kind, text: d.text,
                       name: "", state: "", toolIn: "", toolOut: "",
                       live: false });
    if (chatView.pinned) Qt.callLater(chatView.stick);
    debugChat("ended");
  }

  function flushDeltas() {
    const pend = root.pendingDeltas;
    root.pendingDeltas = {};
    let stuck = false;
    for (const mapKey in pend) {
      const sep = mapKey.lastIndexOf("|");
      const key = mapKey.slice(0, sep);
      const kind = mapKey.slice(sep + 1);
      const text = pend[mapKey];
      let found = false;
      for (let i = 0; i < chatModel.count; i++) {
        const it = chatModel.get(i);
        if (it.key !== key || it.kind !== kind) continue;
        chatModel.setProperty(i, "text", it.text + text);
        chatModel.setProperty(i, "live", true);
        found = true;
        break;
      }
      if (!found) {
        chatModel.append({ key: key, kind: kind, text: text,
                           name: "", state: "", toolIn: "", toolOut: "",
                           live: true });
      }
      stuck = true;
    }
    // callLater: stick after the layout pass, against fresh contentHeight
    if (stuck) Qt.callLater(chatView.stick);
    debugChat("flush");
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

  function refreshSoon() { refreshTimer.restart(); }

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
      root.loadSessionInfo();
    }
  }

  Timer {
    id: streamRetry
    interval: 2000
    onTriggered: root.connectStream()
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

  // (re)read service.json and health-check — also the respawn path,
  // driven by retryTimer
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
    onLoaded: root.readService()
    onLoadFailed: root.checkService()
  }

  Timer {
    id: retryTimer
    interval: 1200
    onTriggered: root.readService()
  }

  // ---------- data loaders ----------
  function loadSession() {
    api("GET", "/api/session?limit=20", null, (ok, data) => {
      if (!ok || !data || !data.data) return;
      root.sessionList = data.data;
      // remember the model/agent last used anywhere — new chats start
      // with them instead of showing the placeholder chips
      for (const s of data.data) {
        if (!root.lastModel && s.model) root.lastModel = s.model;
        if (root.lastAgent === "" && s.agent) root.lastAgent = s.agent;
        if (root.lastModel && root.lastAgent !== "") break;
      }
      if (root.session) return;      // already chatting
      // continue the latest session of this directory (opencode2 --continue)
      const here = data.data.filter(s =>
        s.location && s.location.directory === Quickshell.env("HOME"));
      root.session = (here.length ? here : data.data)[0] || null;
      root.loadMessages();
      root.loadPerms();
    });
  }

  // refresh the open session's live fields (title, cost, model, agent) —
  // the server re-titles the session after the first prompt
  function loadSessionInfo() {
    if (!root.session) return;
    api("GET", "/api/session/" + root.session.id, null, (ok, d) => {
      if (ok && d && d.data) root.session = d.data;
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

  // TEMP DEBUG: compact model snapshot — find the disappearing-part bug
  function debugChat(tag) {
    let s = tag + " n=" + chatModel.count + " [";
    for (let i = 0; i < chatModel.count; i++) {
      const it = chatModel.get(i);
      s += (i ? ", " : "") + it.kind.charAt(0) + ":" + it.key.slice(-6) + ":"
          + (it.kind === "tool" ? (it.state || "").slice(0, 12) : it.text.length);
    }
    console.log("CHAT " + s + "]");
  }

  // transient "copied" toast in the panel
  function showCopyToast() { toastTimer.restart(); }

  function loadMessages() {
    if (!root.session) return;
    api("GET", "/api/session/" + root.session.id + "/message", null, (ok, data) => {
      if (!ok || !data || !data.data) return;
      const wasPinned = chatView.pinned;
      let mode = "inplace";
      // rebuild atomically: intermediate contentHeight collapses clamp
      // contentY and would clobber the pinned/scroll state mid-rebuild
      root.rebuilding = true;
      try {
      // the API returns messages newest-first; chat order is oldest-first
      const raw = data.data;
      const ms = raw.slice().reverse();
      // snapshot the current items: the API copy can lag the live deltas,
      // so streamed text must never shrink
      const prev = {};
      for (let i = 0; i < chatModel.count; i++) {
        const it = chatModel.get(i);
        prev[it.key + "|" + it.kind] = it.text;
      }

      // build the desired item list WITHOUT touching the model
      const desired = [];
      for (const m of ms) {
        if (m.type === "user") {
          desired.push({ key: m.id, kind: "user", text: m.text || "",
                         name: "", state: "", toolIn: "", toolOut: "",
                         live: false });
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
              const t = (c.text || "").length >= (prev[k] || "").length
                  ? c.text : prev[k];
              desired.push({ key: key, kind: "assistant", text: t,
                             name: "", state: "", toolIn: "", toolOut: "",
                             live: !done });
            } else if (c.type === "reasoning") {
              const k = key + "|reasoning";
              const t = (c.text || "").length >= (prev[k] || "").length
                  ? (c.text || "") : (prev[k] || "");
              desired.push({ key: key, kind: "reasoning", text: t,
                             name: "", state: "", toolIn: "", toolOut: "",
                             live: !done });
            } else if (c.type === "tool") {
              const st = c.state || {};
              const running = st.status === "running" || st.status === "streaming";
              desired.push({
                key: key, kind: "tool", name: c.tool || c.name || "tool",
                state: (st.status || "") + (st.title ? " · " + st.title : running ? " · running…" : ""),
                toolIn: st.input ? JSON.stringify(st.input, null, 1) : "",
                toolOut: toolOutText(st),
                live: false
              });
            }
          }
        }
      }

      // apply with the smallest possible surgery: destroying delegates
      // re-creates and re-parses every markdown text — visible flicker.
      // Same shape → field updates in place; new parts → append-only;
      // full rebuild only on structural changes (session switch, reorder).
      const n = Math.min(chatModel.count, desired.length);
      let prefix = 0;
      for (; prefix < n; prefix++) {
        const it = chatModel.get(prefix);
        if (it.key !== desired[prefix].key || it.kind !== desired[prefix].kind) break;
      }

      if (prefix === chatModel.count || prefix === desired.length) {
        // shape preserved: update in place; trailing streamed extras not
        // persisted yet simply stay (they merge in on a later reload)
        const upto = Math.min(chatModel.count, desired.length);
        for (let i = 0; i < upto; i++) {
          const d = desired[i];
          const it = chatModel.get(i);
          if (it.text !== d.text) chatModel.setProperty(i, "text", d.text);
          if (it.name !== d.name) chatModel.setProperty(i, "name", d.name);
          if (it.state !== d.state) chatModel.setProperty(i, "state", d.state);
          if (it.toolIn !== d.toolIn) chatModel.setProperty(i, "toolIn", d.toolIn);
          if (it.toolOut !== d.toolOut) chatModel.setProperty(i, "toolOut", d.toolOut);
          // `live` only ever settles true → false (part finished)
          if (it.live && !d.live) chatModel.setProperty(i, "live", false);
        }
        for (let i = chatModel.count; i < desired.length; i++)
          chatModel.append(desired[i]);
      } else {
        mode = "rebuild";
        chatModel.clear();
        for (const d of desired) chatModel.append(d);
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
      } finally { root.rebuilding = false; }
      // restore the scroll exactly where the rebuild found it
      chatView.pinned = wasPinned;
      if (wasPinned) Qt.callLater(chatView.stick);
      debugChat("reload " + mode);
    });
  }

  function loadPerms() {
    if (!root.session) return;
    api("GET", "/api/session/" + root.session.id + "/permission", null, (ok, data) => {
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

  // ---------- actions ----------
  function newChat() {
    // no title — the server auto-titles from the first message
    api("POST", "/api/session", {}, (ok, data) => {
      if (!ok || !data || !data.data) { root.error = "could not create session"; return; }
      root.session = data.data;
      chatModel.clear();
      root.busy = false;
      root.pendingPerm = null;
      root.menu = "";
      // a fresh session carries no model/agent — apply the last used ones
      // server-side so the chips tell the truth
      if (root.lastModel)
        api("POST", "/api/session/" + root.session.id + "/model",
            { model: root.lastModel }, ok2 => {
              if (ok2 && root.session)
                root.session = Object.assign({}, root.session, { model: root.lastModel });
            });
      if (root.lastAgent !== "")
        api("POST", "/api/session/" + root.session.id + "/agent",
            { agent: root.lastAgent }, ok2 => {
              if (ok2 && root.session)
                root.session = Object.assign({}, root.session, { agent: root.lastAgent });
            });
      inputField.forceActiveFocus();
    });
  }

  function switchSession(s) {
    root.session = s;
    chatModel.clear();
    root.pendingPerm = null;
    root.menu = "";
    root.loadMessages();
    root.loadPerms();
  }

  function switchModel(m) {
    if (!root.session) return;
    api("POST", "/api/session/" + root.session.id + "/model",
        { model: { id: m.id, providerID: m.providerID } }, ok => {
          if (ok && root.session) {
            root.lastModel = { id: m.id, providerID: m.providerID };
            root.session = Object.assign({}, root.session,
              { model: { id: m.id, providerID: m.providerID } });
          }
          root.menu = "";
        });
  }

  function switchAgent(a) {
    if (!root.session) return;
    api("POST", "/api/session/" + root.session.id + "/agent",
        { agent: a.id }, ok => {
          if (ok) root.lastAgent = a.id;
          root.menu = "";
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
    const re = /(^|\s)@([^\s,;]+)/g;
    let m;
    while ((m = re.exec(text)) !== null) {
      const start = m.index + m[1].length;
      const tok = m[2];
      files.push({
        uri: "file://" + dir + "/" + tok,
        name: tok,
        mention: { start: start, end: start + 1 + tok.length, text: "@" + tok }
      });
    }
    return files;
  }

  function send() {
    if (root.sending || root.busy) return;
    const text = inputField.text.trim();
    if (text === "") return;
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
      api("POST", "/api/session/" + root.session.id + "/command",
          { command: name, text: args }, (ok, d, status) => {
            root.sending = false;
            if (!ok) root.error = "command failed (" + status + ")";
            else { root.busy = true; root.turnStartMs = Date.now(); root.loadMessages(); }
          });
      return;
    }

    const files = collectFiles(text);
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
    else api("POST", "/api/session", { title: text.slice(0, 60) }, (ok, data) => {
      if (!ok || !data || !data.data) { root.sending = false; root.error = "could not create session"; return; }
      root.session = data.data;
      prompt(data.data.id);
    });
  }

  // ---------- mention / command finders ----------
  function updateFinder() {
    const text = inputField.text;
    // "/" at start with no space yet → command menu
    if (text.length > 0 && text[0] === "/" && text.indexOf(" ") === -1) {
      root.fileHits = [];
      root.menu = "commands";
      return;
    }
    // trailing @token → file finder
    const m = text.match(/@([^\s,;]*)$/);
    if (m && root.session) {
      const q = m[1];
      root.menu = "files";
      if (q.length === 0) { root.fileHits = []; return; }
      api("GET", "/api/fs/find?query=" + encodeURIComponent(q)
          + "&type=file&limit=8", null, (ok, data) => {
        if (!ok || !data || !data.data) { root.fileHits = []; return; }
        root.fileHits = data.data.map(f =>
          typeof f === "string" ? f : (f.path || f.name || ""));
      });
      return;
    }
    if (root.menu === "files") root.menu = "";
  }

  function pickFile(path) {
    const text = inputField.text;
    const m = text.match(/@([^\s,;]*)$/);
    if (m) {
      // fs/find returns paths relative to the session directory — mention
      // the relative form (like the TUI does)
      const dir = root.session && root.session.location
          ? root.session.location.directory : Quickshell.env("HOME");
      let rel = path;
      if (rel.indexOf(dir + "/") === 0) rel = rel.slice(dir.length + 1);
      inputField.text = text.slice(0, m.index) + "@" + rel;
      inputField.cursorPosition = inputField.text.length;
    }
    root.menu = "";
    inputField.forceActiveFocus();
  }

  function toggleFold(key) {
    const e = Object.assign({}, root.expanded);
    e[key] = !e[key];
    root.expanded = e;
  }

  function closeMenuOrPanel() {
    if (root.menu !== "") { root.menu = ""; return; }
    root.panelOpen = false;
  }

  // ---------- pill ----------
  Text {
    id: label
    anchors.centerIn: parent
    text: "󰆍"
    font.family: "Agave Nerd Font"
    font.bold: true
    font.pixelSize: 14
    color: root.busy ? root.cLive
         : root.panelOpen ? root.cAccent
         : (mouse.containsMouse ? "#ffffff" : "#dcdfe1")
    Behavior on color { ColorAnimation { duration: 150 } }
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
    text: "opencode — chat panel"
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
      inputField.text = text;
      root.inputSyncing = false;
      root.updateFinder();
    }
    onCursorPositionChanged: if (!root.inputSyncing) {
      root.inputSyncing = true;
      inputField.cursorPosition = cursorPosition;
      root.inputSyncing = false;
    }
    // the chat's TextEdits never hold the (compositor) keyboard — the bar
    // does. Forward copy from here to whichever message has a selection
    Keys.onPressed: event => {
      if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier)
          && root.selEdit) {
        root.selEdit.copy();
        root.showCopyToast();
        event.accepted = true;
      }
    }
    Keys.onReturnPressed: root.send()
    Keys.onEnterPressed: root.send()
    Keys.onEscapePressed: root.closeMenuOrPanel()
  }

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

    visible: root.panelOpen
    color: "transparent"
    implicitWidth: panelContent.width
    implicitHeight: panelContent.height

    onVisibleChanged: {
      if (!visible || !root.panelOpen) return;
      // the BAR window holds compositor keyboard focus (its OnDemand grab
      // was taken by the pill's click) — focus the hidden TextInput that
      // lives there; the popup's field mirrors its text (see hiddenInput).
      // Re-asserted shortly after, once the keyboard mode change and map
      // have fully settled.
      hiddenInput.forceActiveFocus();
      refocusTimer.restart();
      if (root.svcUp) root.connectStream();
      // events missed while closed are never replayed by the stream —
      // reload now (also reconciles a stale `busy` via loadMessages)
      root.lastChangeMs = Date.now();
      root.clearBusyNextLoad = true;
      root.loadMessages();
      root.loadPerms();
    }

    anchor {
      window: root.QsWindow.window
      edges: Edges.Top | Edges.Right
      gravity: Edges.Bottom | Edges.Left
    }

    anchor.onAnchoring: {
      // pill coords (relative to the bar window) + the bar's own offsets
      // (Bar.qml margins: left 2); right-align the panel's right edge
      // with the pill's right edge
      const p = root.mapToItem(null, 0, 0);
      anchor.rect.x = p.x + 2;
      anchor.rect.y = p.y + root.height + 6;
      anchor.rect.width = root.width;
      anchor.rect.height = 1;
    }

    Rectangle {
      id: panelContent
      anchors.fill: parent
      width: 660
      height: 700
      color: root.cBg
      radius: 6
      border.color: root.cBorder
      border.width: 1

      Column {
        anchors.fill: parent
        anchors.margins: 10
        anchors.bottomMargin: 0   // input row sits on the bottom edge
        spacing: 8

        // ----- header -----
        Row {
          id: headerRow
          width: parent.width
          height: 26
          spacing: 8

          Text {
            id: headerIcon
            anchors.verticalCenter: parent.verticalCenter
            text: "󰆍"
            font.family: "Agave Nerd Font"
            font.bold: true
            font.pixelSize: 13
            color: root.busy ? root.cLive : root.cMuted
          }

          // session title — click for the session list. Width accounts for
          // every sibling (incl. the stop button, which appears mid-turn)
          // so the header never overflows the panel edge
          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - headerIcon.width - costText.width
                   - modelBtn.width - agentBtn.width - newBtn.width - 40
                   - (stopBtn.visible ? stopBtn.width + 8 : 0)
            text: root.session ? (root.session.title || "opencode") : "opencode — new chat"
            font.family: "Agave Nerd Font"
            font.bold: true
            font.pixelSize: 12
            color: root.cAccent
            elide: Text.ElideRight

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.menu = root.menu === "sessions" ? "" : "sessions"
            }
          }

          Text {
            id: costText
            anchors.verticalCenter: parent.verticalCenter
            text: root.session && root.session.cost > 0
                  ? "$" + root.session.cost.toFixed(2) : ""
            font.family: "Agave Nerd Font"
            font.pixelSize: 10
            color: root.cMuted
          }

          // model chip — click for the model list
          Rectangle {
            id: modelBtn
            anchors.verticalCenter: parent.verticalCenter
            width: modelText.implicitWidth + 14
            height: 22
            radius: 5
            color: modelMa.containsMouse ? root.cHover : root.cSurface
            Behavior on color { ColorAnimation { duration: 150 } }
            Text {
              id: modelText
              anchors.centerIn: parent
              text: root.session && root.session.model ? root.session.model.id : "model"
              font.family: "Agave Nerd Font"
              font.pixelSize: 10
              color: root.cText
            }
            MouseArea {
              id: modelMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.menu = root.menu === "models" ? "" : "models"
            }
          }

          // agent chip — click for the agent list
          Rectangle {
            id: agentBtn
            anchors.verticalCenter: parent.verticalCenter
            width: agentText.implicitWidth + 14
            height: 22
            radius: 5
            color: agentMa.containsMouse ? root.cHover : root.cSurface
            Behavior on color { ColorAnimation { duration: 150 } }
            Text {
              id: agentText
              anchors.centerIn: parent
              text: root.session && root.session.agent ? root.session.agent : "agent"
              font.family: "Agave Nerd Font"
              font.pixelSize: 10
              color: root.cText
            }
            MouseArea {
              id: agentMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.menu = root.menu === "agents" ? "" : "agents"
            }
          }

          Rectangle {
            id: newBtn
            anchors.verticalCenter: parent.verticalCenter
            width: 22; height: 22; radius: 5
            color: newChatMa.containsMouse ? root.cHover : root.cSurface
            Behavior on color { ColorAnimation { duration: 150 } }
            scale: newChatMa.containsMouse ? 1.07 : 1
            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            Text {
              anchors.centerIn: parent
              text: "\uf067"          // plus — the old oct glyph overflowed the 22px chip
              font.family: "Agave Nerd Font"
              font.pixelSize: 11
              color: root.cText
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
            visible: root.busy || root.sending
            color: stopMa.containsMouse ? root.cHover : root.cSurface
            Behavior on color { ColorAnimation { duration: 150 } }
            Text {
              anchors.centerIn: parent
              text: "\uf04d"
              font.family: "Agave Nerd Font"
              font.pixelSize: 11
              color: "#ff6666"
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
          width: parent.width
          height: root.error !== "" ? implicitHeight : 0
          visible: root.error !== ""
          text: root.error
          font.family: "Agave Nerd Font"
          font.pixelSize: 10
          color: "#ff6666"
          elide: Text.ElideRight
        }

        // ----- chat history (anchored to the bottom like a real chat) -----
        Flickable {
          id: chatView
          width: parent.width
          height: parent.height - headerRow.height - menuBox.height
                  - errorLine.height - permBanner.height - inputRow.height
                  - 8 * 5
          clip: true
          contentWidth: width
          contentHeight: chatCol.implicitHeight + (height > chatCol.implicitHeight
            ? chatCol.y : 0)

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
                required property string toolIn
                required property string toolOut
                required property bool live
                readonly property bool open: root.expanded[key] === true
                width: chatCol.width
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
                  color: msgDel.kind === "user" ? root.cSurface : "transparent"
                  border.width: msgDel.kind === "user" ? 1 : 0
                  border.color: root.cBorder

                  // invisible measure: TextEdit has no content-hugging width,
                  // this sizes the user bubble
                  Text {
                    id: userMeasure
                    visible: false
                    width: Math.min(chatCol.width - 60, implicitWidth)
                    text: msgDel.text
                    textFormat: Text.PlainText
                    font.family: "Agave Nerd Font"
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
                    // markdown live during streaming too — safe now that
                    // tokens are batched (~12 updates/s), no re-parse storm
                    textFormat: TextEdit.MarkdownText
                    text: msgDel.text
                    font.pixelSize: 12
                    color: root.cAccent
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
                    font.family: "Agave Nerd Font"
                    font.pixelSize: 10
                    color: msgDel.kind === "reasoning" ? root.cMuted
                         : (msgDel.state.indexOf("error") !== -1 ? "#ff6666" : root.cMuted)
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
                      visible: msgDel.toolIn !== ""
                      width: parent.width
                      height: contentHeight
                      text: msgDel.toolIn
                      textFormat: TextEdit.PlainText
                      font.pixelSize: 9
                      color: root.cIdleText
                      onSelectedTextChanged: if (selectedText !== "") root.selEdit = toolInEdit
                      onCopied: root.showCopyToast()
                    }

                    // reasoning text lives in `text` (tools use toolOut)
                    SelText {
                      id: reasoningEdit
                      visible: msgDel.kind === "reasoning" && msgDel.text !== ""
                      width: parent.width
                      height: contentHeight
                      text: msgDel.text
                      textFormat: TextEdit.PlainText
                      font.pixelSize: 9
                      color: root.cMuted
                      onSelectedTextChanged: if (selectedText !== "") root.selEdit = reasoningEdit
                      onCopied: root.showCopyToast()
                    }

                    SelText {
                      id: toolOutEdit
                      visible: msgDel.toolOut !== ""
                      width: parent.width
                      height: contentHeight
                      text: msgDel.toolOut.length > 4000
                            ? msgDel.toolOut.slice(0, 4000) + " …"
                            : msgDel.toolOut
                      textFormat: TextEdit.PlainText
                      font.pixelSize: 9
                      color: msgDel.kind === "reasoning" ? root.cMuted : root.cText
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
              font.family: "Agave Nerd Font"
              font.pixelSize: 11
              color: root.cMuted
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
          width: parent.width
          height: root.menu !== "" ? Math.min(200, menuCol.implicitHeight + 12) : 0
          visible: root.menu !== ""
          radius: 6
          color: root.cSurface
          border.color: root.cBorder
          border.width: 1
          clip: true

          Flickable {
            id: menuFlick
            anchors.fill: parent
            contentWidth: width
            contentHeight: menuCol.implicitHeight + 12
            interactive: contentHeight > height
            clip: true

            Connections {
              target: root
              function onMenuChanged() { menuFlick.contentY = 0; }
            }

            Column {
              id: menuCol
              x: 6
              y: 6
              width: menuFlick.width - 12
              spacing: 2

            // file finder results
            Repeater {
              model: root.menu === "files" ? root.fileHits : []

              Rectangle {
                required property string modelData
                width: menuCol.width - 4
                height: 24
                radius: 4
                color: fileMa.containsMouse ? root.cHover : "transparent"
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  text: parent.modelData
                  font.family: "Agave Nerd Font"
                  font.pixelSize: 10
                  color: root.cText
                  elide: Text.ElideMiddle
                  width: parent.width - 16
                }
                MouseArea {
                  id: fileMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.pickFile(parent.modelData)
                }
              }
            }

            // sessions menu
            Repeater {
              model: root.menu === "sessions" ? root.sessionList : []

              Rectangle {
                required property var modelData
                readonly property bool cur: root.session && root.session.id === modelData.id
                width: menuCol.width - 4
                height: 24
                radius: 4
                color: sesMa.containsMouse ? root.cHover : "transparent"
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - 90
                  text: (parent.cur ? "● " : "") + (parent.modelData.title || parent.modelData.id)
                  font.family: "Agave Nerd Font"
                  font.pixelSize: 10
                  font.bold: parent.cur
                  color: parent.cur ? root.cAccent : root.cText
                  elide: Text.ElideRight
                }
                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  text: parent.modelData.agent || ""
                  font.family: "Agave Nerd Font"
                  font.pixelSize: 9
                  color: root.cMuted
                }
                MouseArea {
                  id: sesMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.switchSession(parent.modelData)
                }
              }
            }

            // models menu
            Repeater {
              model: root.menu === "models" ? root.models : []

              Rectangle {
                required property var modelData
                readonly property bool cur: root.session && root.session.model
                    && root.session.model.id === modelData.id
                width: menuCol.width - 4
                height: 24
                radius: 4
                color: modMa.containsMouse ? root.cHover : "transparent"
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - 90
                  text: (parent.cur ? "● " : "") + parent.modelData.name
                      + "  ·  " + parent.modelData.providerID
                  font.family: "Agave Nerd Font"
                  font.pixelSize: 10
                  font.bold: parent.cur
                  color: parent.cur ? root.cAccent : root.cText
                  elide: Text.ElideRight
                }
                MouseArea {
                  id: modMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.switchModel(parent.modelData)
                }
              }
            }

            // agents menu
            Repeater {
              model: root.menu === "agents" ? root.agents : []

              Rectangle {
                required property var modelData
                readonly property bool cur: root.session && root.session.agent === modelData.id
                width: menuCol.width - 4
                height: 24
                radius: 4
                color: agMa.containsMouse ? root.cHover : "transparent"
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  text: (parent.cur ? "● " : "") + parent.modelData.name
                  font.family: "Agave Nerd Font"
                  font.pixelSize: 10
                  font.bold: parent.cur
                  color: parent.cur ? root.cAccent : root.cText
                }
                MouseArea {
                  id: agMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
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
                color: cmdMa.containsMouse ? root.cHover : "transparent"
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - 16
                  text: "/" + parent.modelData.name
                      + (parent.modelData.description !== ""
                         ? "  —  " + parent.modelData.description : "")
                  font.family: "Agave Nerd Font"
                  font.pixelSize: 10
                  color: root.cText
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
                    inputField.forceActiveFocus();
                  }
                }
              }
            }
            }
          }
        }

        // ----- permission banner -----
        Rectangle {
          id: permBanner
          width: parent.width
          height: root.pendingPerm ? 46 : 0
          visible: root.pendingPerm != null
          radius: 6
          color: root.cSurface
          border.color: root.cBorder
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
            font.family: "Agave Nerd Font"
            font.pixelSize: 10
            color: root.cText
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
                color: permMa.containsMouse ? root.cHover : root.cBg
                Behavior on color { ColorAnimation { duration: 150 } }
                Text {
                  id: permLabel
                  anchors.centerIn: parent
                  text: parent.modelData.l
                  font.family: "Agave Nerd Font"
                  font.pixelSize: 10
                  font.bold: parent.modelData.v !== "reject"
                  color: parent.modelData.v === "reject" ? "#ff6666" : root.cAccent
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

        // ----- input row -----
        Rectangle {
          id: inputRow
          width: parent.width
          height: 38
          radius: 6
          color: root.cSurface
          border.color: inputField.activeFocus || hiddenInput.activeFocus
                       ? root.cMuted : root.cBorder
          border.width: 1

          TextField {
            id: inputField
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: sendBtn.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            background: null
            placeholderText: root.busy ? "opencode is working…"
                                       : "ask opencode…  (@file · /command)"
            placeholderTextColor: root.cIdleText
            color: root.cAccent
            font.family: "Agave Nerd Font"
            font.pixelSize: 12
            selectionColor: root.cHover
            selectedTextColor: root.cAccent
            enabled: !root.busy && !root.sending
            wrapMode: TextInput.Wrap
            // the popup window is keyboard-less — the bar's hiddenInput is
            // the real editor, so this field never gets real active focus
            // (and with it, no caret). Mirror the cursor position and fake
            // the blinking caret here while the panel is open.
            cursorVisible: root.panelOpen && !root.busy && !root.sending
            cursorDelegate: Item {
              implicitWidth: 2
              Rectangle {
                anchors.fill: parent
                radius: 1
                color: root.cAccent
                SequentialAnimation on opacity {
                  running: root.panelOpen && !root.busy && !root.sending
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
            Keys.onReturnPressed: root.send()
            Keys.onEnterPressed: root.send()
            Keys.onEscapePressed: event => {
              event.accepted = true;   // don't let the panel Shortcut also fire
              root.closeMenuOrPanel();
            }
          }

          Rectangle {
            id: sendBtn
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 28; height: 26; radius: 5
            color: sendMa.containsMouse ? root.cHover : root.cBg
            Behavior on color { ColorAnimation { duration: 150 } }
            scale: sendMa.containsMouse ? 1.07 : 1
            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            Text {
              anchors.centerIn: parent
              text: root.busy || root.sending ? "\uf04d" : "➤"
              font.family: "Agave Nerd Font"
              font.pixelSize: 12
              color: root.busy || root.sending ? "#ff6666" : root.cLive
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
        color: root.cSurface
        border.color: root.cBorder
        border.width: 1
        opacity: toastTimer.running ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

        Text {
          id: toastText
          anchors.centerIn: parent
          text: "copied to clipboard"
          font.family: "Agave Nerd Font"
          font.bold: true
          font.pixelSize: 10
          color: root.cText
        }

        Timer {
          id: toastTimer
          interval: 1400
        }
      }

      Shortcut {
        sequence: "Escape"
        onActivated: root.closeMenuOrPanel()
      }
    }
  }

  onPanelOpenChanged: {
    if (panelOpen) return;   // open-side setup happens in the popup's
                             // onVisibleChanged, on the real map
    menu = "";
    stopStream();
  }

  // fallback polling only when the SSE stream is not delivering
  Timer {
    interval: 50
    repeat: true
    running: root.panelOpen && (root.busy || root.sending) && !root.streamLive
    onTriggered: {
      root.loadMessages();
      root.loadPerms();
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
