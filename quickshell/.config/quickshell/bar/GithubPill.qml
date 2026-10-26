import Quickshell
import QtQuick
import "../hyprconf"

// GitHub status pill for the top bar, left of the tray. Reads the shared
// Github singleton (one poller for every monitor) and opens a click panel
// with open PRs, running Actions and unread notifications.
Pill {
  id: root

  property bool panelOpen: false
  pillOpen: panelOpen

  implicitWidth: pillRow.implicitWidth + 16

  readonly property string ico: "\uf09b"   // Font Awesome github

  Row {
    id: pillRow
    anchors.centerIn: parent
    spacing: 3

    Text {
      id: icoText
      anchors.verticalCenter: parent.verticalCenter
      text: root.ico
      font.family: Theme.font
      font.pixelSize: 14
      color: Github.error !== "" ? Theme.err
          : Github.unreadCount > 0 ? Theme.accent
          : Theme.text
      Behavior on color { ColorAnimation { duration: 200 } }
    }

    Text {
      id: countText
      visible: Github.prCount > 0
      anchors.verticalCenter: parent.verticalCenter
      text: Github.prCount
      font.family: Theme.font
      font.pixelSize: 10
      color: Github.error !== "" ? Theme.err : Theme.accent
    }
  }

  // unread notification bubble
  Rectangle {
    id: unreadBadge
    visible: Github.unreadCount > 0
    anchors.right: parent.right
    anchors.rightMargin: 2
    anchors.top: parent.top
    anchors.topMargin: 2
    width: Math.max(10, unreadText.implicitWidth + 4)
    height: 10
    radius: 5
    color: Theme.err

    Text {
      id: unreadText
      anchors.centerIn: parent
      text: Github.unreadCount > 9 ? "9+" : Github.unreadCount
      font.family: Theme.font
      font.bold: true
      font.pixelSize: 7
      color: Theme.deep
    }
  }

  // running Actions indicator
  Rectangle {
    visible: Github.runningCount > 0
    anchors.right: parent.right
    anchors.rightMargin: 4
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 4
    width: 4
    height: 4
    radius: 2
    color: Theme.live
  }

  MouseArea {
    id: click
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.panelOpen = !root.panelOpen
  }

  onPanelOpenChanged: {
    if (root.panelOpen) {
      Github.panelsOpen++;
      Github.refresh();
    } else {
      Github.panelsOpen = Math.max(0, Github.panelsOpen - 1);
    }
  }

  Component.onDestruction: {
    if (root.panelOpen) Github.panelsOpen = Math.max(0, Github.panelsOpen - 1);
  }

  // click-outside close, pinned to this bar's monitor
  Catcher {
    screen: root.QsWindow.window ? root.QsWindow.window.screen : null
    active: root.panelOpen
    onClicked: root.panelOpen = false
  }

  Tip {
    target: root
    shown: root.panelOpen
    showDelay: 0
    content: panelView
  }

  Component {
    id: panelView

    Flickable {
      id: panel

      implicitWidth: 460
      implicitHeight: Math.min(content.implicitHeight, 560)
      contentWidth: width
      contentHeight: content.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      property double nowMs: Date.now()

      Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: panel.nowMs = Date.now()
      }

      function ago(ms) {
        if (!ms || ms <= 0) return "not yet";
        const s = Math.max(0, Math.floor((panel.nowMs - ms) / 1000));
        if (s < 60) return s + "s ago";
        const m = Math.floor(s / 60);
        if (m < 60) return m + "m ago";
        const h = Math.floor(m / 60);
        if (h < 24) return h + "h ago";
        return Math.floor(h / 24) + "d ago";
      }

      function age(iso) {
        const t = Date.parse(iso);
        return isNaN(t) ? "" : panel.ago(t);
      }

      function checkColor(state) {
        if (state === "failed") return Theme.err;
        if (state === "running") return Theme.accent;
        if (state === "passed") return Theme.live;
        return Theme.idleText;
      }

      function reviewLabel(m) {
        if (m.reviewDecision === "APPROVED") return "approved";
        if (m.reviewDecision === "CHANGES_REQUESTED") return "changes";
        if (m.reviewDecision === "REVIEW_REQUIRED") return "review";
        return "";
      }

      function reviewColor(m) {
        if (m.reviewDecision === "APPROVED") return Theme.live;
        if (m.reviewDecision === "CHANGES_REQUESTED") return Theme.err;
        return Theme.muted;
      }

      function openUrl(url) {
        if (url !== "") Quickshell.execDetached(["xdg-open", url]);
        root.panelOpen = false;
      }

      Column {
        id: content
        width: panel.width
        spacing: 6

        // ----- header -----
        Item {
          width: parent.width
          implicitHeight: 22

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            Text {
              text: Github.login !== "" ? Github.login : "GitHub"
              font.family: Theme.font
              font.bold: true
              font.pixelSize: 12
              color: Theme.accent
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: Github.loading
                  ? "refreshing…"
                  : "updated " + panel.ago(Github.lastUpdated)
              font.family: Theme.font
              font.pixelSize: 9
              color: Theme.muted
            }
          }

          Rectangle {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: refreshLabel.implicitWidth + 12
            height: 18
            radius: 4
            color: refreshMa.containsMouse && !Github.loading ? Theme.hover : Theme.surface
            Behavior on color { ColorAnimation { duration: 180 } }

            Text {
              id: refreshLabel
              anchors.centerIn: parent
              text: "refresh"
              font.family: Theme.font
              font.pixelSize: 9
              color: Github.loading ? Theme.muted : Theme.text
            }

            MouseArea {
              id: refreshMa
              anchors.fill: parent
              hoverEnabled: true
              enabled: !Github.loading
              cursorShape: Qt.PointingHandCursor
              onClicked: Github.retry()
            }
          }
        }

        Text {
          width: parent.width
          visible: Github.error !== ""
          text: Github.error
          wrapMode: Text.Wrap
          maximumLineCount: 3
          elide: Text.ElideRight
          textFormat: Text.PlainText
          font.family: Theme.font
          font.pixelSize: 10
          color: Theme.err
        }

        // ----- unread notifications -----
        Text {
          width: parent.width
          text: "NOTIFICATIONS  ·  " + Github.unreadCount + " unread"
          font.family: Theme.font
          font.bold: true
          font.pixelSize: 9
          color: Theme.muted
          topPadding: 2
        }

        Text {
          width: parent.width
          visible: Github.unreadCount === 0
          x: 8
          text: "no unread notifications"
          font.family: Theme.font
          font.pixelSize: 10
          color: Theme.idleText
        }

        Repeater {
          model: Github.notifications

          Rectangle {
            required property var modelData
            width: content.width
            height: 38
            radius: 5
            color: notifMa.containsMouse ? Theme.hover : Theme.surface
            Behavior on color { ColorAnimation { duration: 150 } }

            Column {
              x: 8
              y: 4
              width: parent.width - 16
              spacing: 1

              Text {
                width: parent.width
                elide: Text.ElideRight
                text: (modelData.type === "CheckSuite" ? "CI" : "PR")
                    + " · " + modelData.repo
                    + (modelData.reason !== "" ? " · " + modelData.reason : "")
                font.family: Theme.font
                font.pixelSize: 9
                color: Theme.muted
              }

              Text {
                width: parent.width
                elide: Text.ElideRight
                text: modelData.title
                font.family: Theme.font
                font.pixelSize: 11
                color: Theme.text
              }
            }

            Text {
              anchors.right: parent.right
              anchors.rightMargin: 8
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 4
              text: panel.age(modelData.updatedAt)
              font.family: Theme.font
              font.pixelSize: 8
              color: Theme.muted
            }

            MouseArea {
              id: notifMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: panel.openUrl(modelData.url)
            }
          }
        }

        // ----- running Actions -----
        Text {
          width: parent.width
          text: "ACTIONS  ·  " + Github.runningCount + " running"
          font.family: Theme.font
          font.bold: true
          font.pixelSize: 9
          color: Theme.muted
          topPadding: 2
        }

        Text {
          width: parent.width
          visible: Github.runningCount === 0
          x: 8
          text: "nothing running"
          font.family: Theme.font
          font.pixelSize: 10
          color: Theme.idleText
        }

        Repeater {
          model: Github.runs

          Rectangle {
            required property var modelData
            width: content.width
            height: 34
            radius: 5
            color: runMa.containsMouse ? Theme.hover : Theme.surface
            Behavior on color { ColorAnimation { duration: 150 } }

            Column {
              x: 8
              y: 4
              width: parent.width - 16
              spacing: 1

              Text {
                width: parent.width
                elide: Text.ElideRight
                text: modelData.name
                font.family: Theme.font
                font.pixelSize: 11
                color: Theme.text
              }

              Text {
                width: parent.width
                elide: Text.ElideRight
                text: modelData.repo + " · " + modelData.branch
                    + " · " + (modelData.status === "in_progress" ? "running"
                                                               : modelData.status)
                font.family: Theme.font
                font.pixelSize: 9
                color: Theme.muted
              }
            }

            MouseArea {
              id: runMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: panel.openUrl(modelData.url)
            }
          }
        }

        // ----- open pull requests -----
        Text {
          width: parent.width
          text: "PULL REQUESTS  ·  " + Github.prCount
          font.family: Theme.font
          font.bold: true
          font.pixelSize: 9
          color: Theme.muted
          topPadding: 2
        }

        Text {
          width: parent.width
          visible: Github.prCount === 0
          x: 8
          text: "no open pull requests"
          font.family: Theme.font
          font.pixelSize: 10
          color: Theme.idleText
        }

        Repeater {
          model: Github.prs

          Rectangle {
            id: prRow
            required property var modelData
            width: content.width
            height: 38
            radius: 5
            color: prMa.containsMouse ? Theme.hover : Theme.surface
            Behavior on color { ColorAnimation { duration: 150 } }

            Column {
              x: 8
              y: 5
              width: parent.width - 26
              spacing: 1

              Row {
                width: parent.width
                spacing: 5

                Text {
                  width: Math.max(0, parent.width - draftText.width - reviewText.width - 10)
                  elide: Text.ElideRight
                  text: modelData.repo + "#" + modelData.number
                  font.family: Theme.font
                  font.pixelSize: 9
                  color: Theme.muted
                }

                Text {
                  id: draftText
                  visible: modelData.isDraft
                  text: "draft"
                  font.family: Theme.font
                  font.pixelSize: 9
                  color: Theme.idleText
                }

                Text {
                  id: reviewText
                  visible: panel.reviewLabel(modelData) !== ""
                  text: panel.reviewLabel(modelData)
                  font.family: Theme.font
                  font.pixelSize: 9
                  color: panel.reviewColor(modelData)
                }
              }

              Text {
                width: parent.width
                elide: Text.ElideRight
                text: modelData.title
                font.family: Theme.font
                font.pixelSize: 11
                color: Theme.text
              }
            }

            Rectangle {
              anchors.right: parent.right
              anchors.rightMargin: 9
              anchors.verticalCenter: parent.verticalCenter
              width: 6
              height: 6
              radius: 3
              color: panel.checkColor(modelData.checksState)
            }

            MouseArea {
              id: prMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: panel.openUrl(modelData.url)
            }
          }
        }

        Item { width: parent.width; height: 2 }
      }
    }
  }
}
