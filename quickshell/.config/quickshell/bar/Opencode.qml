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
  property var fileHits: []       // @-mention finder hits: {path, type}
  property int fileSel: 0         // keyboard-selected finder hit
  property int finderSeq: 0       // guards against out-of-order finder replies
  property var pendingImages: []  // clipboard images awaiting send: {name, b64}
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
            // ping the desktop whenever a turn ends, panel open or not
            root.notifyDone(false);
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
          root.notifyDone(true);
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
                       diff: "", live: false });
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
      root.loadForms();
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
      root.loadForms();
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

  function renderMarkdown(md) {
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
        i++;
        while (i < lines.length
               && !new RegExp("^\\s*" + marker + "{3,}\\s*$").test(lines[i])) {
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
    imgs.push({ name: "clipboard-" + (imgs.length + 1) + ".png", b64: b64 });
    root.pendingImages = imgs;
  }

  function removePendingImage(i) {
    const imgs = root.pendingImages.slice();
    imgs.splice(i, 1);
    root.pendingImages = imgs;
  }

  function imageUri(img) { return "data:image/png;base64," + img.b64; }

  function pasteFromClipboard(fallbackText) {
    root.pasteFallbackText = fallbackText !== false;
    pasteImageProc.base64 = "";
    pasteImageProc.running = true;
  }

  // desktop notification for a turn that ends while the panel is closed —
  // the only way to learn the job finished without reopening it
  function notifyDone(isErr) {
    const title = isErr ? "opencode — erro"
        : "opencode — " + ((root.session && root.session.title) || "turn complete");
    let body = isErr ? root.error : "";
    if (!isErr) {
      // tail of the newest assistant text (text.ended arrived first, so it
      // is already in the model)
      for (let i = chatModel.count - 1; i >= 0; i--) {
        const it = chatModel.get(i);
        if (it.kind === "assistant" && it.text !== "") {
          body = it.text.length > 120 ? "…" + it.text.slice(-120) : it.text;
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
    api("GET", "/api/session/" + root.session.id + "/message", null, (ok, data) => {
      if (!ok || !data || !data.data) return;
      const wasPinned = chatView.pinned;
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
              const t = (c.text || "").length >= (prev[k] || "").length
                  ? c.text : prev[k];
              desired.push({ key: key, kind: "assistant", text: t,
                             name: "", state: "", toolIn: "", toolOut: "",
                             diff: "", live: !done });
            } else if (c.type === "reasoning") {
              const k = key + "|reasoning";
              const t = (c.text || "").length >= (prev[k] || "").length
                  ? (c.text || "") : (prev[k] || "");
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
                toolIn: st.input ? JSON.stringify(st.input, null, 1) : "",
                toolOut: toolOutText(st),
                diff: diff,
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
          if (it.diff !== d.diff) chatModel.setProperty(i, "diff", d.diff);
          // `live` only ever settles true → false (part finished)
          if (it.live && !d.live) chatModel.setProperty(i, "live", false);
        }
        for (let i = chatModel.count; i < desired.length; i++)
          chatModel.append(desired[i]);
      } else {
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

  // ---------- select questions (forms) ----------
  // The question tool surfaces as a pending form; without rendering it the
  // turn waits forever. Forms carry fields with options (single/multi).
  function loadForms() {
    if (!root.session) return;
    api("GET", "/api/session/" + root.session.id + "/form", null, (ok, data) => {
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

  function formSubmit(form) {
    if (!root.session) return;
    const ans = root.formAnswers[form.id] || {};
    for (const fld of form.fields) {
      if (!fld.required) continue;
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
    if (root.menu !== "") root.menu = "";
  }

  function formCommitText() {
    const t = root.formTextTarget;
    if (!t) return false;
    const v = inputField.text.trim();
    root.formTextTarget = null;
    inputField.text = "";
    if (v !== "") {
      root.formSetAnswer(t.formID, t.key, v);
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
  function newChat() {
    // no title — the server auto-titles from the first message
    api("POST", "/api/session", {}, (ok, data) => {
      if (!ok || !data || !data.data) { root.error = "could not create session"; return; }
      root.session = data.data;
      chatModel.clear();
      root.busy = false;
      root.pendingPerm = null;
      root.pendingForms = [];
      root.formAnswers = {};
      root.formTextTarget = null;
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
    root.pendingForms = [];
    root.formAnswers = {};
    root.formTextTarget = null;
    root.menu = "";
    root.loadMessages();
    root.loadPerms();
    root.loadForms();
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
    const home = Quickshell.env("HOME");
    const re = /(^|\s)@([^\s,;]+)/g;
    let m;
    while ((m = re.exec(text)) !== null) {
      const start = m.index + m[1].length;
      const tok = m[2];
      // absolute and ~-anchored mentions must not be glued to the session dir
      let uri;
      if (tok.startsWith("/")) uri = "file://" + tok;
      else if (tok.startsWith("~/")) uri = "file://" + home + tok.slice(1);
      else uri = "file://" + dir + "/" + tok;
      files.push({
        uri: uri,
        name: tok,
        mention: { start: start, end: start + 1 + tok.length, text: "@" + tok }
      });
    }
    return files;
  }

  function send() {
    if (root.formTextTarget !== null) { root.formCommitText(); return; }
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
      api("POST", "/api/session/" + root.session.id + "/command",
          { command: name, text: args }, (ok, d, status) => {
            root.sending = false;
            if (!ok) root.error = "command failed (" + status + ")";
            else { root.busy = true; root.turnStartMs = Date.now(); root.loadMessages(); }
          });
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
    else api("POST", "/api/session", { title: text.slice(0, 60) }, (ok, data) => {
      if (!ok || !data || !data.data) { root.sending = false; root.error = "could not create session"; return; }
      root.session = data.data;
      prompt(data.data.id);
    });
  }

  // ---------- mention / command finders ----------
  function updateFinder() {
    const text = inputField.text;
    if (root.formTextTarget !== null) {
      root.fileHits = [];
      if (root.menu === "files") root.menu = "";
      return;
    }
    // "/" at start with no space yet → command menu
    if (text.length > 0 && text[0] === "/" && text.indexOf(" ") === -1) {
      root.fileHits = [];
      root.menu = "commands";
      return;
    }
    // trailing @token → file finder (works before a session exists too)
    const m = text.match(/@([^\s,;]*)$/);
    if (m) {
      const q = m[1];
      if (q.length === 0) {
        root.fileHits = [];
        root.fileSel = 0;
        if (root.menu === "files") root.menu = "";
        return;
      }
      root.menu = "files";
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
      return;
    }
    if (root.menu === "files") root.menu = "";
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
    inputField.forceActiveFocus();
    if (type === "directory") root.updateFinder();
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
      else inputField.text = text;
      root.inputSyncing = false;
      if (root.mode === "chat") root.updateFinder();
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
      // @-mention finder: arrows move the selection, Enter picks it
      if (root.menu === "files" && root.fileHits.length > 0) {
        if (event.key === Qt.Key_Down) { root.finderMove(1); event.accepted = true; return; }
        if (event.key === Qt.Key_Up) { root.finderMove(-1); event.accepted = true; return; }
      }
    }
    Keys.onReturnPressed: {
      if (root.formCommitText()) return;
      if (root.mode === "translate") translateBox.translate();
      else if (!root.finderPickSelected()) root.send();
    }
    Keys.onEnterPressed: {
      if (root.formCommitText()) return;
      if (root.mode === "translate") translateBox.translate();
      else if (!root.finderPickSelected()) root.send();
    }
    Keys.onEscapePressed: {
      if (root.formCancelText()) return;
      root.closeMenuOrPanel();
    }
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

    // stays mapped briefly while closing so the fade/slide can play
    visible: root.panelOpen || hideAnim.running
    color: "transparent"
    implicitWidth: panelContent.width
    implicitHeight: panelContent.height

    Timer { id: hideAnim; interval: 220 }

    onVisibleChanged: {
      if (!visible) {
        // panel closed mid-recording: discard the take
        if (root.sttState !== "idle") {
          root.sttCancel = true;
          recProc.running = false;
        }
        return;
      }
      if (!root.panelOpen) return;
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
      root.loadForms();
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
              onClicked: root.menu = root.menu === "sessions" ? "" : "sessions"
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
              text: root.session && root.session.model ? root.session.model.id : "model"
              font.family: Theme.font
              font.pixelSize: 10
              color: Theme.text
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
            visible: root.mode === "chat"
            width: agentText.implicitWidth + 14
            height: 22
            radius: 5
            color: agentMa.containsMouse ? Theme.hover : Theme.surface
            Behavior on color { ColorAnimation { duration: 200 } }
            Text {
              id: agentText
              anchors.centerIn: parent
              text: root.session && root.session.agent ? root.session.agent : "agent"
              font.family: Theme.font
              font.pixelSize: 10
              color: Theme.text
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
                  color: msgDel.kind === "user" ? Theme.surface : "transparent"
                  border.width: msgDel.kind === "user" ? 1 : 0
                  border.color: Theme.border

                  // invisible measure: TextEdit has no content-hugging width,
                  // this sizes the user bubble
                  Text {
                    id: userMeasure
                    visible: false
                    width: Math.min(chatCol.width - 60, implicitWidth)
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
                    text: root.renderMarkdown(msgDel.text)
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
                      visible: msgDel.toolIn !== "" && msgDel.diff === ""
                      width: parent.width
                      height: contentHeight
                      text: msgDel.toolIn
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
                      text: msgDel.text
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
                      text: renderDiff(msgDel.diff)
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
                      text: msgDel.toolOut.length > 4000
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
              function onMenuChanged() { menuFlick.contentY = 0; }
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

            // sessions menu
            Repeater {
              model: root.menu === "sessions" ? root.sessionList : []

              Rectangle {
                required property var modelData
                readonly property bool cur: root.session && root.session.id === modelData.id
                width: menuCol.width - 4
                height: 24
                radius: 4
                color: sesMa.containsMouse ? Theme.hover : "transparent"
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - 90
                  text: (parent.cur ? "● " : "") + (parent.modelData.title || parent.modelData.id)
                  font.family: Theme.font
                  font.pixelSize: 10
                  font.bold: parent.cur
                  color: parent.cur ? Theme.accent : Theme.text
                  elide: Text.ElideRight
                }
                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  text: parent.modelData.agent || ""
                  font.family: Theme.font
                  font.pixelSize: 9
                  color: Theme.muted
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
                color: modMa.containsMouse ? Theme.hover : "transparent"
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - 90
                  text: (parent.cur ? "● " : "") + parent.modelData.name
                      + "  ·  " + parent.modelData.providerID
                  font.family: Theme.font
                  font.pixelSize: 10
                  font.bold: parent.cur
                  color: parent.cur ? Theme.accent : Theme.text
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
                color: agMa.containsMouse ? Theme.hover : "transparent"
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  text: (parent.cur ? "● " : "") + parent.modelData.name
                  font.family: Theme.font
                  font.pixelSize: 10
                  font.bold: parent.cur
                  color: parent.cur ? Theme.accent : Theme.text
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
          enabled: !root.busy && !root.sending
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
          Keys.onReturnPressed: if (!root.formCommitText()
                                     && !root.finderPickSelected()) root.send()
          Keys.onEnterPressed: if (!root.formCommitText()
                                   && !root.finderPickSelected()) root.send()
          Keys.onUpPressed: root.finderMove(-1)
          Keys.onDownPressed: root.finderMove(1)
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

      Shortcut {
        sequence: "Escape"
        onActivated: root.closeMenuOrPanel()
      }
    }
  }

  onPanelOpenChanged: {
    if (panelOpen) {          // open: cancel any pending close so the
      hideAnim.stop();        // fade-in plays from fully transparent
      return;
    }
    hideAnim.restart();       // close: keep mapped while fading out
    menu = "";
    stopStream();
  }

  // tab switch: the bar's hiddenInput is the single real editor — point
  // it at the newly active tab's field (both directions stay in sync)
  onModeChanged: {
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
    if (panelOpen) hiddenInput.forceActiveFocus();
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
