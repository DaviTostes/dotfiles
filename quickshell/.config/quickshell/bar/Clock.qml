import Quickshell
import QtQuick
import "../hyprconf"

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
    font.family: Theme.font
    font.bold: true
    font.pixelSize: 12
    color: Theme.accent
  }

  // panel body: notifications (left) | date + calendar (right)
  Component {
    id: calendarView

    Item {
      id: panel

      implicitWidth: 488
      implicitHeight: 400

      // =============== left: notifications ===============
      Item {
        id: leftCol
        x: 0; y: 0
        width: 224; height: parent.height

        // clear-all chip (top-right)
        Rectangle {
          anchors.top: parent.top
          anchors.right: parent.right
          visible: Notifs.historyCount > 0
          width: clearLabel.implicitWidth + 12
          height: 18
          radius: 4
          color: clearMa.containsMouse ? Theme.hover : Theme.surface
          Behavior on color { ColorAnimation { duration: 200 } }

          Text {
            id: clearLabel
            anchors.centerIn: parent
            text: "clear all"
            font.family: Theme.font
            font.pixelSize: 9
            color: Theme.text
          }

          MouseArea {
            id: clearMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Notifs.clearAll()
          }
        }

        // list area (shared by list and empty state)
        Item {
          id: notifArea
          anchors.top: parent.top
          anchors.topMargin: 24
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 34
          anchors.left: parent.left
          anchors.right: parent.right

          // empty state
          Column {
            anchors.centerIn: parent
            spacing: 8
            visible: Notifs.historyCount === 0

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "\uf0a2"
              font.family: Theme.font
              font.pixelSize: 40
              color: Theme.muted
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "No Notifications"
              font.family: Theme.font
              font.bold: true
              font.pixelSize: 12
              color: Theme.muted
            }
          }

          ListView {
            id: notifList
            visible: Notifs.historyCount > 0
            anchors.fill: parent
            clip: true
            spacing: 4
            model: Notifs.historyModel

            delegate: Rectangle {
              id: row
              required property int nid
              required property string app
              required property string summary
              required property string body
              required property bool critical

              width: notifList.width
              height: rowCol.implicitHeight + 12
              radius: 5
              color: rowMa.containsMouse ? Theme.hover : Theme.surface
              Behavior on color { ColorAnimation { duration: 200 } }

              MouseArea {
                id: rowMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Notifs.open(row.nid)
              }

              Column {
                id: rowCol
                x: 8; y: 6
                width: parent.width - 16
                spacing: 2

                Row {
                  width: parent.width
                  spacing: 4

                  Rectangle {
                    visible: row.critical
                    width: 5; height: 5; radius: 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.err
                  }

                  Text {
                    width: parent.width - (row.critical ? 9 : 0)
                    elide: Text.ElideRight
                    text: row.app
                    font.family: Theme.font
                    font.pixelSize: 9
                    color: Theme.muted
                  }
                }

                Text {
                  width: parent.width
                  visible: row.summary !== ""
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: row.summary
                  font.family: Theme.font
                  font.bold: true
                  font.pixelSize: 11
                  color: Theme.text
                }

                Text {
                  width: parent.width
                  visible: row.body !== ""
                  wrapMode: Text.Wrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: row.body
                  font.family: Theme.font
                  font.pixelSize: 10
                  color: Theme.muted
                }
              }
            }
          }
        }

        // do not disturb switch
        Item {
          id: dndRow
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          width: parent.width
          height: 24

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Do Not Disturb"
              font.family: Theme.font
              font.bold: true
              font.pixelSize: 11
              color: Notifs.dnd ? Theme.accent : Theme.text
              Behavior on color { ColorAnimation { duration: 200 } }
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: 34; height: 18; radius: 9
              color: Notifs.dnd ? Theme.accent : Theme.surface
              border.color: Notifs.dnd ? Theme.accent : Theme.border
              border.width: 1
              Behavior on color { ColorAnimation { duration: 200 } }
              scale: dndMa.containsMouse ? 1.06 : 1
              Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

              Rectangle {
                x: Notifs.dnd ? parent.width - width - 3 : 3
                anchors.verticalCenter: parent.verticalCenter
                width: 12; height: 12; radius: 6
                color: Notifs.dnd ? Theme.deep : Theme.muted
                Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
              }
            }
          }

          MouseArea {
            id: dndMa
            anchors.fill: parent
            anchors.leftMargin: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Notifs.dnd = !Notifs.dnd
          }
        }
      }

      // =============== divider ===============
      Rectangle {
        x: 236; y: 0
        width: 1; height: parent.height
        color: Theme.border
      }

      // =============== right: date + calendar ===============
      Column {
        id: rightCol
        x: 248; y: 0
        width: 240
        spacing: 6

        readonly property var base: new Date()
        // month navigation state (0 = current month)
        property int monthOffset: 0

        readonly property var shown:
            new Date(base.getFullYear(), base.getMonth() + monthOffset, 1)
        readonly property int daysIn:
            new Date(shown.getFullYear(), shown.getMonth() + 1, 0).getDate()
        readonly property int offset:
            (new Date(shown.getFullYear(), shown.getMonth(), 1).getDay() + 6) % 7

        // ----- date header -----
        Text {
          text: Qt.formatDate(rightCol.base, "dddd")
          font.family: Theme.font
          font.pixelSize: 11
          color: Theme.muted
        }

        Text {
          text: Qt.formatDate(rightCol.base, "d MMMM yyyy")
          font.family: Theme.font
          font.bold: true
          font.pixelSize: 15
          color: Theme.accent
          bottomPadding: 4
        }

        // ----- month navigation -----
        Item {
          width: parent.width; height: 20

          Rectangle {
            id: prevBtn
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: 20; height: 18; radius: 4
            color: prevMa.containsMouse ? Theme.hover : "transparent"
            Behavior on color { ColorAnimation { duration: 200 } }

            Text {
              anchors.centerIn: parent
              text: "\uf104"
              font.family: Theme.font
              font.pixelSize: 10
              color: prevMa.containsMouse ? Theme.accent : Theme.text
              Behavior on color { ColorAnimation { duration: 200 } }
            }

            MouseArea {
              id: prevMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: rightCol.monthOffset--
            }
          }

          Text {
            anchors.centerIn: parent
            text: Qt.formatDate(rightCol.shown, "MMMM yyyy")
            font.family: Theme.font
            font.bold: true
            font.pixelSize: 12
            color: Theme.accent
          }

          Rectangle {
            id: nextBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 20; height: 18; radius: 4
            color: nextMa.containsMouse ? Theme.hover : "transparent"
            Behavior on color { ColorAnimation { duration: 200 } }

            Text {
              anchors.centerIn: parent
              text: "\uf105"
              font.family: Theme.font
              font.pixelSize: 10
              color: nextMa.containsMouse ? Theme.accent : Theme.text
              Behavior on color { ColorAnimation { duration: 200 } }
            }

            MouseArea {
              id: nextMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: rightCol.monthOffset++
            }
          }
        }

        // ----- weekday letters -----
        Grid {
          columns: 7
          horizontalItemAlignment: Grid.AlignHCenter
          verticalItemAlignment: Grid.AlignVCenter

          Repeater {
            model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

            Text {
              required property string modelData
              width: 34
              horizontalAlignment: Text.AlignHCenter
              text: modelData
              font.family: Theme.font
              font.pixelSize: 10
              color: Theme.muted
              bottomPadding: 2
            }
          }
        }

        // ----- day grid (with adjacent-month days, dimmed) -----
        Grid {
          columns: 7
          horizontalItemAlignment: Grid.AlignHCenter
          verticalItemAlignment: Grid.AlignVCenter

          Repeater {
            model: 42

            Item {
              id: cell

              readonly property var date:
                  new Date(rightCol.shown.getFullYear(),
                           rightCol.shown.getMonth(), 1 - rightCol.offset + index)
              readonly property bool inMonth:
                  date.getMonth() === rightCol.shown.getMonth()
              readonly property bool weekend: index % 7 >= 5
              readonly property bool isToday:
                  date.getFullYear() === rightCol.base.getFullYear()
                  && date.getMonth() === rightCol.base.getMonth()
                  && date.getDate() === rightCol.base.getDate()

              width: 34
              height: 22

              Rectangle {
                anchors.centerIn: parent
                width: 20; height: 20; radius: 10
                color: Theme.accent
                visible: cell.isToday
              }

              Text {
                anchors.centerIn: parent
                text: cell.date.getDate()
                font.family: Theme.font
                font.bold: cell.isToday
                font.pixelSize: 11
                color: !cell.inMonth ? Theme.muted
                    : cell.isToday ? Theme.deep
                    : cell.weekend ? Theme.muted
                    : Theme.text
              }
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
