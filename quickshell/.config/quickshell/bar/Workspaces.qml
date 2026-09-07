import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick

Pill {
  id: root

  required property HyprlandMonitor monitor

  implicitWidth: row.implicitWidth + 12

  // 0.56 routes hyprctl dispatch through Lua eval, so plain dispatcher
  // strings fail — focus a workspace via the Lua API instead
  Process {
    id: wsProc
    property int target: 0
    command: ["hyprctl", "eval", "hl.dsp.focus({ workspace = " + target + " })"]
  }

  Row {
    id: row
    anchors.centerIn: parent
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

        implicitWidth: label.implicitWidth + 6
        implicitHeight: label.implicitHeight + 6
        radius: 10
        color: modelData.urgent && !modelData.active
            ? Qt.rgba(166 / 255, 227 / 255, 161 / 255, 0.5)
            : "transparent"

        Text {
          id: label
          anchors.centerIn: parent
          text: btn.modelData.name
          font.family: "Agave Nerd Font"
          font.bold: true
          font.pixelSize: 12
          color: mouse.containsMouse || btn.modelData.active ? "#ffffff" : "#6a6a6a"
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
