import QtQuick
import "../hyprconf"

Pill {
  id: root

  implicitWidth: label.implicitWidth + 20

  Text {
    id: label
    anchors.centerIn: parent
    textFormat: Text.RichText
    font.family: Theme.font
    font.pixelSize: 14
    color: Notifs.dnd ? Theme.muted : Theme.accent
    text: (Notifs.dnd ? "\uf1f7" : "\uf0a2")
        + (Notifs.historyCount > 0 ? "<span style=\"color:" + Theme.err + "\"><sup>\uf444</sup></span>" : "");
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    // left: toggle do-not-disturb · right: clear everything
    onClicked: mouse => {
      if (mouse.button === Qt.RightButton)
        Notifs.clearAll();
      else
        Notifs.dnd = !Notifs.dnd;
    }
  }

  Tip {
    target: root
    shown: mouse.containsMouse
    text: Notifs.dnd ? "do not disturb"
        : Notifs.historyCount + " notification" + (Notifs.historyCount === 1 ? "" : "s")
    subtitle: "click: dnd · right-click: clear all"
  }
}
