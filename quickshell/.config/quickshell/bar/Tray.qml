import Quickshell
import Quickshell.Io
import Quickshell.Services.SystemTray
import QtQuick

Pill {
  id: root

  implicitWidth: row.implicitWidth + 20
  visible: SystemTray.items.values.length > 0

  // exposed so the bar can hold keyboard focus while the menu is open
  // (popups can't grab focus themselves) — this is what lets Esc reach it
  readonly property alias menuOpen: trayMenu.open

  // click-outside duty for the tray menu
  Catcher {
    active: trayMenu.open
    onClicked: trayMenu.closeMenu()
  }

  TrayMenu {
    id: trayMenu
  }

  // Steam's tray item (libayatana-appindicator) exposes no Activate method,
  // so item.activate() is a silent no-op. Relaunching the client instead
  // focuses (or opens) its main window.
  Process {
    id: steamOpen
    command: ["steam", "steam://open/main"]
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

            const toggleMenu = () => {
              if (trayMenu.open && trayMenu.targetItem === icon)
                trayMenu.closeMenu();
              else
                trayMenu.openFor(icon, item.menu);
            };

            // left activates the app (menu-only items open the menu;
            // Steam, whose appindicator item has no Activate method, gets
            // its window re-opened through the steam:// handler); right
            // toggles the menu; middle does the item's secondary action
            if (mouse.button === Qt.RightButton) {
              if (item.menu) toggleMenu();
            } else if (mouse.button === Qt.MiddleButton) {
              item.secondaryActivate();
            } else if (mouse.button === Qt.LeftButton) {
              if (item.onlyMenu && item.menu)
                toggleMenu();
              else if (item.id === "steam")
                steamOpen.running = true;
              else
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
