import Quickshell
import Quickshell.Services.Notifications
import QtQuick
import "../hyprconf"

// Per-monitor toast stack: shows every notification currently tracked by
// the Notifs server (shared singleton), top-right, auto-expiring. Panel
// window so toasts are never clipped by the bar surface. The whole toast
// is clickable: invokes the app's default action (or dismisses when the
// app sent no actions).
PanelWindow {
  id: root

  anchors { top: true; right: true }
  exclusionMode: ExclusionMode.Ignore
  color: "transparent"
  margins { top: 34; right: 8 }

  visible: Notifs.pending > 0
  implicitWidth: 344
  // never let a big burst of toasts spill off the bottom of the screen
  implicitHeight: Math.min(stack.implicitHeight + 16,
                           (root.screen ? root.screen.height : 1080) - 60)

  Item {
    anchors.fill: parent

    Column {
      id: stack
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: 6

      Repeater {
        model: Notifs.toastList

        Rectangle {
          id: toast
          required property var modelData
          readonly property var n: modelData
          readonly property bool critical: n.urgency === NotificationUrgency.Critical
          // honor the app's timeout hint when it sent one (ms); fall back
          // to 12s / 20s (critical)
          readonly property int duration: n.expireTimeout > 0
              ? Math.max(3000, Math.min(30000, n.expireTimeout))
              : (critical ? 20000 : 12000)

          width: 344
          height: col.implicitHeight + 16
          radius: 6
          color: Theme.bg
          border.color: critical ? Theme.err : Theme.border
          border.width: 1
          Behavior on border.color { ColorAnimation { duration: 200 } }

          // auto-expire; paused while hovered
          Timer {
            id: expireTimer
            interval: toast.duration
            running: true
            // hide the visual only — the notification stays alive so its
            // actions remain invocable from the history
            onTriggered: Notifs.hideToast(toast.n)
          }

          MouseArea {
            id: toastMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            // whole toast clickable: open the default action and dismiss
            onClicked: Notifs.open(toast.n.id)
            onContainsMouseChanged: containsMouse ? expireTimer.stop() : expireTimer.restart()
          }

          Column {
            id: col
            x: 10; y: 8
            width: parent.width - 20
            spacing: 3

            Row {
              width: parent.width

              Text {
                width: parent.width - 18
                elide: Text.ElideRight
                text: toast.n.appName
                font.family: Theme.font
                font.pixelSize: 10
                color: Theme.muted
              }

              // dismiss-only: hides the toast without invoking the action
              Text {
                text: "\uf00d"
                font.family: Theme.font
                font.pixelSize: 12
                color: closeMa.containsMouse ? Theme.accent : Theme.muted
                Behavior on color { ColorAnimation { duration: 200 } }

                MouseArea {
                  id: closeMa
                  anchors.fill: parent
                  anchors.margins: -4
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: Notifs.hideToast(toast.n)
                }
              }
            }

            Text {
              width: parent.width
              visible: toast.n.summary !== ""
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: toast.n.summary
              font.family: Theme.font
              font.bold: true
              font.pixelSize: 14
              color: Theme.text
            }

            Text {
              width: parent.width
              visible: toast.n.body !== ""
              wrapMode: Text.Wrap
              maximumLineCount: 5
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: toast.n.body
              font.family: Theme.font
              font.pixelSize: 15
              color: Theme.muted
            }

            Row {
              spacing: 5

              Repeater {
                // "Settings"-style extra actions are dropped (and the app's
                // "Activate" is the whole-toast click already); `actions` can
                // come back null-ish, hence the guard
                model: (toast.n.actions || []).filter(
                    a => a.text !== "" && a.text !== "Activate"
                        && a.text.toLowerCase() !== "settings")

                Rectangle {
                  required property var modelData
                  readonly property var action: modelData
                  readonly property string label:
                      action.text === "Activate" ? "Open" : action.text

                  width: actionLabel.implicitWidth + 12
                  height: 18
                  radius: 4
                  color: actionMa.containsMouse ? Theme.hover : Theme.surface
                  Behavior on color { ColorAnimation { duration: 200 } }
                  scale: actionMa.containsMouse ? 1.06 : 1
                  Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                  Text {
                    id: actionLabel
                    anchors.centerIn: parent
                    text: parent.label
                    font.family: Theme.font
                    font.pixelSize: 12
                    color: Theme.text
                  }

                  MouseArea {
                    id: actionMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      parent.action.invoke();
                      Notifs.hideToast(toast.n);
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
