import Quickshell
import Quickshell.Hyprland
import QtQuick
import QtQuick.Shapes
import "../hyprconf"

// Two opaque bars per monitor, fused into an "L" at the top-RIGHT, flush
// against the screen edges:
//
//   topBar   workspaces (left) · clock + notifications (center) · tray (right)
//   sideBar  intelligence central + tasks (top) · volume + settings (bottom)
//
// The side bar hangs from the top bar's right end. An Arch logo sits in the
// square where they meet, and the inner (inverted) radius below it fuses the
// two surfaces. Both reserve their workspace (exclusive zone) so windows do
// not slide underneath. The component root is a Scope: shell.qml still
// instantiates one `Bar` per monitor and routes the keybind IPC calls here.
Scope {
  id: root

  required property var screen

  // ----- geometry (px) ---------------------------------------------------
  readonly property int topBarH: 28
  readonly property int sideBarW: 28
  readonly property int radius: 8        // inner fillet at the junction

  // ----- panel state (lives on the side bar / settings pill) -------------
  property bool panelOpen: false
  property int settingsTab: 0
  property bool chatPanelOpen: false
  property bool tasksPanelOpen: false

  // =======================================================================
  //  top bar
  // =======================================================================
  PanelWindow {
    id: topBar

    screen: root.screen
    anchors { top: true; left: true; right: true }
    implicitHeight: root.topBarH
    color: "transparent"
    // reserve the top strip so windows stay clear of the opaque bar. The side
    // bar (Normal) respects this zone and is pushed down to start right below.
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
      // leave the rightmost sideBarW px for the Arch block. The tray pill has
      // ~10px of internal padding, so use a smaller outer gap than the side
      // bar's top margin (10) to make the visual spacing to the logo match.
      anchors.rightMargin: root.sideBarW + 6
      anchors.verticalCenter: parent.verticalCenter
      spacing: 7

      Tray { id: trayPill; color: "transparent" }
      Battery { color: "transparent" }
    }

    // native toast popups for incoming notifications (Notifs server)
    Toasts {}
  }

  // =======================================================================
  //  side bar (right)
  // =======================================================================
  PanelWindow {
    id: sideBar

    screen: root.screen
    anchors { top: true; right: true; bottom: true }
    implicitWidth: root.sideBarW
    color: "transparent"
    // reserve the right strip; the top bar's zone pushes this down so its top
    // lands exactly on the top bar's bottom edge (fused, no gap)
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
  //  fused corner: inner radius where the two bars meet
  // =======================================================================
  PanelWindow {
    id: corner

    screen: root.screen
    anchors { top: true; right: true }
    margins {
      top: root.topBarH
      right: root.sideBarW
    }
    implicitWidth: root.radius
    implicitHeight: root.radius
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore

    // inverted quarter circle: fills the notch between the top bar's bottom
    // edge and the side bar's left edge (mirrored for the right-hand corner)
    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeWidth: 0
        fillColor: Theme.bg
        startX: 0
        startY: 0

        PathLine { x: root.radius; y: 0 }
        PathLine { x: root.radius; y: root.radius }
        PathArc {
          x: 0
          y: 0
          radiusX: root.radius
          radiusY: root.radius
          direction: PathArc.Counterclockwise
        }
      }
    }
  }

  // =======================================================================
  //  Arch logo, in the square block where the two bars meet
  // =======================================================================
  PanelWindow {
    id: archBlock

    screen: root.screen
    anchors { top: true; right: true }
    implicitWidth: root.sideBarW
    implicitHeight: root.topBarH
    color: Theme.bg
    exclusionMode: ExclusionMode.Ignore

    Text {
      anchors.centerIn: parent
      text: "\uf303"        // Arch Linux (Nerd Font)
      font.family: Theme.font
      font.pixelSize: 16
      color: Theme.accent
    }
  }

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
