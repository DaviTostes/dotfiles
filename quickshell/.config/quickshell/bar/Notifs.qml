pragma Singleton
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Notifications
import QtQuick

// Native notification daemon (replaces swaync). Owns the
// org.freedesktop.Notifications bus name. Live notifications are rendered as
// toasts by each bar's Toasts window; every notification is also kept in a
// capped history that the clock pill's panel lists.
//
// Lifecycle model: a notification stays tracked for its whole life so its
// actions remain invocable from the history even after its toast is hidden.
// Clicking a notification (toast or history) invokes the app's default
// action and, when the app doesn't bring its own window forward (Chromium
// web notifications usually don't), focuses that app's window through
// Hyprland. Only "clear all" closes the notifications for real.
Item {
  id: root

  // suppress toasts while on; notifications still reach the history
  property bool dnd: false
  onDndChanged: if (dnd) root.hideAllToasts()

  // ids whose toast is hidden — they remain tracked (and actionable)
  // hiddenTick re-evaluates toastList when the (plain) object is mutated
  readonly property var hiddenIds: ({})
  property int hiddenTick: 0
  readonly property var toastList: {
    root.hiddenTick;
    return server.trackedNotifications.values.filter(n => !root.hiddenIds[n.id]);
  }
  readonly property int pending: toastList.length

  readonly property alias historyModel: history
  readonly property int historyCount: history.count

  NotificationServer {
    id: server

    // advertise only what we actually use/render
    bodySupported: true
    bodyMarkupSupported: false
    actionsSupported: true
    imageSupported: true
    persistenceSupported: true

    // do not re-emit on reload: history would duplicate and the toast stack
    // is rebuilt by the (reloaded) bars anyway
    keepOnReload: false

    onNotification: n => {
      // tracking must happen before anything else: an untracked notification
      // is discarded by the server and its actions become unreachable
      n.tracked = true;
      root.recordHistory(n);
      if (root.dnd) root.hideToast(n); else root.showToast(n);
    }
  }

  ListModel { id: history }

  // ---------- history ----------
  function recordHistory(n) {
    // apps that keep updating one notification (progress bars, volume,
    // now-playing…) reuse the same id: update in place instead of adding a
    // row per change
    for (let i = 0; i < history.count; i++) {
      if (history.get(i).nid === n.id) {
        history.setProperty(i, "app", n.appName);
        history.setProperty(i, "summary", n.summary);
        history.setProperty(i, "body", n.body);
        history.setProperty(i, "critical",
            n.urgency === NotificationUrgency.Critical);
        return;
      }
    }
    history.insert(0, {
      nid: n.id,
      app: n.appName,
      summary: n.summary,
      body: n.body,
      critical: n.urgency === NotificationUrgency.Critical,
    });
    if (history.count > 50) {
      const old = history.get(history.count - 1).nid;
      history.remove(history.count - 1);
      root.close(old);
    }
  }

  // ---------- toast visibility ----------
  function showToast(n) {
    delete root.hiddenIds[n.id];
    root.hiddenTick++;
  }

  function hideToast(n) {
    root.hiddenIds[n.id] = true;
    root.hiddenTick++;
  }

  function hideAllToasts() {
    for (const n of server.trackedNotifications.values)
      root.hideToast(n);
  }

  // ---------- lifetime ----------
  function find(nid) {
    for (const n of server.trackedNotifications.values)
      if (n.id === nid) return n;
    return null;
  }

  // untracking discards the notification and notifies the client; calling
  // dismiss()/expire() afterwards would touch a destroyed object
  function close(nid) {
    delete root.hiddenIds[nid];
    const n = root.find(nid);
    if (n) n.tracked = false;
  }

  function clearAll() {
    for (const n of server.trackedNotifications.values) {
      delete root.hiddenIds[n.id];
      n.tracked = false;
    }
    history.clear();
  }

  // ---------- click-to-open ----------  // Capture every field we need BEFORE invoking: invoke() closes the
  // notification, which destroys the object synchronously.
  function open(nid) {
    const n = root.find(nid);
    if (n) {
      const app = n.appName || "";
      const acts = n.actions || [];
      let act = acts.length ? acts[0] : null;
      for (let i = 0; i < acts.length; i++) {
        if (acts[i].text === "Activate") { act = acts[i]; break; }
      }
      root.hideToast(n);
      if (act) act.invoke();
      root.focusAfterAction(app);
      return;
    }
    // the live object is gone (the app closed its notification): still take
    // the user to the app, using the name stored in the history entry
    for (let i = 0; i < history.count; i++) {
      if (history.get(i).nid === nid) {
        root.focusApp(history.get(i).app);
        return;
      }
    }
  }

  // Give the app a moment to react to the action, then check whether one of
  // its windows is now active. If not, focus it ourselves — this avoids
  // overriding the exact window/tab the app may have focused.
  function focusAfterAction(name) {
    const q = (name || "").trim().toLowerCase();
    if (q === "") return;
    postAction.want = q;
    postAction.restart();
  }

  Timer {
    id: postAction
    interval: 400
    property string want: ""
    onTriggered: {
      activeProc.want = want;
      activeProc.running = true;
    }
  }

  Process {
    id: activeProc
    command: ["hyprctl", "-j", "activewindow"]
    property string want: ""
    stdout: StdioCollector { id: activeOut }

    onExited: {
      let w = null;
      try { w = JSON.parse(activeOut.text); } catch (e) { w = null; }
      const cls = ((w && w.class) || "").toLowerCase();
      const title = ((w && w.title) || "").toLowerCase();
      if (cls.indexOf(activeProc.want) === -1
          && title.indexOf(activeProc.want) === -1)
        root.focusApp(activeProc.want);
    }
  }

  // Focus the first window whose class or title matches the app name
  // (case-insensitive).
  function focusApp(name) {
    const q = (name || "").trim().toLowerCase();
    if (q === "") return;
    clientsProc.want = q;
    clientsProc.running = true;
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "-j", "clients"]
    property string want: ""
    stdout: StdioCollector { id: clientsOut }

    onExited: {
      let clients = [];
      try { clients = JSON.parse(clientsOut.text); } catch (e) { clients = []; }
      let classHit = null, titleHit = null;
      for (const c of clients) {
        const cls = (c.class || "").toLowerCase();
        if (!classHit && cls.indexOf(clientsProc.want) !== -1) classHit = c;
        const title = (c.title || "").toLowerCase();
        if (!titleHit && title.indexOf(clientsProc.want) !== -1) titleHit = c;
      }
      const target = classHit || titleHit;
      if (!target) return;
      // this Hyprland is configured in Lua: hyprctl dispatch evaluates its
      // argument as Lua, so the legacy "focuswindow address:..." syntax does
      // not exist — the Lua dispatcher form is focus({ window = ... })
      Hyprland.dispatch(
          'hl.dsp.focus({ window = hl.get_window("address:' + target.address + '") })');
    }
  }
}
