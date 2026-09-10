pragma Singleton
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Notifications
import QtQuick

// Native notification daemon (replaces swaync). Owns the
// org.freedesktop.Notifications bus name; live notifications render as
// toasts via each bar's Toasts window, and every received notification is
// kept in a capped history that the clock pill's panel lists.
//
// Persistence model (like swaync's control center): notifications stay
// tracked (and their actions invocable) even after the toast is hidden;
// clicking a history entry re-invokes the app's default action. Only
// "clear all" closes them for real.
Item {
  id: root

  // suppress toasts while on; notifications still land in the history
  property bool dnd: false
  onDndChanged: if (dnd) root.hideAllToasts()

  // live notifications, tracked by the server (and kept alive) until the
  // user clears them

  // toast ids already shown/hidden — they remain tracked but stop
  // rendering as toasts. expiredTick forces re-evaluation of the filter
  readonly property var expiredIds: ({})
  property int expiredTick: 0
  // `expiredTick` is read so mutating expiredIds (a plain object, not a
  // notifiable property) still re-evaluates this binding
  readonly property var toastList: {
    root.expiredTick;
    return server.trackedNotifications.values.filter(n => !root.expiredIds[n.id]);
  }
  readonly property int pending: toastList.length

  NotificationServer {
    id: server

    // advertise what we actually render
    bodySupported: true
    bodyMarkupSupported: false
    actionsSupported: true
    imageSupported: true
    persistenceSupported: true

    // on config reload the server re-emits prior-generation notifications;
    // the toast stack is rebuilt by the bars, history would only duplicate
    keepOnReload: false

    onNotification: n => {
      n.tracked = true;
      // apps that keep updating one notification (progress bars, volume,
      // now-playing…) reuse the same id — update in place instead of
      // spamming the history with a row per change
      for (let i = 0; i < history.count; i++) {
        if (history.get(i).nid === n.id) {
          history.setProperty(i, "app", n.appName);
          history.setProperty(i, "summary", n.summary);
          history.setProperty(i, "body", n.body);
          history.setProperty(i, "critical",
              n.urgency === NotificationUrgency.Critical);
          // always track: even with dnd on the notification must survive so
          // its actions stay invocable from the history
          n.tracked = true;
          if (root.dnd) root.hideToast(n); else root.showToast(n);
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
        // drop the oldest entry and really close its notification
        const old = history.get(history.count - 1).nid;
        history.remove(history.count - 1);
        root.close(old);
      }
      n.tracked = true;
      if (root.dnd) root.hideToast(n); else root.showToast(n);
    }
  }

  ListModel { id: history }

  readonly property int historyCount: history.count

  // the history model itself, for views (ids do not cross file boundaries)
  readonly property alias historyModel: history

  function showToast(n) {
    delete root.expiredIds[n.id];
    root.expiredTick++;
  }

  // hide the toast visual only — the object stays tracked/alive so its
  // actions remain invocable from the history
  function hideToast(n) {
    root.expiredIds[n.id] = true;
    root.expiredTick++;
  }

  function hideAllToasts() {
    for (const n of server.trackedNotifications.values)
      root.hideToast(n);
  }

  // real closure: untracking discards the notification and notifies the
  // client — calling dismiss() afterwards would hit a destroyed object
  function close(nid) {
    delete root.expiredIds[nid];
    for (const n of server.trackedNotifications.values) {
      if (n.id === nid) {
        n.tracked = false;
        return;
      }
    }
  }

  // toast click / history row click: run the app default action, then hide
  // the toast (the history entry survives). The "default action" is the one
  // labeled "Activate" (apps send it first with key "default"); fall back to
  // the first action. Plain loops — .find on a QList is not worth relying on.
  function open(nid) {
    for (const n of server.trackedNotifications.values) {
      if (n.id !== nid) continue;
      const acts = n.actions || [];
      let act = acts.length ? acts[0] : null;
      for (let i = 0; i < acts.length; i++) {
        if (acts[i].text === "Activate") { act = acts[i]; break; }
      }
      // hide first: invoking can close/destroy the notification synchronously
      root.hideToast(n);
      if (act) act.invoke();
      // if the app ignores the action, take the user to its window anyway
      root.focusAfterAction(n.appName);
      return;
    }
    // the live notification is gone (app closed it): still take the user to
    // the app using the name stored in the history entry
    for (let i = 0; i < history.count; i++) {
      if (history.get(i).nid === nid) {
        root.focusApp(history.get(i).app);
        return;
      }
    }
  }

  // After the app's own action fired: give it a moment, then check whether it
  // actually brought one of its windows to the front. Only if it did NOT
  // (Chromium web notifications receive ActionInvoked but rarely raise their
  // window) fall back to focusing the app's window ourselves — this avoids
  // overriding the exact window/tab the app itself focused.
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

  // Last-resort guarantee for "click a notification and go to the app":
  // query Hyprland for a window whose class or title matches the app name
  // (case-insensitive) and focus it by address.
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

  function clearAll() {
    for (const n of server.trackedNotifications.values) {
      delete root.expiredIds[n.id];
      n.tracked = false;
    }
    history.clear();
  }
}
