import QtQuick
import "../hyprconf"

Rectangle {
  implicitHeight: 28
  radius: 6
  color: Theme.pill

  // while this pill's own dropdown/panel is open, draw the same inset
  // surface + border the opencode pill uses (its inner rectangle), so every
  // pill gets that little "open" outline. Set `pillOpen` on the derived pill.
  property bool pillOpen: false

  Rectangle {
    anchors.fill: parent
    anchors.margins: 2
    radius: 6
    color: pillOpen ? Theme.surface : "transparent"
    border.width: pillOpen ? 1 : 0
    border.color: Theme.border
    Behavior on color { ColorAnimation { duration: 180 } }
  }
}
