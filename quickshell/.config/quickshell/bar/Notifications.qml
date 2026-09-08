import Quickshell
import Quickshell.Io
import QtQuick
import "../hyprconf"

Pill {
  id: root

  property string state: "none"

  implicitWidth: label.implicitWidth + 20

  Process {
    id: sub
    command: ["swaync-client", "-swb"]
    running: true

    stdout: SplitParser {
      onRead: data => {
        try { root.state = JSON.parse(data).class || "none"; } catch (e) {}
      }
    }

    onExited: restartTimer.start()
  }
  Timer {
    id: restartTimer
    interval: 5000
    onTriggered: sub.running = true
  }

  Text {
    id: label
    anchors.centerIn: parent
    textFormat: Text.RichText
    font.family: Theme.font
    font.pixelSize: 14
    color: Theme.accent
    text: {
      const dnd = root.state.indexOf("dnd") !== -1;
      const has = root.state.indexOf("notification") !== -1;
      return (dnd ? "\uf1f7" : "\uf0a2")
          + (has ? "<span style=\"color:" + Theme.err + "\"><sup>\uf444</sup></span>" : "");
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: mouse => Quickshell.execDetached([
      "swaync-client",
      mouse.button === Qt.RightButton ? "-d" : "-t",
      "-sw"
    ])
  }
}
