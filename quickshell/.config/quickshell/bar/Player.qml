import Quickshell
import Quickshell.Services.Mpris
import QtQuick
import Qt5Compat.GraphicalEffects
import "../hyprconf"

Pill {
  id: root

  readonly property MprisPlayer player: {
    const players = Mpris.players.values;
    for (const p of players)
      if (p.identity.toLowerCase().includes("spotify")) return p;
    return players.length ? players[0] : null;
  }

  readonly property bool playing: player && player.playbackState === MprisPlaybackState.Playing
  readonly property bool hasArt: player && player.trackArtUrl !== ""

  // ---------- panel ----------
  // opens/closes ONLY on pill click — same pattern as the Pomodoro panel
  property bool panelOpen: false

  visible: player != null && player.playbackState !== MprisPlaybackState.Stopped
  implicitWidth: Math.min(label.implicitWidth, 220) + 16

  // ---------- pill ----------
  Text {
    id: label
    anchors.centerIn: parent
    font.family: Theme.font
    font.bold: true
    font.pixelSize: 12
    elide: Text.ElideRight
    width: Math.min(implicitWidth, 220)
    text: root.player
        ? (root.playing ? "󰏤" : "󰐊") + " " + root.player.trackTitle
        : ""
    color: root.panelOpen ? Theme.accent : Theme.text
    Behavior on color { ColorAnimation { duration: 200 } }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.panelOpen = !root.panelOpen
  }

  // click-outside close (same pattern as the Pomodoro panel)
  Catcher {
    id: catcher
    active: root.panelOpen
    onClicked: root.panelOpen = false
  }

  // drive the popup's close fade (see the dropdown panel below)
  onPanelOpenChanged: panelOpen ? hideAnim.stop() : hideAnim.restart()

  // ---------- dropdown panel ----------
  PopupWindow {
    // stays mapped briefly while closing so the fade can play
    visible: root.panelOpen || hideAnim.running
    color: "transparent"

    Timer { id: hideAnim; interval: 220 }

    implicitWidth: panelBody.implicitWidth + 24
    implicitHeight: panelBody.implicitHeight + 16
    onVisibleChanged: if (visible) anchor.updateAnchor()
    onImplicitWidthChanged: if (visible) anchor.updateAnchor()
    onImplicitHeightChanged: if (visible) anchor.updateAnchor()

    anchor {
      window: catcher
      edges: Edges.Top
      gravity: Edges.Bottom
    }

    anchor.onAnchoring: {
      const p = root.mapToItem(null, 0, 0);
      anchor.rect.x = p.x + 2;
      anchor.rect.y = p.y + 4 + root.height + 6;
      anchor.rect.width = root.width;
      anchor.rect.height = 1;
    }

    Rectangle {
      anchors.fill: parent
      color: Theme.bg
      radius: 6
      border.color: Theme.border
      border.width: 1
    }

    Item {
      id: panelBody
      anchors.centerIn: parent
      implicitWidth: 240
      implicitHeight: col.implicitHeight
      opacity: root.panelOpen ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

      transform: Translate {
        y: root.panelOpen ? 0 : -8
        Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      }

      Column {
        id: col
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 10

        // ----- art + track info -----
        Row {
          spacing: 10

          Rectangle {
            width: 56; height: 56; radius: 6
            color: Theme.surface

            Text {
              anchors.centerIn: parent
              visible: !root.hasArt
              text: "󰎈"
              font.family: Theme.font
              font.pixelSize: 22
              color: Theme.muted
            }

            Image {
              id: art
              anchors.fill: parent
              visible: root.hasArt
              asynchronous: true
              fillMode: Image.PreserveAspectCrop
              source: root.hasArt ? root.player.trackArtUrl : ""
              sourceSize.width: 112
              sourceSize.height: 112
              layer.enabled: root.hasArt
              layer.effect: OpacityMask {
                maskSource: Rectangle {
                  width: 56; height: 56; radius: 6
                }
              }
            }
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: 240 - 56 - 10
            spacing: 3

            Text {
              width: parent.width
              elide: Text.ElideRight
              text: root.player ? root.player.trackTitle : ""
              font.family: Theme.font
              font.bold: true
              font.pixelSize: 12
              color: Theme.accent
            }

            Text {
              width: parent.width
              elide: Text.ElideRight
              text: root.player && root.player.trackArtist ? root.player.trackArtist : ""
              visible: text !== ""
              font.family: Theme.font
              font.pixelSize: 10
              color: Theme.muted
            }
          }
        }

        // ----- controls -----
        component Ctrl: Item {
          id: ctrl

          property string glyph
          property bool dim: false
          signal activated

          implicitWidth: 34
          implicitHeight: 28

          Text {
            anchors.centerIn: parent
            text: ctrl.glyph
            font.family: Theme.font
            font.bold: true
            font.pixelSize: 13
            color: ctrl.dim ? Theme.muted : (ctrlMa.containsMouse ? Theme.accent : Theme.text)
            Behavior on color { ColorAnimation { duration: 200 } }
          }

          MouseArea {
            id: ctrlMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: ctrl.activated()
          }
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 6

          Ctrl {
            glyph: "󰒮"
            dim: !(root.player && root.player.canGoPrevious)
            onActivated: if (root.player && root.player.canGoPrevious) root.player.previous()
          }

          Rectangle {
            width: 42; height: 28; radius: 6
            color: playMa.containsMouse ? Theme.hover : Theme.surface
            Behavior on color { ColorAnimation { duration: 200 } }
            scale: playMa.containsMouse ? 1.06 : 1
            Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

            Text {
              anchors.centerIn: parent
              text: root.playing ? "󰏤" : "󰐊"
              font.family: Theme.font
              font.bold: true
              font.pixelSize: 15
              color: Theme.text
            }

            MouseArea {
              id: playMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.player) root.player.togglePlaying()
            }
          }

          Ctrl {
            glyph: "󰒭"
            dim: !(root.player && root.player.canGoNext)
            onActivated: if (root.player && root.player.canGoNext) root.player.next()
          }
        }
      }
    }
  }
}
