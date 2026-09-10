import Quickshell
import Quickshell.Services.Pipewire
import QtQuick
import "../hyprconf"

Pill {
  id: root

  // quickshell 0.3.1's tracker does not follow the nodes ObjectModel — it
  // only binds objects present in the list at assignment time (and the
  // initial sync adds nodes before QML exists), so the bound list is
  // rebuilt explicitly: once the service reports ready, and whenever the
  // node set changes (polling is the only option here — nodeAdded/
  // nodeRemoved are not exposed as QML signals in this version)
  PwObjectTracker {
    id: tracker
    objects: []
    Component.onCompleted: objects = Pipewire.nodes.values
  }

  Connections {
    target: Pipewire
    function onReadyChanged() { tracker.objects = Pipewire.nodes.values; }
    function onDefaultAudioSinkChanged() { tracker.objects = Pipewire.nodes.values; }
  }

  Timer {
    interval: 2000; running: true; repeat: true
    onTriggered: {
      const vals = Pipewire.nodes.values;
      const cur = tracker.objects;
      if (vals.length !== cur.length
          || vals.some((n, i) => n.id !== cur[i].id))
        tracker.objects = vals;
    }
  }

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var audio: sink && sink.ready ? sink.audio : null
  readonly property bool muted: audio ? audio.muted : false
  readonly property real volume: audio ? Math.round(audio.volume * 100) : 0

  // pavucontrol-style listings, keyed off media.class — quickshell's
  // isSink/isStream flags are noisy (every Stream/Output node is flagged
  // as a sink too), while media.class is authoritative:
  //   Audio/Sink            → output device
  //   Stream/Output/Audio   → per-app playback stream
  //   Stream/Input/Audio    → mic capture (excluded from this panel)
  readonly property var sinks: Pipewire.nodes.values
      .filter(n => n.ready && n.audio
          && (n.properties["media.class"] === "Audio/Sink"
              || (n.properties["media.class"] === undefined
                  && n.isSink && !n.isStream)))
  readonly property var streams: Pipewire.nodes.values
      .filter(n => n.ready && n.audio
          && n.properties["media.class"] === "Stream/Output/Audio")

  function streamName(n) {
    const app = n.properties["application.name"];
    const media = n.properties["media.name"];
    const p = app || n.nickname || n.name;
    // "vesktop — Playback" style label; skip redundant/synthetic media names
    if (media && media !== p && media.toLowerCase() !== "playback")
      return p + " — " + media;
    return p;
  }

  // merge per-app streams into one row per application (Discord-like apps
  // open several streams — voice, screenshare, sounds — that are almost
  // always controlled together); order of first appearance is kept
  readonly property var appGroups: {
    const groups = {};
    const order = [];
    for (const s of root.streams) {
      const name = root.streamName(s);
      if (!(name in groups)) { groups[name] = []; order.push(name); }
      groups[name].push(s.audio);
    }
    return order.map(name => ({ name: name, audios: groups[name] }));
  }

  // ---------- panel ----------
  // opens/closes ONLY on pill click — same pattern as the Pomodoro panel
  property bool panelOpen: false

  implicitWidth: label.implicitWidth + 16

  // ---------- pill ----------
  Text {
    id: label
    anchors.centerIn: parent
    font.family: Theme.font
    font.pixelSize: 14
    color: root.muted ? Theme.err : (root.panelOpen ? Theme.accent : Theme.text)
    Behavior on color { ColorAnimation { duration: 200 } }

    text: root.muted ? "󰝟"
        : root.volume === 0 ? "󰕿"
        : root.volume < 50 ? "󰖀"
        : "󰕾"
  }

  MouseArea {
    id: ma
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onClicked: mouse => {
      if (mouse.button === Qt.RightButton && root.audio)
        root.audio.muted = !root.audio.muted;
      else if (mouse.button === Qt.LeftButton)
        root.panelOpen = !root.panelOpen;
    }
    // scroll to step the volume
    onWheel: wheel => {
      if (!root.audio) return;
      const step = wheel.angleDelta.y > 0 ? 0.05 : -0.05;
      root.audio.volume = Math.max(0, Math.min(1.5, root.audio.volume + step));
    }
  }

  Tip {
    target: root
    shown: ma.containsMouse && !root.panelOpen
    text: root.muted ? "muted" : root.volume + "%"
  }

  // click-outside close (same pattern as the Pomodoro panel)
  Catcher {
    id: catcher
    active: root.panelOpen
    onClicked: root.panelOpen = false
  }

  // drive the popup's close fade (see the dropdown panel below)
  onPanelOpenChanged: panelOpen ? hideAnim.stop() : hideAnim.restart()

  // reusable pavu-style row: [mute] ====slider==== 42%
  // `audios` is a list — when a group (merged app) is passed, the slider
  // drives every stream in it at once
  component VolSlider: Item {
    id: vs

    property var audios: []

    readonly property bool muted: audios.length > 0
        && audios.every(a => a.muted)
    // display the loudest stream so a silent one doesn't halve the readout
    readonly property real frac: audios.length
        ? Math.max(0, Math.min(1.5, Math.max(...audios.map(a => a.volume))) / 1.5)
        : 0
    readonly property int pct: audios.length
        ? Math.round(Math.max(...audios.map(a => a.volume)) * 100) : 0

    implicitWidth: 34 + 10 + 150 + 10 + 34
    implicitHeight: 28

    Rectangle {
      width: 34; height: 28; radius: 6
      color: muteMa.containsMouse ? Theme.hover : Theme.surface
      Behavior on color { ColorAnimation { duration: 200 } }
      scale: muteMa.containsMouse ? 1.06 : 1
      Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

      Text {
        anchors.centerIn: parent
        text: vs.muted ? "󰝟" : "󰕾"
        font.family: Theme.font
        font.pixelSize: 14
        color: vs.muted ? Theme.err : Theme.text
        Behavior on color { ColorAnimation { duration: 200 } }
      }

      MouseArea {
        id: muteMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: vs.audios.length > 0
        // any stream audible → mute the whole group, else unmute all
        onClicked: {
          const target = !vs.muted;
          for (const a of vs.audios) a.muted = target;
        }
      }
    }

    Item {
      id: track
      x: 44
      width: 150; height: parent.height

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width; height: 6; radius: 3
        color: Theme.hover

        Rectangle {
          width: parent.width * vs.frac
          height: parent.height
          radius: 3
          color: vs.muted ? Theme.muted : Theme.accent
          Behavior on color { ColorAnimation { duration: 200 } }
        }

        Rectangle {
          x: Math.max(0, Math.min(parent.width, parent.width * vs.frac)) - width / 2
          anchors.verticalCenter: parent.verticalCenter
          width: 12; height: 12; radius: 6
          color: Theme.text
          scale: dragArea.containsMouse || dragArea.pressed ? 1.2 : 1
          Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        }
      }

      MouseArea {
        id: dragArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPressed: mouse => apply(mouse.x)
        onPositionChanged: mouse => { if (pressed) apply(mouse.x) }

        function apply(x) {
          // slider spans 0–150% like pavucontrol's range
          const v = Math.max(0, Math.min(1.5, x / dragArea.width * 1.5));
          for (const a of vs.audios) a.volume = v;
        }
      }
    }

    Text {
      x: 44 + 150 + 10
      width: 34
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      text: vs.muted ? "—" : vs.pct + "%"
      font.family: Theme.font
      font.pixelSize: 12
      color: vs.muted ? Theme.muted : Theme.accent
    }
  }

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
      implicitWidth: 260
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
        spacing: 8

        // ----- output devices -----
        Text {
          text: "output"
          font.family: Theme.font
          font.pixelSize: 10
          color: Theme.muted
        }

        Repeater {
          model: root.sinks

          Rectangle {
            required property var modelData
            readonly property bool sel: modelData === Pipewire.defaultAudioSink

            width: 260; height: 22; radius: 5
            color: sinkMa.containsMouse && !sel ? Theme.hover : "transparent"
            Behavior on color { ColorAnimation { duration: 200 } }

            Rectangle {
              id: dot
              x: 4; anchors.verticalCenter: parent.verticalCenter
              width: 6; height: 6; radius: 3
              color: parent.sel ? Theme.accent : Theme.muted
              Behavior on color { ColorAnimation { duration: 200 } }
            }

            Text {
              anchors.left: dot.right
              anchors.leftMargin: 6
              anchors.right: parent.right
              anchors.rightMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              text: parent.modelData.description
                  || parent.modelData.nickname || parent.modelData.name
              font.family: Theme.font
              font.pixelSize: 11
              color: parent.sel ? Theme.accent : Theme.text
            }

            MouseArea {
              id: sinkMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: Pipewire.preferredDefaultAudioSink = parent.modelData
            }
          }
        }

        // ----- master volume -----
        VolSlider { audios: root.audio ? [root.audio] : [] }

        // ----- per-app streams -----
        Text {
          text: "applications"
          font.family: Theme.font
          font.pixelSize: 10
          color: Theme.muted
        }

        Text {
          visible: root.appGroups.length === 0
          text: "no apps playing"
          font.family: Theme.font
          font.pixelSize: 10
          color: Theme.muted
        }

        Repeater {
          model: root.appGroups

          Column {
            required property var modelData

            width: 260
            spacing: 2

            Text {
              anchors.left: parent.left
              width: parent.width
              elide: Text.ElideRight
              text: parent.modelData.name
              font.family: Theme.font
              font.pixelSize: 11
              color: Theme.text
            }

            VolSlider { audios: parent.modelData.audios }
          }
        }
      }
    }
  }
}
