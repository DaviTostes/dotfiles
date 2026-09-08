import Quickshell
import Quickshell.Services.SystemTray
import QtQuick

Pill {
  id: root

  implicitWidth: row.implicitWidth + 20
  visible: SystemTray.items.values.length > 0

  // click-outside duty for the tray menu
  Catcher {
    active: trayMenu.open
    onClicked: trayMenu.closeMenu()
  }

  TrayMenu {
    id: trayMenu
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
            // left and right click both open the menu; middle does the
            // item's secondary action
            if ((mouse.button === Qt.RightButton || mouse.button === Qt.LeftButton) && item.menu) {
              trayMenu.openFor(icon, item.menu);
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
