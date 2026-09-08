import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick
import "../hyprconf"

Pill {
  id: root

  required property HyprlandMonitor monitor

  implicitWidth: wsArea.implicitWidth + 12

  // 0.56 routes hyprctl dispatch through Lua eval, so plain dispatcher
  // strings fail — focus a workspace via the Lua API instead
  Process {
    id: wsProc
    property int target: 0
    command: ["hyprctl", "eval", "hl.dsp.focus({ workspace = " + target + " })"]
  }

  Item {
    id: wsArea

    anchors.centerIn: parent
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    // accent pill that slides under the active workspace chip
    property Item activeBtn: null
    // suppress the slide on the very first placement
    property bool ready: false

    Rectangle {
      id: pill
      visible: wsArea.activeBtn !== null
      x: wsArea.activeBtn ? wsArea.activeBtn.x : 0
      width: wsArea.activeBtn ? wsArea.activeBtn.width : 0
      height: parent.height
      radius: 10
      color: Theme.hover

      Behavior on x { enabled: wsArea.ready; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      Behavior on width { enabled: wsArea.ready; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    }

    Row {
      id: row
      spacing: 6

      Repeater {
        model: ScriptModel {
          values: {
            const m = root.monitor;
            if (!m) return [];
            const list = [];
            for (const ws of Hyprland.workspaces.values)
              if (ws.monitor && ws.monitor.name == m.name && ws.id > 0) list.push(ws);
            list.sort((a, b) => a.id - b.id);
            return list;
          }
        }

        Rectangle {
          id: btn

          required property HyprlandWorkspace modelData

          readonly property bool isActive: modelData.active

          implicitWidth: label.implicitWidth + 6
          implicitHeight: label.implicitHeight + 6
          radius: 10
          color: modelData.urgent && !modelData.active
              ? Qt.alpha(Theme.live, 0.5)
              : "transparent"

          onIsActiveChanged: {
            if (isActive) {
              wsArea.activeBtn = btn;
              wsArea.ready = true;
            }
          }
          Component.onCompleted: {
            if (isActive) {
              wsArea.activeBtn = btn;
              wsArea.ready = true;
            }
          }

          Text {
            id: label
            anchors.centerIn: parent
            text: btn.modelData.name
            font.family: Theme.font
            font.bold: true
            font.pixelSize: 12
            color: mouse.containsMouse || btn.modelData.active ? Theme.text : Theme.muted
            Behavior on color { ColorAnimation { duration: 200 } }
          }

          MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              wsProc.target = btn.modelData.id;
              wsProc.running = true;
            }
          }
        }
      }
    }
  }
}
