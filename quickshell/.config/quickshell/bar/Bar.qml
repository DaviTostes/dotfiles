import Quickshell
import Quickshell.Hyprland
import QtQuick
import "../hyprconf"

PanelWindow {
  id: root

  // panel state is per-bar (per monitor), like the Pomodoro's panelOpen
  property bool panelOpen: false
  // which tab the settings dropdown opens on (see openSettings below)
  property int settingsTab: 0
  // set by the opencode pill when its DOCKED dropdown is on screen. The full
  // mode is a real window with its own focus, so the bar holds no grab for it.
  property bool chatPanelOpen: false
  // set by the tasks pill while its dropdown is open (same signal-driven
  // pattern as chatPanelOpen: a direct binding races object creation)
  property bool tasksPanelOpen: false

  // lets a panel popup receive keyboard input while it is open (popups
  // can't grab focus themselves; OnDemand only grabs on click) — covers
  // the settings panel, the opencode docked input field, the tasks
  // panel's fields, and the tray menu's Esc-to-close
  focusable: root.panelOpen || root.chatPanelOpen || root.tasksPanelOpen
             || trayPill.menuOpen

  anchors {
    top: true
    left: true
    right: true
  }

  margins {
    top: 2
    left: 4
    right: 4
  }

  implicitHeight: 30
  color: "transparent"

  // full-screen catcher: while the panel is open, any click outside it
  // lands here and closes it (same pattern as the Pomodoro panel).
  // Suspended while a native file dialog is open — the dialog lives on a
  // layer below this overlay and its clicks must go through.
  Catcher {
    active: root.panelOpen && !HyprSettings.modalDialogOpen
    onClicked: {
      root.panelOpen = false;
      HyprSettings.galleryOpen = false;
    }
  }

  Workspaces {
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    monitor: Hyprland.monitorFor(root.screen)
  }

  Clock {
    id: clockPill
    anchors.centerIn: parent
  }

  Row {
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: 7

    Tray { id: trayPill }
    // Player {}
    Battery {}
    // Pomodoro {}
    Tasks {
      id: tasksPill
    }
    // propagate the tasks panel state into the bar's keyboard-focus decision.
    // A Connections (not an `onPanelOpenChanged` on the instance) so the
    // pill's own open/close handler — animations, focus, tab reset — is not
    // shadowed by the outer handler.
    Connections {
      target: tasksPill
      function onPanelOpenChanged() { root.tasksPanelOpen = tasksPill.panelOpen; }
    }
    Opencode {
      id: opencodePill
    }
    // docked dropdown owns the bar keyboard grab; full mode is a real window
    // with normal focus. A direct binding races object creation, so drive it
    // from signals.
    Connections {
      target: opencodePill
      function onPanelOpenChanged() { root.chatPanelOpen = opencodePill.panelOpen && !opencodePill.panelExpanded; }
      function onPanelExpandedChanged() { root.chatPanelOpen = opencodePill.panelOpen && !opencodePill.panelExpanded; }
    }
    // Notifications {}

    // native toast popups for incoming notifications (Notifs server)
    Toasts {}
    Sound {}

    // wallpaper / hyprlock / hypridle settings panel
    Pill {
      id: settingsPill

      implicitWidth: settingsText.implicitWidth + 12

      Text {
        id: settingsText
        anchors.centerIn: parent
        text: "\uf013"
        font.family: Theme.font
        font.pixelSize: 13
        color: root.panelOpen ? Theme.accent : Theme.text
        Behavior on color { ColorAnimation { duration: 200 } }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.panelOpen = !root.panelOpen
      }
    }
  }

  // opens anchored under the pill, on this bar's monitor
  HyprConfig {
    id: hyprConfig
    barWindow: root
    pill: settingsPill
    panelOpen: root.panelOpen
  }

  // IPC bridge entry points — shell.qml routes keybind calls to the
  // focused monitor's bar (the chat panel is per-bar, like its pill)
  function toggleChat() {
    opencodePill.panelOpen = !opencodePill.panelOpen;
    if (opencodePill.panelOpen) opencodePill.ensureService();
  }

  function openChat() {
    if (!opencodePill.panelOpen) {
      opencodePill.panelOpen = true;
      opencodePill.ensureService();
    }
  }

  // SUPER+SHIFT+A: one key for the big chat window — see
  // Opencode.toggleExpanded() for the cycle (closed→full, docked→full,
  // full→closed)
  function toggleChatExpanded() {
    if (!opencodePill.panelOpen) opencodePill.ensureService();
    opencodePill.toggleExpanded();
  }

  function closeChat() { opencodePill.panelOpen = false; }

  // SUPER+SHIFT+B / SUPER+SHIFT+W → settings dropdown, straight on a tab
  // (name resolved by HyprConfig, which owns the tab list)
  function openSettings(name) {
    const i = hyprConfig.tabIndex(name);
    root.settingsTab = i >= 0 ? i : 0;
    root.panelOpen = true;
  }

  function closeSettings() { root.panelOpen = false; }

  // notifications live in the clock pill's calendar panel (per-bar state)
  function toggleNotifPanel() {
    clockPill.calOpen = !clockPill.calOpen;
  }

  // tasks dropdown (per-bar, like the pill) — `qs ipc call tasks toggle`
  function toggleTasks() { tasksPill.panelOpen = !tasksPill.panelOpen; }

  function closeTasks() { tasksPill.panelOpen = false; }
}
