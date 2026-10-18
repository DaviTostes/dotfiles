import QtQuick
import "../hyprconf"

// ChatGPT-style live voice conversation stage for OpenCode.
//
// Two layouts in one component:
//   - Full stage (!showChat): centered reactive multi-ring Voice Orb with
//     7-bar live waveform, orbital thinking satellites, live subtitles for
//     both user and assistant, language chips, and bottom control dock.
//   - Compact dock (showChat): sleek 52px bottom bar so the user can read
//     code/diffs/history in chatView while continuing to talk hands-free.
Item {
  id: root

  property bool active: false
  property bool showChat: false
  // "starting" | "listening" | "speech" | "transcribing" | "thinking" | "speaking" | "muted"
  property string state: "listening"
  property bool muted: false
  property bool busy: false
  property bool toolRunning: false
  property bool ttsPlaying: false
  property string lang: "pt"          // "pt" | "en" | "auto"
  property real level: 0              // 0..1 instantaneous audio envelope
  property real volume: 0.85          // assistant speech volume (0..1.5)
  property real savedVolume: 0.85     // last non-zero volume for speaker mute toggle
  // Voice Mode model picker: `models` is the panel's flat, provider-sorted
  // catalog; `modelKey` is "providerID/id" of the active Voice Mode model.
  property var models: []
  property string modelLabel: "session model"
  property string modelKey: ""
  // speech-to-text quality currently loaded ("fast" | "accurate") and while a
  // swap is in flight (the daemon restarts whisper-server with the other model)
  property string sttQuality: "accurate"
  property bool sttSwapping: false
  property string userText: ""
  property string assistantText: ""
  property int lastSttMs: 0

  signal toggleMute()
  signal primaryAction()              // orb tap / Space: interrupt or commit speech
  signal selectLang(string lang)
  signal setVolume(real volume)
  signal selectModel(string id, string providerID)
  signal selectStt(string quality)
  signal clearModel()
  signal toggleShowChat()
  signal closeVoice()

  // ---------- voice-model picker state ----------
  property bool modelOpen: false

  readonly property var modelHits: root.models || []

  // one row per model + the "session model" (no override) row on top
  readonly property int modelRowH: 38
  readonly property int modelListH:
      Math.min(240, (root.modelHits.length + 1) * root.modelRowH)

  function modelMeta(m) {
    const parts = [m.providerID];
    if (m.image) parts.push("img");
    if (m.tools) parts.push("tools");
    if (m.variants && m.variants.length) parts.push("reason");
    if (m.costIn > 0 || m.costOut > 0) parts.push("$" + m.costIn + "/" + m.costOut);
    return parts.join("  ·  ");
  }

  function modelRowKey(m) { return (m.providerID || "") + "/" + m.id; }

  function openModelMenu() { root.modelOpen = true; }
  function closeModelMenu() { root.modelOpen = false; }

  function pickModel(m) {
    root.modelOpen = false;
    root.selectModel(m.id, m.providerID);
  }

  function pickSessionModel() {
    root.modelOpen = false;
    root.clearModel();
  }

  // Smoothed audio level for 60fps orb & bar motion
  property real smoothLevel: active ? level : 0
  Behavior on smoothLevel {
    NumberAnimation { duration: 60; easing.type: Easing.OutQuad }
  }

  // Continuous phase for organic waveform bar ripple while active
  property real wavePhase: 0
  NumberAnimation on wavePhase {
    running: root.active && (root.state === "speech" || root.state === "speaking" || root.state === "listening")
    loops: Animation.Infinite
    from: 0
    to: 6.2831853
    duration: 900
  }

  // Idle breathing pulse when listening
  property real breathe: 0
  SequentialAnimation on breathe {
    running: root.active && !root.showChat && root.state === "listening" && !root.muted
    loops: Animation.Infinite
    NumberAnimation { to: 1; duration: 1600; easing.type: Easing.InOutSine }
    NumberAnimation { to: 0; duration: 1600; easing.type: Easing.InOutSine }
  }

  readonly property color stateColor: {
    if (root.muted || root.state === "muted") return Theme.err;
    if (root.state === "speech") return Theme.live;
    if (root.state === "speaking") return Theme.accent;
    if (root.state === "thinking" || root.state === "transcribing" || root.busy) return Theme.accent2;
    return Theme.accent;
  }

  readonly property bool speakingNow: state === "speaking" || ttsPlaying

  readonly property string stateTitle: {
    if (root.muted || root.state === "muted") return "microphone muted";
    if (root.sttSwapping) return "switching speech model…";
    if (root.state === "starting") return "warming up voice engine…";
    if (root.state === "speech") return "hearing you…";
    if (root.state === "transcribing") return "transcribing…";
    if (root.state === "speaking" || root.ttsPlaying) return "speaking…";
    if (root.toolRunning) return "running tool…";
    if (root.state === "thinking" || root.busy) return "thinking…";
    return "listening…";
  }

  readonly property string stateHint: {
    if (root.muted || root.state === "muted") return "press Space or M to unmute";
    if (root.sttSwapping) return "loading the " + root.sttQuality + " speech model…";
    if (root.state === "speech") return "pause to send  ·  tap orb or Space to send now";
    if (root.state === "speaking" || root.ttsPlaying) return "just start talking or tap orb to interrupt";
    if (root.state === "thinking" || root.busy) return "tap orb or Space to interrupt";
    return "speak naturally  ·  hands-free conversation";
  }

  function barHeight(idx, maxH, minH) {
    const centerDist = Math.abs(idx - 3) / 3.0;
    const profile = 1.0 - centerDist * 0.45;
    if (root.muted || root.state === "muted") return minH;
    if (root.state === "speech" || root.state === "speaking" || root.ttsPlaying) {
      const wobble = 0.72 + 0.28 * Math.sin(root.wavePhase + idx * 1.05);
      const amp = Math.max(0.14, root.smoothLevel) * profile * wobble;
      return Math.round(minH + (maxH - minH) * Math.min(1, amp * 1.25));
    }
    if (root.state === "listening") {
      const idleWave = 0.08 + 0.06 * Math.sin(root.wavePhase + idx * 0.9);
      const micBoost = root.smoothLevel * 0.55;
      return Math.round(minH + (maxH - minH) * Math.min(1, (idleWave + micBoost) * profile));
    }
    return minH;
  }

  // =========================================================================
  //  small reusable volume slider (track + draggable knob)
  // =========================================================================
  component VolumeSlider: Item {
    id: vsl
    property real value: 0.85
    property real maxValue: 1.5
    signal moved(real v)
    implicitWidth: 82
    implicitHeight: 20

    Rectangle {
      id: vslTrack
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      width: parent.width
      height: 4
      radius: 2
      color: Theme.bg
      border.color: Theme.border
      border.width: 1
      clip: true

      Rectangle {
        // the fill edge tracks the knob's CENTRE, so knob and bar never
        // disagree at either end of the travel
        width: Math.round(vslKnob.x + vslKnob.width / 2)
        height: parent.height
        radius: 2
        color: Theme.accent
        Behavior on width { NumberAnimation { duration: 70; easing.type: Easing.OutQuad } }
      }
    }

    Rectangle {
      id: vslKnob
      width: 11; height: 11; radius: 5.5
      anchors.verticalCenter: parent.verticalCenter
      x: Math.round(Math.max(0, Math.min(vsl.width - width,
             vsl.width * Math.min(1, vsl.value / vsl.maxValue) - width / 2)))
      color: vslHover.hovered || vslDrag.pressed ? Theme.text : Theme.accent
      border.color: Theme.deep
      border.width: 1
      Behavior on color { ColorAnimation { duration: 130 } }
      // while dragging the knob must track the pointer, not animate behind it
      Behavior on x { enabled: !vslDrag.pressed; NumberAnimation { duration: 70 } }
    }

    HoverHandler { id: vslHover }
    MouseArea {
      id: vslDrag
      // fills the track horizontally (so mouse.x maps 1:1 onto the value) and
      // is padded vertically only, keeping the grab area comfortable
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.topMargin: -5
      anchors.bottomMargin: -5
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      preventStealing: true
      function apply(mx) {
        const rel = Math.max(0, Math.min(1, mx / vsl.width));
        vsl.moved(rel * vsl.maxValue);
      }
      // press = jump to that spot; keep moving while held = drag. NB: it must
      // be `pressed`, not `dragging` — `dragging` only becomes true when a
      // `drag.target` is set, so the old check made this click-only.
      onPressed: mouse => apply(mouse.x)
      onPositionChanged: mouse => { if (pressed) apply(mouse.x); }
    }
  }

  // =========================================================================
  //  FULL IMMERSIVE STAGE (!showChat)
  // =========================================================================
  Rectangle {
    id: fullStage
    anchors.fill: parent
    visible: !root.showChat
    radius: 8
    color: Theme.bg
    border.color: Theme.border
    border.width: 1
    clip: true

    // ----- top bar: status badge (left) + controls (flush right) -----
    // Two groups, not one centered row: the status pill sits on the left, and
    // the control cluster sits flush against the right edge inside a
    // RightToLeft Flow so it wraps cleanly when the docked panel (~640px) is
    // narrower than the full window.
    Item {
      id: topBar
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: 12
      height: Math.max(statusPill.height, rightFlow.height)

      // live indicator pill
      Rectangle {
        id: statusPill
        anchors.left: parent.left
        anchors.top: parent.top
        height: 24
        width: statusRow.implicitWidth + 18
        radius: 6
        color: Theme.surface
        border.color: Theme.border
        border.width: 1

        Row {
          id: statusRow
          anchors.centerIn: parent
          spacing: 6

          Rectangle {
            width: 6; height: 6; radius: 3
            anchors.verticalCenter: parent.verticalCenter
            color: root.stateColor
            Behavior on color { ColorAnimation { duration: 180 } }
            SequentialAnimation on opacity {
              running: root.active && !root.muted
              loops: Animation.Infinite
              NumberAnimation { to: 0.35; duration: 520; easing.type: Easing.InOutSine }
              NumberAnimation { to: 1.0; duration: 520; easing.type: Easing.InOutSine }
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.state === "starting" ? "voice · warming" : "voice · live"
            font.family: Theme.font
            font.bold: true
            font.pixelSize: 10
            color: Theme.accent
          }

          Text {
            visible: root.lastSttMs > 0
            anchors.verticalCenter: parent.verticalCenter
            text: "· " + root.lastSttMs + "ms"
            font.family: Theme.font
            font.pixelSize: 9
            color: Theme.muted
          }
        }
      }

      // NOTE: a RightToLeft Flow puts its FIRST child at the RIGHT edge, so the
      // children below are declared right-to-left. Read left-to-right on screen
      // they are: model · volume · language · quality · chat.
      Flow {
        id: rightFlow
        anchors.right: parent.right
        anchors.top: parent.top
        width: Math.max(60, topBar.width - statusPill.width - 12)
        layoutDirection: Qt.RightToLeft
        spacing: 6

        // peek chat history while staying in voice mode
        Rectangle {
          id: peekBtn
          width: peekRow.implicitWidth + 16
          height: 24
          radius: 6
          color: peekMa.containsMouse ? Theme.hover : Theme.surface
          border.color: Theme.border
          border.width: 1
          Behavior on color { ColorAnimation { duration: 160 } }
          scale: peekMa.pressed ? 0.94 : (peekMa.containsMouse ? 1.04 : 1)
          Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

          Row {
            id: peekRow
            anchors.centerIn: parent
            spacing: 5

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "󰆍"
              font.family: Theme.font
              font.pixelSize: 11
              color: Theme.accent
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "chat"
              font.family: Theme.font
              font.pixelSize: 10
              color: Theme.text
            }
          }

          MouseArea {
            id: peekMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleShowChat()
          }
        }

        // speech-to-text quality segmented pill: accurate = whisper medium,
        // fast = whisper small.
        Rectangle {
          id: sttWrap
          width: sttRow.implicitWidth + 4
          height: 24
          radius: 6
          color: Theme.surface
          border.color: Theme.border
          border.width: 1

          Row {
            id: sttRow
            anchors.centerIn: parent
            spacing: 2

            Repeater {
              model: [
                { id: "accurate", label: fullStage.width >= 720 ? "ACCURATE" : "ACC" },
                { id: "fast", label: "FAST" }
              ]

              Rectangle {
                id: sttChip
                required property var modelData
                readonly property bool cur: root.sttQuality === modelData.id
                width: sttLabel.implicitWidth + 12
                height: 20
                radius: 4
                color: cur ? Theme.accent2 : (sttMa.containsMouse ? Theme.hover : "transparent")
                Behavior on color { ColorAnimation { duration: 160 } }

                Text {
                  id: sttLabel
                  anchors.centerIn: parent
                  text: sttChip.modelData.label
                  font.family: Theme.font
                  font.bold: sttChip.cur
                  font.pixelSize: 9
                  color: sttChip.cur ? Theme.deep : (sttMa.containsMouse ? Theme.text : Theme.muted)
                  Behavior on color { ColorAnimation { duration: 150 } }
                }

                MouseArea {
                  id: sttMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectStt(sttChip.modelData.id)
                }
              }
            }
          }
        }

        // language selector segmented pill (PT / EN / AUTO)
        Rectangle {
          id: langWrap
          width: langRow.implicitWidth + 4
          height: 24
          radius: 6
          color: Theme.surface
          border.color: Theme.border
          border.width: 1

          Row {
            id: langRow
            anchors.centerIn: parent
            spacing: 2

            Repeater {
              model: [
                { id: "pt", label: "PT" },
                { id: "en", label: "EN" },
                { id: "auto", label: "AUTO" }
              ]

              Rectangle {
                id: langChip
                required property var modelData
                readonly property bool cur: root.lang === modelData.id
                width: langLabel.implicitWidth + 12
                height: 20
                radius: 4
                color: cur ? Theme.accent : (langMa.containsMouse ? Theme.hover : "transparent")
                Behavior on color { ColorAnimation { duration: 160 } }

                Text {
                  id: langLabel
                  anchors.centerIn: parent
                  text: langChip.modelData.label
                  font.family: Theme.font
                  font.bold: langChip.cur
                  font.pixelSize: 9
                  color: langChip.cur ? Theme.deep : (langMa.containsMouse ? Theme.text : Theme.muted)
                  Behavior on color { ColorAnimation { duration: 150 } }
                }

                MouseArea {
                  id: langMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectLang(langChip.modelData.id)
                }
              }
            }
          }
        }

        // volume control pill for the assistant's spoken voice
        Rectangle {
          id: volPill
          width: volBox.implicitWidth + 16
          height: 24
          radius: 6
          color: Theme.surface
          border.color: Theme.border
          border.width: 1

          Row {
            id: volBox
            anchors.centerIn: parent
            spacing: 6

            Item {
              width: 14; height: 20
              anchors.verticalCenter: parent.verticalCenter

              Text {
                anchors.centerIn: parent
                readonly property bool on: root.speakingNow
                text: root.volume <= 0.01 ? "\uf026" : (root.volume < 0.45 ? "\uf027" : "\uf028")
                font.family: Theme.font
                font.pixelSize: 11
                color: root.volume <= 0.01 ? Theme.err
                     : (on ? root.stateColor : (spkMa.containsMouse ? Theme.text : Theme.muted))
                Behavior on color { ColorAnimation { duration: 150 } }
              }

              MouseArea {
                id: spkMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (root.volume > 0.01) {
                    root.savedVolume = root.volume;
                    root.setVolume(0);
                  } else {
                    root.setVolume(root.savedVolume > 0.05 ? root.savedVolume : 0.85);
                  }
                }
              }
            }

            VolumeSlider {
              anchors.verticalCenter: parent.verticalCenter
              implicitWidth: fullStage.width >= 720 ? 74 : 58
              value: root.volume
              onMoved: v => {
                const rounded = Math.round(Math.max(0, Math.min(1.5, v)) * 100) / 100;
                if (rounded > 0.05) root.savedVolume = rounded;
                root.setVolume(rounded);
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: 24
              text: Math.round(root.volume * 100) + "%"
              horizontalAlignment: Text.AlignRight
              font.family: Theme.font
              font.pixelSize: 9
              color: Theme.muted
            }
          }
        }

        // Voice Mode model — the model every voice turn uses. Click to change.
        // Sized from an un-anchored measure of the label so there is no
        // circular width dependency between the pill and the elided label.
        Rectangle {
          id: modelChip
          readonly property int maxLabelW: fullStage.width >= 720 ? 150 : 105
          readonly property int labelW: Math.min(maxLabelW, modelLabelMeasure.implicitWidth)
          width: labelW + 38
          height: 24
          radius: 6
          color: root.modelOpen || modelMa.containsMouse ? Theme.hover : Theme.surface
          border.width: 1
          border.color: root.modelOpen ? Theme.muted
                      : (root.modelKey === "" ? Theme.border : Theme.accent2)
          Behavior on color { ColorAnimation { duration: 160 } }
          Behavior on border.color { ColorAnimation { duration: 160 } }
          scale: modelMa.pressed ? 0.96 : (modelMa.containsMouse ? 1.04 : 1)
          Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

          Text {
            id: modelLabelMeasure
            visible: false
            text: root.modelLabel
            font.family: Theme.font
            font.pixelSize: 10
          }

          Text {
            id: modelChipIcon
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: "󰧑"
            font.family: Theme.font
            font.pixelSize: 11
            color: root.modelKey === "" ? Theme.muted : Theme.accent2
          }

          Text {
            anchors.left: modelChipIcon.right
            anchors.leftMargin: 5
            anchors.right: modelChipChev.left
            anchors.rightMargin: 5
            anchors.verticalCenter: parent.verticalCenter
            text: root.modelLabel
            font.family: Theme.font
            font.pixelSize: 10
            color: Theme.text
            elide: Text.ElideRight
          }

          Text {
            id: modelChipChev
            anchors.right: parent.right
            anchors.rightMargin: 7
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf0d7"
            font.family: Theme.font
            font.pixelSize: 9
            color: root.modelOpen ? Theme.accent : Theme.muted
            rotation: root.modelOpen ? 180 : 0
            Behavior on rotation { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
          }

          MouseArea {
            id: modelMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.modelOpen ? root.closeModelMenu() : root.openModelMenu()
          }
        }
      }
    }

    // ----- center stage: fluid multi-ring Voice Orb -----
    // Vertically centered in the stage region between topBar and bottomDock
    // (shifting up gently when live user/assistant subtitles are visible) so
    // the orb never floats stranded near the top of a tall fullscreen window.
    Item {
      id: orbContainer
      readonly property bool hasSubtitles: root.userText !== "" || root.assistantText !== ""
      readonly property real stageTop: topBar.y + topBar.height + 16
      readonly property real stageBot: bottomDockWrap.y - 16
      readonly property real availH: Math.max(height + 60, stageBot - stageTop)
      readonly property real unitH: height + 14 + captionCol.height
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(stageTop, Math.round(stageTop + (availH - unitH) * (hasSubtitles ? 0.42 : 0.48)))
      Behavior on y { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
      width: 240
      height: 240

      // outermost subtle ambient ring
      Rectangle {
        id: orbHalo3
        anchors.centerIn: parent
        width: 236
        height: 236
        radius: 118
        color: "transparent"
        border.width: 1
        border.color: root.stateColor
        opacity: root.muted ? 0.05
               : (root.state === "speech" || root.state === "speaking")
                 ? Math.min(0.32, 0.08 + root.smoothLevel * 0.35)
                 : (0.06 + root.breathe * 0.06)
        scale: root.muted ? 0.90
             : (root.state === "speech" || root.state === "speaking")
               ? (0.95 + root.smoothLevel * 0.28)
               : (0.94 + root.breathe * 0.06)
        Behavior on border.color { ColorAnimation { duration: 200 } }
        Behavior on opacity { NumberAnimation { duration: 120 } }
      }

      // outer atmospheric ripple ring
      Rectangle {
        id: orbHalo2
        anchors.centerIn: parent
        width: 196
        height: 196
        radius: 98
        color: "transparent"
        border.width: 1
        border.color: root.stateColor
        opacity: root.muted ? 0.12
               : (root.state === "speech" || root.state === "speaking")
                 ? Math.min(0.65, 0.22 + root.smoothLevel * 0.55)
                 : (0.16 + root.breathe * 0.12)
        scale: root.muted ? 0.88
             : (root.state === "speech" || root.state === "speaking")
               ? (0.94 + root.smoothLevel * 0.30)
               : (0.92 + root.breathe * 0.08)
        Behavior on border.color { ColorAnimation { duration: 200 } }
        Behavior on opacity { NumberAnimation { duration: 120 } }
      }

      // middle reactive ring + orbital satellites
      Rectangle {
        id: orbHalo1
        anchors.centerIn: parent
        width: 156
        height: 156
        radius: 78
        color: root.stateColor
        opacity: root.muted ? 0.05
               : (root.state === "speech" || root.state === "speaking")
                 ? Math.min(0.26, 0.08 + root.smoothLevel * 0.22)
                 : (0.07 + root.breathe * 0.05)
        scale: (root.state === "speech" || root.state === "speaking")
               ? (0.96 + root.smoothLevel * 0.22)
               : (0.95 + root.breathe * 0.05)
        Behavior on color { ColorAnimation { duration: 200 } }
      }

      // spinning orbital dots (fast when thinking/transcribing, slow drift otherwise)
      Item {
        id: orbitRing
        anchors.centerIn: parent
        width: 158
        height: 158
        visible: !root.muted
        NumberAnimation on rotation {
          running: root.active && !root.showChat && !root.muted
          loops: Animation.Infinite
          from: 0
          to: 360
          duration: (root.state === "thinking" || root.state === "transcribing" || root.busy)
                    ? 2200 : 9000
        }

        Repeater {
          model: 4
          Rectangle {
            required property int index
            readonly property real ang: index * Math.PI / 2
            width: (root.state === "thinking" || root.state === "transcribing" || root.busy) ? 6 : 4
            height: width
            radius: width / 2
            x: parent.width / 2 + Math.cos(ang) * 77 - width / 2
            y: parent.height / 2 + Math.sin(ang) * 77 - height / 2
            color: root.stateColor
            opacity: (root.state === "thinking" || root.state === "transcribing" || root.busy) ? 0.85 : 0.35
            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }
      }

      // core sphere
      Rectangle {
        id: orbCore
        anchors.centerIn: parent
        width: 116
        height: 116
        radius: 58
        readonly property bool filled: root.state === "speaking" || root.ttsPlaying
        color: filled ? Theme.accent
             : (orbMa.containsMouse ? Theme.hover : Theme.surface)
        border.width: filled ? 0 : 2
        border.color: root.stateColor
        Behavior on color { ColorAnimation { duration: 200 } }
        Behavior on border.color { ColorAnimation { duration: 200 } }
        scale: orbMa.pressed ? 0.92
             : (root.state === "speech" || root.state === "speaking" || root.ttsPlaying)
               ? (1.0 + root.smoothLevel * 0.16)
               : (orbMa.containsMouse ? 1.04 : (0.98 + root.breathe * 0.04))
        Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

        // 7-bar reactive voice waveform inside the orb (listening / speech / speaking)
        Row {
          anchors.centerIn: parent
          spacing: 5
          visible: !root.muted
                   && root.state !== "thinking"
                   && root.state !== "transcribing"
                   && (!root.busy || root.state === "speaking" || root.ttsPlaying)

          Repeater {
            model: 7
            Rectangle {
              required property int index
              width: 5
              height: root.barHeight(index, 48, 8)
              radius: 2.5
              anchors.verticalCenter: parent.verticalCenter
              color: orbCore.filled ? Theme.deep : root.stateColor
              Behavior on color { ColorAnimation { duration: 180 } }
              Behavior on height { NumberAnimation { duration: 55; easing.type: Easing.OutQuad } }
            }
          }
        }

        // thinking / transcribing icon inside the orb
        Row {
          anchors.centerIn: parent
          spacing: 4
          visible: !root.muted && !root.ttsPlaying && root.state !== "speaking"
                   && (root.state === "thinking" || root.state === "transcribing" || root.busy)

          Text {
            text: root.state === "transcribing" ? "◌" : "󰚩"
            font.family: Theme.font
            font.pixelSize: 26
            color: Theme.accent2
            property real bob: 0
            transform: Translate { y: parent.bob }
            SequentialAnimation on bob {
              running: visible
              loops: Animation.Infinite
              NumberAnimation { to: -4; duration: 320; easing.type: Easing.OutQuad }
              NumberAnimation { to: 0; duration: 320; easing.type: Easing.InQuad }
            }
          }

          Text {
            visible: root.toolRunning
            anchors.verticalCenter: parent.verticalCenter
            text: "󰖷"
            font.family: Theme.font
            font.pixelSize: 18
            color: Theme.accent
          }
        }

        // muted icon
        Text {
          anchors.centerIn: parent
          visible: root.muted
          text: "\uf131"
          font.family: Theme.font
          font.pixelSize: 28
          color: Theme.err
        }

        MouseArea {
          id: orbMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.primaryAction()
        }
      }
    }

    // ----- subtitles & state labels below the orb -----
    Column {
      id: captionCol
      anchors.top: orbContainer.bottom
      anchors.topMargin: 10
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(620, parent.width - 48)
      spacing: 6

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: root.stateTitle
        font.family: Theme.font
        font.bold: true
        font.pixelSize: 16
        color: root.stateColor
        Behavior on color { ColorAnimation { duration: 180 } }
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: root.stateHint
        font.family: Theme.font
        font.pixelSize: 11
        color: Theme.muted
        elide: Text.ElideRight
      }

      // User's last spoken phrase
      Text {
        width: parent.width
        visible: root.userText !== ""
        topPadding: 4
        horizontalAlignment: Text.AlignHCenter
        text: "“" + root.userText + "”"
        font.family: Theme.font
        font.pixelSize: 12
        color: Theme.text
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }

      // Assistant's live spoken sentence
      Rectangle {
        visible: root.assistantText !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width, Math.max(200, asstCapText.implicitWidth + 28))
        height: Math.min(92, asstCapText.implicitHeight + 16)
        radius: 8
        color: Theme.surface
        border.color: Theme.border
        border.width: 1

        Text {
          id: asstCapText
          anchors.fill: parent
          anchors.margins: 8
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: root.assistantText
          font.family: Theme.font
          font.pixelSize: 12
          color: Theme.accent
          wrapMode: Text.WordWrap
          maximumLineCount: 3
          elide: Text.ElideRight
        }
      }
    }

    // ----- bottom control dock (ChatGPT-style action buttons) -----
    Rectangle {
      id: bottomDockWrap
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 18
      anchors.horizontalCenter: parent.horizontalCenter
      width: bottomDock.implicitWidth + 16
      height: 52
      radius: 26
      color: Theme.sidebar
      border.color: Theme.border
      border.width: 1

      Row {
        id: bottomDock
        anchors.centerIn: parent
        spacing: 10

        // Mute / Unmute mic
        Rectangle {
          width: 40; height: 40; radius: 20
          color: root.muted ? Theme.err : (muteMa.containsMouse ? Theme.hover : Theme.surface)
          border.width: 1
          border.color: root.muted ? Theme.err : Theme.border
          Behavior on color { ColorAnimation { duration: 160 } }
          scale: muteMa.pressed ? 0.9 : (muteMa.containsMouse ? 1.07 : 1)
          Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

          Text {
            anchors.centerIn: parent
            text: root.muted ? "\uf131" : "\uf130"
            font.family: Theme.font
            font.pixelSize: 14
            color: root.muted ? Theme.deep : Theme.accent
          }

          MouseArea {
            id: muteMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleMute()
          }
        }

        // Center context action pill (Send now / Interrupt / Hands-free status)
        Rectangle {
          height: 40
          width: Math.max(142, centerActRow.implicitWidth + 30)
          radius: 20
          readonly property bool canInterrupt: root.state === "speaking" || root.ttsPlaying || root.busy
          readonly property bool canCommit: root.state === "speech"
          color: canInterrupt ? (centerActMa.containsMouse ? Theme.hover : Theme.surface)
               : canCommit ? Theme.live
               : (centerActMa.containsMouse ? Theme.hover : Theme.surface)
          border.width: 1
          border.color: canInterrupt ? Theme.err : (canCommit ? Theme.live : Theme.border)
          Behavior on color { ColorAnimation { duration: 160 } }
          Behavior on border.color { ColorAnimation { duration: 160 } }
          scale: centerActMa.pressed ? 0.94 : (centerActMa.containsMouse ? 1.04 : 1)
          Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

          Row {
            id: centerActRow
            anchors.centerIn: parent
            spacing: 8

            // 3-bar soundwave icon when idle, stop/check icon for interrupt/commit
            Item {
              width: 12; height: 12
              anchors.verticalCenter: parent.verticalCenter

              Text {
                visible: parent.parent.parent.canInterrupt || parent.parent.parent.canCommit
                anchors.centerIn: parent
                text: parent.parent.parent.canInterrupt ? "\uf04d" : "\uf00c"
                font.family: Theme.font
                font.pixelSize: 11
                color: parent.parent.parent.canInterrupt ? Theme.err : Theme.deep
              }

              Row {
                visible: !parent.parent.parent.canInterrupt && !parent.parent.parent.canCommit
                anchors.centerIn: parent
                spacing: 2
                Repeater {
                  model: [6, 11, 8]
                  Rectangle {
                    required property int modelData
                    width: 2; height: modelData; radius: 1
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.accent
                  }
                }
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: parent.parent.canInterrupt ? "interrupt  ·  Space"
                  : parent.parent.canCommit ? "send now  ·  Space"
                  : (root.muted ? "unmute  ·  Space" : "hands-free")
              font.family: Theme.font
              font.bold: parent.parent.canInterrupt || parent.parent.canCommit
              font.pixelSize: 11
              color: parent.parent.canInterrupt ? Theme.err
                   : parent.parent.canCommit ? Theme.deep : Theme.text
            }
          }

          MouseArea {
            id: centerActMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.primaryAction()
          }
        }

        // End Voice Mode (red ✕ circle)
        Rectangle {
          width: 40; height: 40; radius: 20
          color: endMa.containsMouse ? Theme.err : Theme.surface
          border.width: 1
          border.color: Theme.err
          Behavior on color { ColorAnimation { duration: 160 } }
          scale: endMa.pressed ? 0.9 : (endMa.containsMouse ? 1.07 : 1)
          Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

          Text {
            anchors.centerIn: parent
            text: "\uf00d"
            font.family: Theme.font
            font.pixelSize: 14
            color: endMa.containsMouse ? Theme.deep : Theme.err
            Behavior on color { ColorAnimation { duration: 150 } }
          }

          MouseArea {
            id: endMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.closeVoice()
          }
        }
      }
    }
  }

  // =========================================================================
  //  COMPACT VOICE BAR (showChat === true, docked at the bottom below chatView)
  // =========================================================================
  Rectangle {
    id: compactBar
    anchors.fill: parent
    visible: root.showChat
    radius: 8
    color: Theme.surface
    border.color: root.state === "speech" ? Theme.live
                : (root.state === "speaking" || root.ttsPlaying ? Theme.accent : Theme.border)
    border.width: 1
    Behavior on border.color { ColorAnimation { duration: 180 } }

    // mini reactive orb on the left (click to interrupt / commit)
    Rectangle {
      id: miniOrb
      anchors.left: parent.left
      anchors.leftMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      width: 30; height: 30; radius: 15
      color: (root.state === "speaking" || root.ttsPlaying) ? Theme.accent : Theme.bg
      border.width: 1
      border.color: root.stateColor
      scale: miniOrbMa.pressed ? 0.9
           : (1.0 + (root.state === "speech" || root.state === "speaking" ? root.smoothLevel * 0.14 : 0))
      Behavior on scale { NumberAnimation { duration: 90 } }

      Row {
        anchors.centerIn: parent
        spacing: 2
        Repeater {
          model: 5
          Rectangle {
            required property int index
            width: 2.5
            height: root.barHeight(index + 1, 16, 4)
            radius: 1.2
            anchors.verticalCenter: parent.verticalCenter
            color: (root.state === "speaking" || root.ttsPlaying) ? Theme.deep : root.stateColor
          }
        }
      }

      MouseArea {
        id: miniOrbMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.primaryAction()
      }
    }

    // live status + subtitle in the middle (click to return to full orb stage)
    Column {
      anchors.left: miniOrb.right
      anchors.leftMargin: 10
      anchors.right: compactBtns.left
      anchors.rightMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      spacing: 1

      Text {
        width: parent.width
        text: root.stateTitle
            + (root.userText !== "" && root.state === "thinking" ? "  ·  “" + root.userText + "”" : "")
        font.family: Theme.font
        font.bold: true
        font.pixelSize: 10
        color: root.stateColor
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: root.assistantText !== "" ? root.assistantText : root.stateHint
        font.family: Theme.font
        font.pixelSize: 9
        color: root.assistantText !== "" ? Theme.accent : Theme.muted
        elide: Text.ElideRight
      }
    }

    MouseArea {
      anchors.left: miniOrb.right
      anchors.right: compactBtns.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleShowChat()
    }

    // right controls: orb stage toggle, mute, end voice mode
    Row {
      id: compactBtns
      anchors.right: parent.right
      anchors.rightMargin: 6
      anchors.verticalCenter: parent.verticalCenter
      spacing: 4

      // Voice Mode model (same picker as the full stage)
      Rectangle {
        id: cModelChip
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(140, cModelRow.implicitWidth + 14)
        height: 26
        radius: 6
        color: root.modelOpen ? Theme.hover : (cModelMa.containsMouse ? Theme.hover : Theme.bg)
        Behavior on color { ColorAnimation { duration: 150 } }
        scale: cModelMa.pressed ? 0.94 : (cModelMa.containsMouse ? 1.04 : 1)
        Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

        Row {
          id: cModelRow
          anchors.centerIn: parent
          spacing: 5

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "󰧑"
            font.family: Theme.font
            font.pixelSize: 11
            color: root.modelKey === "" ? Theme.muted : Theme.accent2
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(104, implicitWidth)
            text: root.modelLabel
            font.family: Theme.font
            font.pixelSize: 10
            color: Theme.text
            elide: Text.ElideRight
          }
        }

        MouseArea {
          id: cModelMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.modelOpen ? root.closeModelMenu() : root.openModelMenu()
        }
      }

      // assistant voice volume (visible in the compact dock too)
      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.volume <= 0.01 ? "\uf026" : (root.volume < 0.45 ? "\uf027" : "\uf028")
          font.family: Theme.font
          font.pixelSize: 11
          color: root.speakingNow ? root.stateColor : Theme.muted
        }

        VolumeSlider {
          anchors.verticalCenter: parent.verticalCenter
          implicitWidth: 64
          value: root.volume
          onMoved: v =>
            root.setVolume(Math.round(Math.max(0, Math.min(1.5, v)) * 100) / 100)
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: 24
          text: Math.round(root.volume * 100) + "%"
          horizontalAlignment: Text.AlignRight
          font.family: Theme.font
          font.pixelSize: 9
          color: Theme.muted
        }
      }

      // expand back to full orb stage
      Rectangle {
        width: 28; height: 26; radius: 6
        color: orbViewMa.containsMouse ? Theme.hover : Theme.bg
        Behavior on color { ColorAnimation { duration: 150 } }
        Row {
          anchors.centerIn: parent
          spacing: 2
          Repeater {
            model: [6, 12, 8]
            Rectangle {
              required property int modelData
              width: 2; height: modelData; radius: 1
              anchors.verticalCenter: parent.verticalCenter
              color: Theme.accent
            }
          }
        }
        MouseArea {
          id: orbViewMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.toggleShowChat()
        }
      }

      // mute toggle
      Rectangle {
        width: 28; height: 26; radius: 6
        color: root.muted ? Theme.err : (cMuteMa.containsMouse ? Theme.hover : Theme.bg)
        Behavior on color { ColorAnimation { duration: 150 } }
        Text {
          anchors.centerIn: parent
          text: root.muted ? "\uf131" : "\uf130"
          font.family: Theme.font
          font.pixelSize: 11
          color: root.muted ? Theme.deep : Theme.text
        }
        MouseArea {
          id: cMuteMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.toggleMute()
        }
      }

      // stop voice mode
      Rectangle {
        width: 28; height: 26; radius: 6
        color: cEndMa.containsMouse ? Theme.err : Theme.bg
        border.width: 1
        border.color: Theme.err
        Behavior on color { ColorAnimation { duration: 150 } }
        Text {
          anchors.centerIn: parent
          text: "\uf00d"
          font.family: Theme.font
          font.pixelSize: 11
          color: cEndMa.containsMouse ? Theme.deep : Theme.err
        }
        MouseArea {
          id: cEndMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.closeVoice()
        }
      }
    }
  }

  // =========================================================================
  //  Voice Mode model picker — shared overlay for both layouts
  // =========================================================================
  Item {
    id: modelOverlay
    anchors.fill: parent
    z: 60
    visible: root.modelOpen || opacity > 0
    opacity: root.modelOpen ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

    // click anywhere outside the panel to dismiss
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: root.closeModelMenu()
    }

    Rectangle {
      id: modelPanel
      // Align with the right-hand controls (or center if narrow)
      anchors.right: parent.right
      anchors.rightMargin: 12
      // above the compact dock, just below the top bar on the orb stage
      y: root.showChat ? Math.max(6, parent.height - 46 - height - 10)
                       : topBar.y + topBar.height + 8
      width: Math.min(360, Math.max(240, parent.width - 24))
      height: 12 + root.modelListH
      radius: 6
      color: Theme.surface
      border.color: Theme.border
      border.width: 1
      clip: true

      // swallow clicks inside the panel so the catcher above does not fire
      MouseArea { anchors.fill: parent }

      Flickable {
        id: modelFlick
        anchors.fill: parent
        anchors.margins: 6
        contentWidth: width
        contentHeight: modelList.implicitHeight
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: modelList
          width: modelFlick.width
          spacing: 2

          // "no override" row — Voice Mode then follows whatever model the
          // chat itself is using
          Rectangle {
            id: modelRowAuto
            readonly property bool cur: root.modelKey === ""
            width: modelList.width
            height: root.modelRowH
            radius: 5
            color: (modelRowAuto.cur || modelRowAutoMa.containsMouse)
                   ? Theme.hover : "transparent"
            Behavior on color { ColorAnimation { duration: 140 } }

            Rectangle {
              visible: modelRowAuto.cur
              anchors.left: parent.left
              anchors.leftMargin: 2
              anchors.verticalCenter: parent.verticalCenter
              width: 3; height: 18; radius: 1.5
              color: Theme.accent
            }

            Column {
              anchors.left: parent.left
              anchors.leftMargin: 10
              anchors.right: modelRowAutoCheck.left
              anchors.rightMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              spacing: 1

              Text {
                width: parent.width
                text: "session model"
                font.family: Theme.font
                font.pixelSize: 10
                font.bold: modelRowAuto.cur
                color: modelRowAuto.cur ? Theme.accent : Theme.text
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                text: "follow whatever the chat is using"
                font.family: Theme.font
                font.pixelSize: 8
                color: Theme.muted
                elide: Text.ElideRight
              }
            }

            Text {
              id: modelRowAutoCheck
              anchors.right: parent.right
              anchors.rightMargin: 8
              anchors.verticalCenter: parent.verticalCenter
              width: 12
              horizontalAlignment: Text.AlignHCenter
              text: modelRowAuto.cur ? "✓" : ""
              font.family: Theme.font
              font.pixelSize: 11
              color: Theme.accent
            }

            MouseArea {
              id: modelRowAutoMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.pickSessionModel()
            }
          }

          Repeater {
            model: root.modelHits

            Rectangle {
              id: modelRow
              required property var modelData
              readonly property bool cur:
                  root.modelKey === root.modelRowKey(modelRow.modelData)
              width: modelList.width
              height: root.modelRowH
              radius: 5
              color: (modelRow.cur || modelRowMa.containsMouse)
                     ? Theme.hover : "transparent"
              Behavior on color { ColorAnimation { duration: 140 } }

              Rectangle {
                visible: modelRow.cur
                anchors.left: parent.left
                anchors.leftMargin: 2
                anchors.verticalCenter: parent.verticalCenter
                width: 3; height: 18; radius: 1.5
                color: Theme.accent2
              }

              Column {
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.right: modelRowCheck.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                  width: parent.width
                  text: modelRow.modelData.name
                  font.family: Theme.font
                  font.pixelSize: 10
                  font.bold: modelRow.cur
                  color: modelRow.cur ? Theme.accent2 : Theme.text
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: root.modelMeta(modelRow.modelData)
                  font.family: Theme.font
                  font.pixelSize: 8
                  color: Theme.muted
                  elide: Text.ElideRight
                }
              }

              Text {
                id: modelRowCheck
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 12
                horizontalAlignment: Text.AlignHCenter
                text: modelRow.cur ? "✓" : ""
                font.family: Theme.font
                font.pixelSize: 11
                color: Theme.accent2
              }

              MouseArea {
                id: modelRowMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.pickModel(modelRow.modelData)
              }
            }
          }
        }
      }
    }
  }
}
