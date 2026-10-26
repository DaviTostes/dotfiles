import QtQuick
import "../hyprconf"

// Vertical fan of the intelligence central's mode pills.
//
// The dock is a single wheel pill in the bar's bottom group; hovering it (or
// the space just above it) makes the mode pills rise into a column.
// Calculator sits nearest the wheel, then translate, with OCR on top; the
// wheel itself is chat.
//
// This is a plain Item inside the bar surface on purpose: a hover-driven
// PopupWindow would pay a whole layer-window build on every pass of the
// pointer (see Tip.qml). The container also covers the wheel itself and only
// uses a passive HoverHandler, so moving the pointer from the wheel up into
// the fan never drops the hover and the wheel keeps its click. It must stay
// hidden while the docked panel is open: the fullscreen Catcher owns pointer
// input then.
Item {
  id: fan

  // the Opencode pill this fan belongs to
  property Item target: null
  // reactive copy of target.mode (kept as a binding so the delegate can read it)
  readonly property string currentMode: target ? target.mode : ""
  readonly property bool available: target !== null && !target.standalone && !target.panelOpen

  readonly property int pillH: fan.target && fan.target.wheelH ? fan.target.wheelH : 28
  readonly property int gap: fan.target && fan.target.fanGap ? fan.target.fanGap : 4
  // top -> bottom: ocr, translate, calculator. The wheel itself opens chat,
  // so it is not duplicated as a fan pill; calc sits nearest the wheel.
  readonly property var modes: [
    { id: "ocr", icon: "\uf03e", label: "ocr" },
    { id: "translate", icon: "\uf1ab", label: "translate" },
    { id: "calc", icon: "\uf1ec", label: "calc" }
  ]
  readonly property int fanH: modes.length * pillH + (modes.length - 1) * gap
  readonly property real stagger: 0.16
  readonly property real span: Math.max(0.2, 1 - (modes.length - 1) * stagger)
  readonly property int expandedHeight: pillH + gap + fanH

  // bottom edge sits on the wheel's bottom. When collapsed the item is only
  // as tall as the wheel, so hovering the empty space far above the dock never
  // opens the fan; it grows to `expandedHeight` only once the wheel is hovered.
  anchors.bottom: parent.bottom
  anchors.horizontalCenter: parent.horizontalCenter
  width: parent.width
  height: revealed ? expandedHeight : pillH
  z: 50

  readonly property bool hovered: hoverHandler.hovered
  // reveal on hover, collapse after a short grace so the gap between the
  // wheel and the first pill cannot flicker
  readonly property bool revealed: available && (hovered || hideTimer.running)
  property real progress: revealed ? 1 : 0
  Behavior on progress {
    NumberAnimation { duration: 240; easing.type: Easing.OutCubic }
  }

  onHoveredChanged: {
    if (hovered) hideTimer.stop();
    else if (revealed) hideTimer.restart();
  }

  HoverHandler { id: hoverHandler }
  Timer { id: hideTimer; interval: 140 }

  Column {
    id: stack

    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: fan.pillH + fan.gap
    spacing: fan.gap

    Repeater {
      model: fan.modes

      delegate: Rectangle {
        id: modePill

        required property var modelData
        required property int index

        readonly property bool cur: fan.currentMode === modePill.modelData.id
        // the row nearest the wheel starts first; each upper pill joins ~40 ms
        // later (span accounts for the reduced row count)
        readonly property real p: Math.max(0, Math.min(1,
            (fan.progress - (fan.modes.length - 1 - modePill.index) * fan.stagger) / fan.span))

        width: fan.width
        height: fan.pillH
        radius: 6
        color: modeMa.containsMouse ? Theme.hover : Theme.surface
        border.width: 1
        border.color: modePill.cur ? Theme.accent2 : Theme.border
        // invisible pills must not catch clicks in the reserved (empty) fan
        // area above the wheel
        enabled: fan.revealed
        opacity: modePill.p
        scale: 0.9 + 0.1 * modePill.p
        transform: Translate { y: (1 - modePill.p) * 10 }
        Behavior on color { ColorAnimation { duration: 180 } }

        Text {
          anchors.centerIn: parent
          text: modePill.modelData.icon
          font.family: Theme.font
          font.pixelSize: 13
          color: modePill.cur ? Theme.accent : (modeMa.containsMouse ? Theme.text : Theme.muted)
          Behavior on color { ColorAnimation { duration: 180 } }
        }

        MouseArea {
          id: modeMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (fan.target) fan.target.openMode(modePill.modelData.id)
        }

        Tip {
          target: modePill
          shown: modeMa.containsMouse && fan.revealed
          leftOfTarget: true
          text: modePill.modelData.label
        }
      }
    }
  }
}
