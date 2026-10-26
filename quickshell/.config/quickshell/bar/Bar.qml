import Quickshell
import Quickshell.Hyprland
import QtQuick
import QtQuick.Shapes
import "../hyprconf"

// One opaque bar frame around the whole monitor, flush to the edges, with
// rounded outer corners and concave inner corners so it reads as a single
// rounded border:
//
//   top     workspaces · clock + notifications · github · tray · Arch logo
//   right   media wave · intelligence dock + auror + volume + settings
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
  readonly property int thinW: 8         // thin left/bottom edges
  readonly property int radius: 8        // inner corner radius

  // ----- panel state (lives on the right bar / settings pill) ------------
  property bool panelOpen: false
  property int settingsTab: 0
  property bool chatPanelOpen: false

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

      GithubPill { id: githubPill; color: "transparent" }
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

    // native toast popups for incoming notifications (Notifs server) — pinned
    // to this bar's monitor and clear of the frame's reserved strips
    Toasts {
      screen: root.screen
      topGap: root.topBarH + 8
      rightGap: root.sideBarW + 8
    }
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
    focusable: root.panelOpen || root.chatPanelOpen
    // exposed for HyprConfig (it reads `barWindow.settingsTab`)
    property int settingsTab: root.settingsTab
    function setSettingsTab(i) { root.settingsTab = i; }

    Rectangle {
      anchors.fill: parent
      color: Theme.bg
    }

    // full-screen catcher: closes the settings dropdown on an outside click
    // (suspended while a native file dialog is open — its clicks must pass)
    Catcher {
      screen: root.screen
      active: root.panelOpen && !HyprSettings.modalDialogOpen
      onClicked: {
        root.panelOpen = false;
        HyprSettings.galleryOpen = false;
      }
    }

    // ----- bottom group: intelligence dock + volume + settings -----
    Column {
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 10
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: 4

      // intelligence central (opencode) — directly above the auror pill. Its
      // slot reserves room above the wheel for the hover fan of mode pills
      // (calc / translate / ocr; the wheel itself is chat), so it must sit in
      // the bottom group.
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

      // DLNA renderer (auror) — sits below the intelligence dock and above
      // the volume pill
      Auror {
        width: parent.width
        color: "transparent"
      }

      Sound {
        width: parent.width
        color: "transparent"
      }

      // wallpaper / hyprlock / hypridle settings panel
      Pill {
        id: settingsPill

        width: parent.width
        color: "transparent"

        // border while the settings dropdown is open
        pillOpen: root.panelOpen

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
          onClicked: {
            const open = !root.panelOpen;
            if (open) root.closeDockedPanels();
            root.panelOpen = open;
          }
        }
      }
    }

    // media soundwave, vertically centered; hover opens the player panel
    Player {
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

  // The docked chat, the calendar and the settings dropdown all unfold over
  // the same part of the screen. The full-mode chat is a real window and can
  // stay open. Opening one docked panel from the IPC bridge closes the others
  // first, so two of them can never be stacked.
  function closeDockedPanels() {
    root.panelOpen = false;
    clockPill.calOpen = false;
    githubPill.panelOpen = false;
    if (opencodePill.panelOpen && !opencodePill.panelExpanded)
      opencodePill.panelOpen = false;
  }

  function toggleChat() {
    if (opencodePill.panelOpen) {
      opencodePill.panelOpen = false;
      return;
    }
    root.closeDockedPanels();
    opencodePill.openMode("chat");
  }

  function openChat() {
    if (!opencodePill.panelOpen) {
      root.closeDockedPanels();
      opencodePill.openMode("chat");
    }
  }

  // open the docked panel on a named mode (chat | calc | translate | ocr) —
  // the keyboard/IPC counterpart of the bar's hover fan
  function openIntel(mode) {
    root.closeDockedPanels();
    opencodePill.openMode(mode || "chat");
  }

  function closeChat() { opencodePill.panelOpen = false; }

  function toggleGithub() {
    if (githubPill.panelOpen) {
      githubPill.panelOpen = false;
      return;
    }
    root.closeDockedPanels();
    githubPill.panelOpen = true;
  }

  function closeGithub() { githubPill.panelOpen = false; }

  function toggleVoiceChat() {
    if (!opencodePill.panelOpen) {
      root.closeDockedPanels();
      opencodePill.panelOpen = true;
      opencodePill.ensureService();
      opencodePill.startVoiceMode();
    } else if (opencodePill.voiceMode) {
      opencodePill.panelOpen = false;   // closing the panel ends Voice Mode too
    } else {
      opencodePill.startVoiceMode();    // text chat open → flip it into voice
    }
  }

  // SUPER+SHIFT+B / SUPER+SHIFT+W / SUPER+SHIFT+V → settings on a tab
  function openSettings(name) {
    const i = hyprConfig.tabIndex(name);
    root.settingsTab = i >= 0 ? i : 0;
    root.closeDockedPanels();
    root.panelOpen = true;
  }

  function closeSettings() { root.panelOpen = false; }

  // notifications live in the clock pill's calendar panel (per-bar state)
  function toggleNotifPanel() {
    const open = !clockPill.calOpen;
    if (open) root.closeDockedPanels();
    clockPill.calOpen = open;
  }
}
