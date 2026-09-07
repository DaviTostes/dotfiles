import Quickshell
import QtQuick

Pill {
  id: root

  implicitWidth: clockText.implicitWidth + 12

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }

  Text {
    id: clockText
    anchors.centerIn: parent
    text: Qt.formatDateTime(clock.date, "ddd dd, HH:mm")
    font.family: "Agave Nerd Font"
    font.bold: true
    font.pixelSize: 12
    color: "#dcdfe1"
  }

  Component {
    id: calendarView

    Column {
      id: cal

      readonly property var d: new Date()
      readonly property int today: d.getDate()
      readonly property int daysIn: new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate()
      readonly property int offset: (new Date(d.getFullYear(), d.getMonth(), 1).getDay() + 6) % 7

      // palette (matches the bar/swaync theme)
      readonly property color fg: "#dcdfe1"
      readonly property color muted: "#6a6a6a"
      readonly property color accent: "#ffcc66"
      readonly property color highlight: "#2e2e2e"

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: Qt.formatDateTime(cal.d, "MMMM yyyy")
        font.family: "Agave Nerd Font"
        font.bold: true
        font.pixelSize: 12
        color: "#ffffff"
        bottomPadding: 2
      }

      Grid {
        columns: 7
        horizontalItemAlignment: Grid.AlignHCenter
        verticalItemAlignment: Grid.AlignVCenter

        Repeater {
          model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

          Text {
            required property string modelData
            width: 22
            horizontalAlignment: Text.AlignHCenter
            text: modelData
            font.family: "Agave Nerd Font"
            font.pixelSize: 10
            color: cal.muted
            bottomPadding: 2
          }
        }

        Repeater {
          model: 42

          Item {
            id: cell

            readonly property int day: index - cal.offset + 1
            readonly property bool valid: day >= 1 && day <= cal.daysIn
            readonly property bool weekend: index % 7 >= 5
            readonly property bool isToday: valid && day === cal.today

            width: 22
            height: 18

            Rectangle {
              anchors.fill: parent
              radius: 4
              color: cal.highlight
              visible: cell.isToday
            }

            Text {
              anchors.centerIn: parent
              text: cell.valid ? cell.day : ""
              font.family: "Agave Nerd Font"
              font.bold: cell.isToday
              font.pixelSize: 11
              color: !cell.valid ? "transparent"
                  : cell.isToday ? cal.accent
                  : cell.weekend ? cal.muted
                  : cal.fg
            }
          }
        }
      }
    }
  }

  // opens on click only; the catcher closes it on any outside click
  property bool calOpen: false

  Catcher {
    active: root.calOpen
    onClicked: root.calOpen = false
  }

  MouseArea {
    id: click
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.calOpen = !root.calOpen
  }

  Tip {
    target: root
    shown: root.calOpen
    content: calendarView
  }
}
