import Quickshell
import Quickshell.Hyprland
import QtQuick
import QtQuick.Shapes
import "../hyprconf"

// One opaque bar frame around the whole monitor, flush to the edges, with
// rounded outer corners and concave inner corners so it reads as a single
// rounded border:
//
//   top     workspaces · clock + notifications · tray · Arch logo
//   right   intelligence central + tasks (top) · media wave · volume + settings
//   left    (empty)
//   bottom  (empty)
//
// The four edges are separate PanelWindows that each reserve their strip, so
// windows never slide underneath. The component root is a Scope: shell.qml
// instantiates one per monitor and routes the keybind IPC calls here.
Scope {
  id: root

  required property var screen

  // ----- geometry (px) ---------------------------------------------------
  readonly property int topBarH: 28
  readonly property int sideBarW: 28
  readonly property int thinW: 10         // thin left/bottom edges
  readonly property int radius: 8        // inner corner radius

  // ----- panel state (lives on the right bar / settings pill) ------------
  property bool panelOpen: false
  property int settingsTab: 0
  property bool chatPanelOpen: false
  property bool tasksPanelOpen: false

  // =======================================================================
  //  top edge
  // =======================================================================
  PanelWindow {
    id: topBar

    screen: root.screen
    anchors { top: true; left: true; right: true }
    implicitHeight: root.topBarH
    color: "transparent"
    exclusiveZone: root.topBarH
    // holds the keyboard while the tray menu is open (Esc closes it)
    focusable: trayPill.menuOpen

    Rectangle {
      anchors.fill: parent
      color: Theme.bg
    }

    Workspaces {
      anchors.left: parent.left
      anchors.leftMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      monitor: Hyprland.monitorFor(root.screen)
      color: "transparent"
    }

    Clock {
      id: clockPill
      anchors.centerIn: parent
      color: "transparent"
    }

    Row {
      anchors.right: parent.right
      // leave the rightmost sideBarW px for the Arch logo block, plus a gap
      anchors.rightMargin: root.sideBarW + 6
      anchors.verticalCenter: parent.verticalCenter
      spacing: 7

      Tray { id: trayPill; color: "transparent" }
      Battery { color: "transparent" }
    }

    // Arch logo, centered in the square block at the top-right corner
    Text {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.rightMargin: Math.max(0, (root.sideBarW - implicitWidth) / 2)
      text: "\uf303"        // Arch Linux (Nerd Font)
      font.family: Theme.font
      font.pixelSize: 16
      color: Theme.accent
    }

    // native toast popups for incoming notifications (Notifs server)
    Toasts {}
  }

  // =======================================================================
  //  bottom edge (thin)
  // =======================================================================
  PanelWindow {
    screen: root.screen
    anchors { bottom: true; left: true; right: true }
    implicitHeight: root.thinW
    color: Theme.bg
    exclusiveZone: root.thinW
  }

  // =======================================================================
  //  left edge (thin, empty)
  // =======================================================================
  PanelWindow {
    screen: root.screen
    anchors { left: true; top: true; bottom: true }
    implicitWidth: root.thinW
    color: Theme.bg
    exclusiveZone: root.thinW
  }

  // =======================================================================
  //  right edge (pills)
  // =======================================================================
  PanelWindow {
    id: sideBar

    screen: root.screen
    anchors { right: true; top: true; bottom: true }
    implicitWidth: root.sideBarW
    color: "transparent"
    exclusiveZone: root.sideBarW
    focusable: root.panelOpen || root.chatPanelOpen || root.tasksPanelOpen
    // exposed for HyprConfig (it reads `barWindow.settingsTab`)
    property int settingsTab: root.settingsTab

    Rectangle {
      anchors.fill: parent
      color: Theme.bg
    }

    // full-screen catcher: closes the settings dropdown on an outside click
    // (suspended while a native file dialog is open — its clicks must pass)
    Catcher {
      active: root.panelOpen && !HyprSettings.modalDialogOpen
      onClicked: {
        root.panelOpen = false;
        HyprSettings.galleryOpen = false;
      }
    }

    // ----- top group: ic + tasks -----
    Column {
      id: sideTop

      anchors.top: parent.top
      anchors.topMargin: 10
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: 4

      Opencode {
        id: opencodePill
        width: parent.width
        color: "transparent"
      }
      // docked dropdown owns the side bar's keyboard grab; full mode is a
      // real window with normal focus. Driven from signals (a direct binding
      // races object creation).
      Connections {
        target: opencodePill
        function onPanelOpenChanged() { root.chatPanelOpen = opencodePill.panelOpen && !opencodePill.panelExpanded; }
        function onPanelExpandedChanged() { root.chatPanelOpen = opencodePill.panelOpen && !opencodePill.panelExpanded; }
      }

      Tasks {
        id: tasksPill
        width: parent.width
        color: "transparent"
      }
      Connections {
        target: tasksPill
        function onPanelOpenChanged() { root.tasksPanelOpen = tasksPill.panelOpen; }
      }
    }

    // ----- bottom group: volume + settings -----
    Column {
      id: sideBottom

      anchors.bottom: parent.bottom
      anchors.bottomMargin: 10
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: 4

      Sound {
        width: parent.width
        color: "transparent"
      }

      // wallpaper / hyprlock / hypridle settings panel
      Pill {
        id: settingsPill

        width: parent.width
        color: "transparent"

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

    // media soundwave, vertically centered; hover opens the player panel
    Player {
      id: playerPill
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.right: parent.right
      color: "transparent"
    }

    // settings dropdown, anchored to this bar's settings pill
    HyprConfig {
      id: hyprConfig
      barWindow: sideBar
      pill: settingsPill
      panelOpen: root.panelOpen
    }
  }

  // =======================================================================
  //  inner corner fillets (fuse the four edges)
  // =======================================================================
  EdgeCorner { screen: root.screen; corner: 0; radius: root.radius; edgeX: root.thinW; edgeY: root.topBarH }
  EdgeCorner { screen: root.screen; corner: 1; radius: root.radius; edgeX: root.sideBarW; edgeY: root.topBarH }
  EdgeCorner { screen: root.screen; corner: 2; radius: root.radius; edgeX: root.sideBarW; edgeY: root.thinW }
  EdgeCorner { screen: root.screen; corner: 3; radius: root.radius; edgeX: root.thinW; edgeY: root.thinW }

  // =======================================================================
  //  IPC bridge entry points (shell.qml routes keybind calls here)
  // =======================================================================
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

  function closeChat() { opencodePill.panelOpen = false; }

  // SUPER+SHIFT+B / SUPER+SHIFT+W / SUPER+SHIFT+V → settings on a tab
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
