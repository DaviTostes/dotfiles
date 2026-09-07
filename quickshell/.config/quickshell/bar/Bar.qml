import Quickshell
import Quickshell.Hyprland
import QtQuick
import "../hyprconf"

PanelWindow {
  id: root

  // panel state is per-bar (per monitor), like the Pomodoro's panelOpen
  property bool panelOpen: false
  // set by the opencode pill when its chat panel opens (see its instance)
  property bool chatPanelOpen: false

  // lets a panel popup receive keyboard input while it is open (popups
  // can't grab focus themselves; OnDemand only grabs on click) — covers
  // both the settings panel and the opencode chat panel's input field
  focusable: root.panelOpen || root.chatPanelOpen

  anchors {
    top: true
    left: true
    right: true
  }

  margins {
    left: 2
    right: 2
  }

  implicitHeight: 30
  color: "transparent"

  // full-screen catcher: while the panel is open, any click outside it
  // lands here and closes it (same pattern as the Pomodoro panel).
  // Suspended while a native file dialog is open — the dialog lives on a
  // layer below this overlay and its clicks must go through.
  Catcher {
    active: root.panelOpen && !HyprSettings.modalDialogOpen
    onClicked: root.panelOpen = false
  }

  Workspaces {
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    monitor: Hyprland.monitorFor(root.screen)
  }

  Clock {
    anchors.centerIn: parent
  }

  Row {
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: 7

    Player {}
    Tray {}
    Battery {}
    Pomodoro {}
    Opencode {
      // propagate into the bar's keyboard-focus decision (a plain binding
      // on the pill's property races object creation at load time)
      onPanelOpenChanged: root.chatPanelOpen = panelOpen
    }
    Notifications {}

    // hyprpaper / hyprlock / hypridle settings panel
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
        Behavior on color { ColorAnimation { duration: 300 } }
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
    barWindow: root
    pill: settingsPill
    panelOpen: root.panelOpen
  }
}
