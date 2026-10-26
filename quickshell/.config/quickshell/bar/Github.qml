pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// One GitHub poller for the whole shell. The bar pill is instantiated once per
// monitor, so polling and toast notifications must live here (same reason Cava
// and Notifs are singletons): otherwise every screen would spawn its own `gh`
// processes and fire the same desktop notification.
//
// Sources (argv only, never a shell):
//   gh api graphql ...                 viewer's open PRs + check rollup
//   gh api notifications?per_page=50   unread PR / CheckSuite inbox
//   gh api repos/<repo>/actions/runs   queued/in-progress runs per repo
//
// A full poll is 1 + 1 + N gh calls (~0.5 s each). It runs every 60 s and
// whenever a panel opens; a failed source keeps its previous snapshot.
Item {
  id: root

  // ---------- published state ----------
  property string login: ""
  property var prs: []
  property var notifications: []
  property var runs: []
  property bool loading: false
  property string error: ""
  property double lastUpdated: 0
  property bool available: true

  // number of open GithubPill panels, so a new notification only toasts once
  property int panelsOpen: 0

  // notification dedupe: seen keys are `<thread id>|<updated_at>`, not just the
  // id, because GitHub reuses a thread id when new activity arrives
  property var seenNotifIds: ({})
  property bool primed: false

  readonly property int prCount: root.prs.length
  readonly property int unreadCount: root.notifications.length
  readonly property int runningCount: root.runs.length

  // ---------- internals ----------
  property bool _busy: false
  property bool _failed: false
  property string _lastErr: ""
  property string _step: ""
  property var _repos: []
  property int _repoIndex: 0
  property var _runAccum: []
  // repos recently pushed to by the viewer, used to find Actions runs that are
  // not tied to an open PR or an unread notification
  property var recentRepos: []
  property double reposUpdated: 0

  readonly property string prQuery: 'query { viewer { login pullRequests(first: 100, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) { totalCount nodes { number title url isDraft reviewDecision updatedAt repository { nameWithOwner } commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 30) { totalCount nodes { __typename ... on CheckRun { name status conclusion } ... on StatusContext { context state } } } } } } } } } } }'

  function refresh() {
    if (root._busy || !root.available) return;
    root._busy = true;
    root.loading = true;
    root.error = "";
    root._failed = false;
    root._lastErr = "";
    root._step = "pr";
    root._repos = [];
    root._repoIndex = 0;
    root._runAccum = [];
    prProc.handled = false;
    prProc.outDone = false;
    prProc.exitCode = -1;
    prProc.raw = "";
    prProc.started = false;
    prProc.running = true;
    pollTimeout.restart();
  }

  // the panel's refresh chip: clear the "gh is missing" latch and try again
  function retry() {
    root.available = true;
    root.refresh();
  }

  function fail(message) {
    root._failed = true;
    if (root._lastErr === "") root._lastErr = message;
  }

  // ---------- PR parsing ----------
  function afterPrs() {
    if (!root._busy) return;
    if (prProc.handled || !prProc.outDone || prProc.exitCode === -1) return;
    prProc.handled = true;

    let data = null;
    if (prProc.exitCode === 0 && prProc.raw !== "") {
      try { data = JSON.parse(prProc.raw); } catch (e) { data = null; }
    }
    const viewer = data && data.data ? data.data.viewer : null;
    if (viewer) {
      root.login = viewer.login || root.login;
      const nodes = viewer.pullRequests && viewer.pullRequests.nodes
          ? viewer.pullRequests.nodes : [];
      const out = [];
      for (const n of nodes) out.push(root.prRecord(n));
      root.prs = out;
    } else {
      root.fail(root._lastErr || "gh PR query failed");
    }
    root.startNotifications();
  }

  function prRecord(n) {
    const commit = n.commits && n.commits.nodes && n.commits.nodes[0]
        ? n.commits.nodes[0].commit : null;
    const rollup = commit ? commit.statusCheckRollup : null;
    const contexts = rollup && rollup.contexts && rollup.contexts.nodes
        ? rollup.contexts.nodes : [];

    let running = 0, failed = 0, passed = 0;
    for (const c of contexts) {
      if (c.__typename === "CheckRun") {
        if (c.status === "COMPLETED") {
          if (["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED",
               "STARTUP_FAILURE"].indexOf(c.conclusion) >= 0) failed++;
          else if (["SUCCESS", "NEUTRAL", "SKIPPED"].indexOf(c.conclusion) >= 0) passed++;
        } else if (["IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED", "PENDING"].indexOf(c.status) >= 0) {
          running++;
        }
      } else {
        const s = c.state || "";
        if (s === "PENDING" || s === "EXPECTED") running++;
        else if (s === "FAILURE" || s === "ERROR") failed++;
        else if (s === "SUCCESS") passed++;
      }
    }

    let checksState = "none";
    if (running > 0) checksState = "running";
    else if (failed > 0) checksState = "failed";
    else if (passed > 0) checksState = "passed";
    else if (rollup && rollup.state) {
      if (rollup.state === "SUCCESS") checksState = "passed";
      else if (rollup.state === "FAILURE" || rollup.state === "ERROR") checksState = "failed";
      else if (rollup.state === "PENDING" || rollup.state === "EXPECTED") checksState = "running";
    }

    return {
      repo: n.repository && n.repository.nameWithOwner ? n.repository.nameWithOwner : "",
      number: n.number,
      title: n.title || "",
      url: n.url || "",
      isDraft: n.isDraft === true,
      reviewDecision: n.reviewDecision || "",
      updatedAt: n.updatedAt || "",
      checksState: checksState,
      checksRunning: running,
    };
  }

  // ---------- notifications ----------
  function startNotifications() {
    root._step = "notifications";
    notifProc.handled = false;
    notifProc.outDone = false;
    notifProc.exitCode = -1;
    notifProc.raw = "";
    notifProc.started = false;
    notifProc.running = true;
  }

  function afterNotifications() {
    if (!root._busy) return;
    if (notifProc.handled || !notifProc.outDone || notifProc.exitCode === -1) return;
    notifProc.handled = true;

    let arr = null;
    if (notifProc.exitCode === 0) {
      try { arr = JSON.parse(notifProc.raw); } catch (e) { arr = null; }
    }
    if (Array.isArray(arr)) {
      const list = [];
      for (const n of arr) {
        if (!n.unread) continue;
        const type = n.subject && n.subject.type ? n.subject.type : "";
        if (type !== "PullRequest" && type !== "CheckSuite") continue;
        const repo = n.repository && n.repository.full_name ? n.repository.full_name : "";
        if (repo === "") continue;
        list.push({
          id: String(n.id || ""),
          type: type,
          reason: n.reason || "",
          repo: repo,
          title: n.subject.title || "",
          url: root.notifUrl(n, type, repo),
          updatedAt: n.updated_at || "",
        });
      }
      root.notifications = list;
      if (!root.primed) {
        root.primeSeen(list);
        root.primed = true;
      } else {
        root.toastNew(list);
      }
    } else {
      root.fail(root._lastErr || "gh notifications query failed");
    }
    root.startRepos();
  }

  function notifKey(n) { return n.id + "|" + n.updatedAt; }

  function primeSeen(list) {
    const keys = {};
    for (const n of list) keys[root.notifKey(n)] = true;
    root.seenNotifIds = keys;
  }

  function toastNew(list) {
    const current = {};
    for (const n of list) current[root.notifKey(n)] = true;

    if (root.panelsOpen === 0) {
      for (const n of list) {
        const key = root.notifKey(n);
        if (root.seenNotifIds[key]) continue;
        const body = (n.title || "new activity")
            + (n.reason !== "" ? " · " + n.reason : "");
        Quickshell.execDetached(["notify-send", "-u", "low", "-a", "GitHub",
                                 "GitHub — " + n.repo, body]);
      }
    }
    root.seenNotifIds = current;
  }

  function notifUrl(n, type, repo) {
    if (type === "PullRequest") {
      const raw = n.subject && (n.subject.url || n.subject.latest_comment_url)
          ? (n.subject.url || n.subject.latest_comment_url) : "";
      const num = String(raw).split("/").pop();
      if (/^[0-9]+$/.test(num)) return "https://github.com/" + repo + "/pull/" + num;
      return "https://github.com/" + repo + "/pulls";
    }
    // CheckSuite has subject.url === null; the repo's Actions tab is the useful target
    return "https://github.com/" + repo + "/actions";
  }

  // ---------- repository discovery ----------
  // Actions runs are per-repository, and the interesting workflow may be in a
  // repo with no open PR and no unread notification (e.g. a deploy on master).
  // Refresh the pushed-recently list every 5 minutes; the run queries below
  // reuse it.
  function startRepos() {
    root._step = "repos";
    if (root.recentRepos.length > 0
        && (Date.now() - root.reposUpdated) < 300000) {
      root.startRuns();
      return;
    }
    repoProc.handled = false;
    repoProc.outDone = false;
    repoProc.exitCode = -1;
    repoProc.raw = "";
    repoProc.started = false;
    repoProc.running = true;
  }

  function afterRepos() {
    if (!root._busy) return;
    if (repoProc.handled || !repoProc.outDone || repoProc.exitCode === -1) return;
    repoProc.handled = true;

    let arr = null;
    if (repoProc.exitCode === 0) {
      try { arr = JSON.parse(repoProc.raw); } catch (e) { arr = null; }
    }
    if (Array.isArray(arr)) {
      const now = Date.now();
      const out = [];
      for (const r of arr) {
        if (!r || !r.full_name) continue;
        const pushed = Date.parse(r.pushed_at || "");
        // keep repos with activity in the last week; fall back to the most
        // recently pushed ones if every timestamp is missing
        if (!isNaN(pushed) && now - pushed > 7 * 24 * 3600 * 1000) continue;
        out.push(r.full_name);
        if (out.length >= 8) break;
      }
      root.recentRepos = out.length > 0
          ? out : arr.filter(r => r && r.full_name).slice(0, 5).map(r => r.full_name);
      root.reposUpdated = now;
    } else {
      root.fail(root._lastErr || "gh repository query failed");
    }
    root.startRuns();
  }

  // ---------- running Actions ----------
  function startRuns() {
    const repos = [];
    for (const p of root.prs)
      if (p.repo !== "" && repos.indexOf(p.repo) < 0) repos.push(p.repo);
    for (const n of root.notifications)
      if (n.repo !== "" && repos.indexOf(n.repo) < 0) repos.push(n.repo);
    for (const r of root.recentRepos)
      if (r !== "" && repos.indexOf(r) < 0) repos.push(r);

    root._repos = repos.slice(0, 8);
    root._repoIndex = 0;
    root._runAccum = [];
    root._step = "runs";
    root.fetchNextRuns();
  }

  function fetchNextRuns() {
    if (root._repoIndex >= root._repos.length) {
      root._runAccum.sort((a, b) =>
          (b.createdAt || "").localeCompare(a.createdAt || ""));
      root.runs = root._runAccum.slice(0, 10);
      root.finishPoll();
      return;
    }
    const repo = root._repos[root._repoIndex];
    runsProc.repo = repo;
    runsProc.handled = false;
    runsProc.outDone = false;
    runsProc.exitCode = -1;
    runsProc.raw = "";
    runsProc.started = false;
    runsProc.command = ["gh", "api",
                        "repos/" + repo + "/actions/runs?per_page=20"];
    runsProc.running = true;
  }

  function afterRuns() {
    if (!root._busy) return;
    if (runsProc.handled || !runsProc.outDone || runsProc.exitCode === -1) return;
    runsProc.handled = true;
    const repo = runsProc.repo;

    let data = null;
    if (runsProc.exitCode === 0) {
      try { data = JSON.parse(runsProc.raw); } catch (e) { data = null; }
    }
    if (data && Array.isArray(data.workflow_runs)) {
      for (const r of data.workflow_runs) {
        if (!r.status || r.status === "completed") continue;
        root._runAccum.push({
          id: String(r.id || ""),
          repo: repo,
          name: r.name || r.workflow_name || "workflow",
          branch: r.head_branch || "",
          status: r.status,
          url: r.html_url || ("https://github.com/" + repo + "/actions/runs/" + r.id),
          createdAt: r.created_at || "",
        });
      }
    } else {
      // a repo may not have Actions enabled (404) — skip it instead of
      // turning the whole pill into an error state
    }
    root._repoIndex++;
    root.fetchNextRuns();
  }

  function finishPoll() {
    root._busy = false;
    root.loading = false;
    root._step = "";
    root.lastUpdated = Date.now();
    root.error = root._failed ? (root._lastErr || "GitHub refresh failed") : "";
    pollTimeout.stop();
  }

  // ---------- processes ----------
  Process {
    id: prProc
    property bool started: false
    property bool outDone: false
    property int exitCode: -1
    property string raw: ""
    property bool handled: false
    command: ["gh", "api", "graphql", "-f", "query=" + root.prQuery]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        prProc.raw = text;
        prProc.outDone = true;
        root.afterPrs();
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const t = text.trim();
        if (t !== "") root._lastErr = t;
      }
    }
    onStarted: {
      prProc.started = true;
      prProc.outDone = false;
      prProc.exitCode = -1;
      prProc.raw = "";
    }
    onExited: code => {
      prProc.started = true;
      prProc.exitCode = code;
      if (code === 127) root.available = false;
      root.afterPrs();
    }
  }

  Process {
    id: notifProc
    property bool started: false
    property bool outDone: false
    property int exitCode: -1
    property string raw: ""
    property bool handled: false
    command: ["gh", "api", "notifications?per_page=50"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        notifProc.raw = text;
        notifProc.outDone = true;
        root.afterNotifications();
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const t = text.trim();
        if (t !== "") root._lastErr = t;
      }
    }
    onStarted: {
      notifProc.started = true;
      notifProc.outDone = false;
      notifProc.exitCode = -1;
      notifProc.raw = "";
    }
    onExited: code => {
      notifProc.started = true;
      notifProc.exitCode = code;
      root.afterNotifications();
    }
  }

  Process {
    id: repoProc
    property bool started: false
    property bool outDone: false
    property int exitCode: -1
    property string raw: ""
    property bool handled: false
    command: ["gh", "api",
              "user/repos?per_page=100&sort=pushed&direction=desc"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        repoProc.raw = text;
        repoProc.outDone = true;
        root.afterRepos();
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const t = text.trim();
        if (t !== "") root._lastErr = t;
      }
    }
    onStarted: {
      repoProc.started = true;
      repoProc.outDone = false;
      repoProc.exitCode = -1;
      repoProc.raw = "";
    }
    onExited: code => {
      repoProc.started = true;
      repoProc.exitCode = code;
      root.afterRepos();
    }
  }

  Process {
    id: runsProc
    property string repo: ""
    property bool started: false
    property bool outDone: false
    property int exitCode: -1
    property string raw: ""
    property bool handled: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        runsProc.raw = text;
        runsProc.outDone = true;
        root.afterRuns();
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const t = text.trim();
        if (t !== "") root._lastErr = t;
      }
    }
    onStarted: {
      runsProc.started = true;
      runsProc.outDone = false;
      runsProc.exitCode = -1;
      runsProc.raw = "";
    }
    onExited: code => {
      runsProc.started = true;
      runsProc.exitCode = code;
      root.afterRuns();
    }
  }

  // Missing `gh` (or a hung network call) never emits `exited`; the watchdog
  // ends the poll and, if the first step never started, stops future polls.
  Timer {
    id: pollTimeout
    interval: 30000
    onTriggered: {
      if (!root._busy) return;
      if (root._step === "pr" && !prProc.started) root.available = false;
      root._failed = true;
      root._lastErr = "GitHub refresh timed out";
      root.error = "GitHub refresh timed out";
      root._busy = false;
      root.loading = false;
      root._step = "";
      prProc.running = false;
      notifProc.running = false;
      repoProc.running = false;
      runsProc.running = false;
    }
  }

  Timer {
    interval: 60000
    running: root.available
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()
}
