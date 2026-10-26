import Quickshell
import QtQuick

// Invisible full-screen catcher: while `active` it swallows every click
// and emits `clicked`. It stays visible for a short moment after
// deactivating, so the release of the closing click cannot leak through
// to the surface underneath (classic popup click-through bug).
//
// A PanelWindow defaults to the focused monitor, not to the window that owns
// it, so every call site binds `screen` to its bar (or panel) — otherwise the
// catcher for a dropdown on monitor A would cover monitor B.
PanelWindow {
  id: root

  property bool active: false
  signal clicked

  readonly property bool shielding: root.active || shieldTimer.running

  visible: root.shielding
  anchors { left: true; right: true; top: true; bottom: true }
  exclusionMode: ExclusionMode.Ignore
  color: "transparent"

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onPressed: root.clicked();
  }

  Timer {
    id: shieldTimer
    interval: 200
  }

  onActiveChanged: {
    if (root.active) shieldTimer.stop();
    else shieldTimer.restart();
  }
}
