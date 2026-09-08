import Quickshell
import Quickshell.Services.UPower
import QtQuick
import "../hyprconf"

Pill {
  id: root

  readonly property UPowerDevice dev: UPower.displayDevice
  readonly property bool charging: dev.state === UPowerDeviceState.Charging
      || dev.state === UPowerDeviceState.PendingCharge
      || dev.state === UPowerDeviceState.FullyCharged

  visible: dev.isLaptopBattery
  implicitWidth: label.implicitWidth + 16

  Text {
    id: label
    anchors.centerIn: parent
    font.family: Theme.font
    font.bold: true
    font.pixelSize: 12
    color: root.charging || root.dev.percentage > 15 ? Theme.accent : Theme.err
    Behavior on color { ColorAnimation { duration: 200 } }

    // soft pulse while discharging low
    SequentialAnimation on opacity {
      loops: Animation.Infinite
      alwaysRunToEnd: true
      running: root.dev.ready && !root.charging && root.dev.percentage <= 15
      NumberAnimation { to: 0.35; duration: 600 }
      NumberAnimation { to: 1; duration: 600 }
    }

    text: {
      if (!root.dev.ready) return "";
      if (root.charging) return "󱐋";
      const icons = ["󰂎", "󰁼", "󰁿", "󰂁", "󰁹"];
      const p = Math.max(0, Math.min(100, Math.floor(root.dev.percentage)));
      return icons[Math.min(4, Math.floor(p / 20))];
    }
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
  }

  Tip {
    target: root
    shown: hover.containsMouse && root.dev.ready
    text: Math.round(root.dev.percentage) + "%"
  }
}
