import Quickshell
import Quickshell.Services.Mpris
import QtQuick
import Qt5Compat.GraphicalEffects
import "../hyprconf"

// Now-playing pill rendered as a vertical soundwave (equalizer) instead of the
// track title. The bars animate while any media plays and sit still otherwise
// (the wave is always visible). Hovering the pill opens the media panel to the
// left; scrolling the pill cycles through every MPRIS player (Spotify, browser
// media, …) and the panel shows one dot per source to pick/see them. The panel
// stays open while either the pill or the panel is hovered.
Pill {
  id: root

  // all MPRIS players; scroll on the pill cycles which one is shown (a little
  // "slider" so Spotify + browser media etc. can all be reached)
  readonly property var players: Mpris.players.values
  property int playerIndex: 0
  // once the user scrolls, stop auto-following the preferred player
  property bool manual: false

  readonly property MprisPlayer player: players.length
      ? players[Math.max(0, Math.min(playerIndex, players.length - 1))] : null

  function preferredIndex() {
    const ps = players;
    for (let i = 0; i < ps.length; i++) {
      const p = ps[i];
      if ((p.identity + " " + (p.desktopEntry || "")).toLowerCase().includes("spotif")) return i;
    }
    for (let i = 0; i < ps.length; i++)
      if (ps[i].playbackState === MprisPlaybackState.Playing) return i;
    return 0;
  }

  onPlayersChanged: {
    if (players.length === 0) { playerIndex = 0; manual = false; return; }
    if (!manual) playerIndex = Math.min(preferredIndex(), players.length - 1);
    else if (playerIndex >= players.length) playerIndex = players.length - 1;
  }

  // scroll-to-switch: slides the content in from the scroll direction and has
  // a cooldown so it can't be spammed (one switch per animation)
  property real slideOfs: 0
  property bool slideAnimate: true
  Behavior on slideOfs {
    enabled: root.slideAnimate
    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
  }

  Timer { id: switchCooldown; interval: 200 }

  function requestSwitch(delta) {
    const n = players.length;
    if (n < 2 || switchCooldown.running) return;
    switchCooldown.restart();
    manual = true;
    playerIndex = ((playerIndex + delta) % n + n) % n;
    // snap to an offset, then animate back to 0 (the new content slides in)
    slideAnimate = false;
    slideOfs = -delta * 36;
    Qt.callLater(function() { root.slideAnimate = true; root.slideOfs = 0; });
  }

  readonly property bool playing: player && player.playbackState === MprisPlaybackState.Playing
  readonly property bool hasArt: player && player.trackArtUrl !== ""
  // true if ANY source is playing (the wave moves whenever something plays)
  readonly property bool anyPlaying: {
    const ps = players;
    for (let i = 0; i < ps.length; i++)
      if (ps[i].playbackState === MprisPlaybackState.Playing) return true;
    return false;
  }

  // ---------- panel ----------
  property bool panelOpen: false
  // hovered state of the popup itself (tracked so moving onto the panel keeps
  // it open instead of falling through to the close timer)
  property bool panelHover: false

  visible: true

  // ---------- pill: vertical soundwave ----------
  implicitWidth: 24
  implicitHeight: wave.implicitHeight + 12
  height: wave.implicitHeight + 12

  Column {
    id: wave
    anchors.centerIn: parent
    spacing: 2

    Repeater {
      id: rep
      model: 11

      Item {
        width: root.width
        height: 2
        // 0..1 per-bar level; set by waveTimer while playing
        property real level: 0

        Rectangle {
          anchors.centerIn: parent
          height: 2
          radius: 1
          color: root.anyPlaying ? Theme.accent : Theme.muted
          Behavior on color { ColorAnimation { duration: 200 } }
          // still stub when nothing is playing; grows toward full width while playing
          width: root.anyPlaying ? 6 + parent.level * Math.max(0, root.width - 12) : 6
          Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        }
      }
    }
  }

  // animate the bars only while media plays; otherwise the wave sits still
  // (it stays visible the whole time)
  Timer {
    id: waveTimer
    running: root.visible && root.anyPlaying
    interval: 120
    repeat: true
    onTriggered: {
      for (let i = 0; i < rep.count; i++) {
        const it = rep.itemAt(i);
        if (it) it.level = 0.15 + Math.random() * 0.85;
      }
    }
  }

  MouseArea {
    id: ma
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: { closeTimer.stop(); root.panelOpen = true; }
    onExited: closeTimer.restart();
    onClicked: root.panelOpen = !root.panelOpen
    // scroll cycles through all the media players
    onWheel: wheel => root.requestSwitch(wheel.angleDelta.y > 0 ? 1 : -1)
  }

  // close right after the pointer leaves both the pill and the panel
  Timer {
    id: closeTimer
    interval: 100
    onTriggered: if (!ma.containsMouse && !root.panelHover) root.panelOpen = false
  }

  // drive the popup's close fade (see the dropdown panel below)
  onPanelOpenChanged: {
    if (panelOpen) { closeTimer.stop(); hideAnim.stop(); }
    else hideAnim.restart();
  }

  // ---------- dropdown panel ----------
  PopupWindow {
    id: panel

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
      window: root.QsWindow.window
      edges: Edges.Right
      gravity: Edges.Left
    }

    anchor.onAnchoring: {
      // the side bar is on the right: open to the LEFT of the pill, clamped
      const p = root.mapToItem(null, 0, 0);
      const win = root.QsWindow.window;
      const sh = win && win.screen ? win.screen.height : 1080;
      const h = panel.implicitHeight;
      anchor.rect.x = p.x - 7;
      anchor.rect.y = Math.max(0, Math.min(p.y, sh - h));
      anchor.rect.width = 1;
      anchor.rect.height = h;
    }

    // the background also clips the content so the switch slide stays inside
    Rectangle {
      anchors.fill: parent
      color: Theme.bg
      radius: 6
      border.color: Theme.border
      border.width: 1
      clip: true

      // panel hover tracking: a HoverHandler (not a MouseArea) so hovering the
      // control buttons doesn't clear the hovered state and close the panel
      HoverHandler {
        id: panelHoverHandler
        onHoveredChanged: {
          root.panelHover = hovered;
          if (hovered) closeTimer.stop();
          else closeTimer.restart();
        }
      }

      Item {
        id: panelBody
        anchors.centerIn: parent
      implicitWidth: 240
      implicitHeight: col.implicitHeight
      opacity: root.panelOpen ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

      transform: [
        // horizontal slide when switching media (scroll)
        Translate { x: root.slideOfs },
        // vertical slide on open/close
        Translate {
          y: root.panelOpen ? 0 : -8
          Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        }
      ]

      Column {
        id: col
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 10

        // ----- player selector: one dot per media source (scroll on the pill
        // or click a dot to switch) -----
        Item {
          width: 240
          height: 8
          visible: root.players.length > 1

          Row {
            anchors.centerIn: parent
            spacing: 7

            Repeater {
              model: root.players.length

              Rectangle {
                required property int index
                width: 6; height: 6; radius: 3
                color: index === root.playerIndex
                    ? Theme.accent
                    : (dotMa.containsMouse ? Theme.text : Theme.muted)
                Behavior on color { ColorAnimation { duration: 200 } }

                MouseArea {
                  id: dotMa
                  anchors.fill: parent
                  anchors.margins: -4
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { root.manual = true; root.playerIndex = index; }
                }
              }
            }
          }
        }

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
              text: root.player && root.player.trackTitle ? root.player.trackTitle : "Nothing playing"
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

            // which source this is (shown only when more than one exists)
            Text {
              width: parent.width
              elide: Text.ElideRight
              visible: root.players.length > 1
              text: root.player ? root.player.identity : ""
              font.family: Theme.font
              font.pixelSize: 9
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

    // full-panel wheel catcher (no buttons, so clicks still reach the controls;
    // no hover, so it doesn't steal the hover above): scrolling anywhere over
    // the panel switches media
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.NoButton
      onWheel: wheel => {
        wheel.accepted = true;
        root.requestSwitch(wheel.angleDelta.y > 0 ? 1 : -1);
      }
    }
  }
}
