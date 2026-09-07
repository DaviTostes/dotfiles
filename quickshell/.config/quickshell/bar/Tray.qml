import Quickshell
import Quickshell.Services.SystemTray
import QtQuick

Pill {
  id: root

  property Item menuTarget: null

  implicitWidth: row.implicitWidth + 20
  visible: SystemTray.items.values.length > 0

  QsMenuAnchor {
    id: menuAnchor

    anchor {
      window: root.QsWindow.window
      item: root.menuTarget
      edges: Edges.Top
      gravity: Edges.Bottom
      margins.top: 6
    }
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 4

    Repeater {
      model: SystemTray.items

      Item {
        id: icon

        required property SystemTrayItem modelData

        implicitWidth: 16
        implicitHeight: 16

        Image {
          anchors.fill: parent
          source: icon.modelData.icon
          sourceSize.width: 16
          sourceSize.height: 16
          fillMode: Image.PreserveAspectFit
          mipmap: true
        }

        MouseArea {
          id: mouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
          cursorShape: Qt.PointingHandCursor
          onClicked: mouse => {
            const item = icon.modelData;
            if ((mouse.button === Qt.RightButton || (mouse.button === Qt.LeftButton && item.onlyMenu)) && item.menu) {
              root.menuTarget = icon;
              menuAnchor.menu = item.menu;
              menuAnchor.open();
            } else if (mouse.button === Qt.MiddleButton) {
              item.secondaryActivate();
            } else if (mouse.button === Qt.LeftButton) {
              item.activate();
            }
          }
        }

        Tip {
          target: icon
          shown: mouse.containsMouse
          text: icon.modelData.tooltipTitle || icon.modelData.title
          subtitle: {
            const d = icon.modelData.tooltipDescription;
            const t = icon.modelData.tooltipTitle || icon.modelData.title;
            return d && d !== t ? d : "";
          }
        }
      }
    }
  }
}
