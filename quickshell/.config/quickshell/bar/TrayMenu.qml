import Quickshell
import QtQuick
import "../hyprconf"

// Pomodoro-styled tray context menu. quickshell's QsMenuAnchor renders the
// platform menu (unstyleable Qt-default look); this wraps QsMenuOpener in
// our own popup instead. Entries with submenus still fall through to the
// platform renderer (entry.display) — sub-styling is a different fight.
PopupWindow {
  id: menu

  property var targetItem: null   // tray icon Item (anchor)
  property var handle: null       // SystemTray menu handle
  property bool open: false

  // stays mapped briefly while closing so the fade can play
  visible: open || hideTimer.running
  color: "transparent"
  implicitWidth: menuList.width + 2
  implicitHeight: Math.max(menuList.height + 2, 12)

  Timer { id: hideTimer; interval: 170 }

  function openFor(item, handle) {
    menu.targetItem = item;
    menu.handle = handle;
    menu.open = true;
    menuList.maxW = 120;
    hideTimer.stop();
    Qt.callLater(menu.anchor.updateAnchor);
  }

  function closeMenu() {
    if (menu.open) hideTimer.restart();
    menu.open = false;
  }

  QsMenuOpener {
    id: opener
    menu: menu.handle
  }

  anchor {
    window: menu.targetItem ? menu.targetItem.QsWindow.window : null
    edges: Edges.Top
    gravity: Edges.Bottom
  }

  anchor.onAnchoring: {
    if (!menu.targetItem) return;
    const p = menu.targetItem.mapToItem(null, 0, 0);
    anchor.rect.x = p.x;
    anchor.rect.y = p.y + menu.targetItem.height + 6;
    anchor.rect.width = menu.targetItem.width;
    anchor.rect.height = 1;
  }

  Rectangle {
    id: menuBg
    anchors.fill: parent
    color: Theme.bg
    radius: 6
    border.color: Theme.border
    border.width: 1
    opacity: menu.open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
    transform: Translate {
      y: menu.open ? 0 : -6
      Behavior on y { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
    }

    ListView {
      id: menuList
      anchors.centerIn: parent
      width: maxW + 24
      height: Math.min(contentHeight, 410)
      clip: true
      model: opener.children
      boundsBehavior: Flickable.StopAtBounds

      property int maxW: 120

      delegate: Item {
        id: entryRow

        required property var modelData

        width: menuList.width
        height: modelData.isSeparator ? 9 : 26

        // ----- separator -----
        Rectangle {
          visible: entryRow.modelData.isSeparator
          anchors.centerIn: parent
          width: parent.width - 20
          height: 1
          color: Theme.border
        }

        // ----- entry -----
        Rectangle {
          visible: !entryRow.modelData.isSeparator
          anchors.fill: parent
          anchors.leftMargin: 4
          anchors.rightMargin: 4
          radius: 4
          color: entryMa.containsMouse && entryRow.modelData.enabled
                 ? Theme.hover : "transparent"
          Behavior on color { ColorAnimation { duration: 200 } }

          Text {
            id: checkMark
            visible: entryRow.modelData.buttonType !== QsMenuButtonType.None
            anchors.left: parent.left
            anchors.leftMargin: 9
            anchors.verticalCenter: parent.verticalCenter
            text: entryRow.modelData.checkState === Qt.Checked ? "\ueab7"
                : entryRow.modelData.checkState === Qt.PartiallyChecked
                ? "\ueab9" : "\ueab8"
            font.family: Theme.font
            font.pixelSize: 11
            color: entryRow.modelData.enabled ? Theme.accent : Theme.muted
          }

          Text {
            id: entryText
            anchors.left: checkMark.visible ? checkMark.right : parent.left
            anchors.leftMargin: checkMark.visible ? 8 : 9
            anchors.right: parent.right
            anchors.rightMargin: subArrow.visible ? 24 : 12
            anchors.verticalCenter: parent.verticalCenter
            text: entryRow.modelData.text
            font.family: Theme.font
            font.pixelSize: 11
            color: entryRow.modelData.enabled ? Theme.text : Theme.muted
            elide: Text.ElideRight
            onImplicitWidthChanged:
                menuList.maxW = Math.max(menuList.maxW, implicitWidth + 46)
          }

          Text {
            id: subArrow
            visible: entryRow.modelData.hasChildren
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf105"
            font.family: Theme.font
            font.pixelSize: 10
            color: Theme.muted
          }

          MouseArea {
            id: entryMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            enabled: entryRow.modelData.enabled && !entryRow.modelData.isSeparator
            onClicked: {
              const e = entryRow.modelData;
              if (e.hasChildren) {
                // platform-rendered submenu at this row's edge
                const p = entryRow.mapToItem(menuBg, 0, 0);
                const win = menu.QsWindow.window;
                menu.closeMenu();
                e.display(win, p.x + entryRow.width - 10, p.y + 13);
              } else {
                e.triggered();
                menu.closeMenu();
              }
            }
          }
        }
      }
    }
  }
}
