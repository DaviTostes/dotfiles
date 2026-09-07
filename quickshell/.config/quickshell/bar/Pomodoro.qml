import Quickshell
import QtQuick

Pill {
  id: root

  // ---------- settings (panel-adjustable) ----------
  property int workDuration: 25 * 60
  property int shortBreak: 5 * 60
  property int longBreak: 15 * 60
  property int longEvery: 4
  property bool autoBreak: true
  property bool autoFocus: true

  // ---------- state ----------
  property string phase: "work"     // work | short | long
  property string runState: "idle"  // idle | run | pause
  property int remaining: workDuration
  property int cycle: 0             // work sessions done since the last long break
  property int sessions: 0
  property int focusMinutes: 0

  // ---------- panel ----------
  // opens/closes ONLY on pill click — hover had unpredictable behavior
  property bool panelOpen: false

  readonly property bool running: runState === "run"
  readonly property color cWork: "#d3d9e0"      // work accent — light gray
  readonly property color cBreak: "#8b95a3"     // break accent — mid gray
  readonly property color cPaused: "#4a505a"    // dim gray when paused
  readonly property color cIdleText: "#585f68"  // idle pill text
  readonly property color cMuted: "#5c6470"     // secondary text
  readonly property color cText: "#a9afb8"      // primary text
  readonly property color cSurface: "#1e2126"   // buttons / chips
  readonly property color cHover: "#282c33"     // hover surface
  readonly property color cDark: "#101216"      // text on accent fills

  readonly property color phaseColor:
      runState === "pause" ? cPaused : (phase === "work" ? cWork : cBreak)
  // not readonly: the Behavior needs to write the animated value
  property real progress: phase === "work"
      ? 1 - remaining / workDuration
      : 1 - remaining / (phase === "long" ? longBreak : shortBreak)
  Behavior on progress {
    NumberAnimation { duration: 1000; easing.type: Easing.Linear }
  }
  onProgressChanged: ring.requestPaint()

  function durationOf(p) {
    return p === "work" ? workDuration : (p === "long" ? longBreak : shortBreak);
  }

  function phaseName(p) {
    return p === "work" ? "work" : (p === "long" ? "long break" : "break");
  }

  // count=false: skip without recording stats
  function advance(count) {
    if (phase === "work") {
      if (count) {
        sessions += 1;
        cycle += 1;
        focusMinutes += Math.round(workDuration / 60);
      }
      const isLong = count && cycle % longEvery === 0 && cycle > 0;
      phase = isLong ? "long" : "short";
      remaining = durationOf(phase);
      runState = autoBreak ? "run" : "idle";
      Quickshell.execDetached(["notify-send", "Pomodoro",
        isLong ? "Long break — you earned it" : "Work session done — take a break"]);
    } else {
      if (phase === "long") cycle = 0;
      phase = "work";
      remaining = workDuration;
      runState = autoFocus ? "run" : "idle";
      Quickshell.execDetached(["notify-send", "Pomodoro", "Break over — back to work"]);
    }
  }

  function reset() {
    runState = "idle";
    phase = "work";
    cycle = 0;
    remaining = workDuration;
  }

  implicitWidth: label.implicitWidth + 16

  Timer {
    interval: 1000
    repeat: true
    running: root.running
    onTriggered: root.remaining -= 1
  }

  onRemainingChanged: if (remaining <= 0 && running) advance(true)

  // ---------- pill ----------
  Text {
    id: label
    anchors.centerIn: parent
    font.family: "Agave Nerd Font"
    font.bold: true
    font.pixelSize: 12
    text: {
      const m = Math.floor(root.remaining / 60);
      const s = root.remaining % 60;
      return "󰄉 " + m + ":" + ("0" + s).slice(-2);
    }
    color: root.runState !== "run" && root.runState !== "pause" ? root.cIdleText : root.phaseColor
    Behavior on color { ColorAnimation { duration: 300 } }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor
    onClicked: me => {
      if (me.button === Qt.RightButton) { root.reset(); return; }
      if (me.button === Qt.MiddleButton) { root.advance(false); return; }
      root.panelOpen = !root.panelOpen;
    }
  }

  // invisible full-screen catcher: while the panel is open, any click outside
  // it lands here and closes the panel (the panel anchors to the catcher so
  // it stays above it and remains clickable)
  Catcher {
    id: catcher
    active: root.panelOpen
    onClicked: root.panelOpen = false
  }

  // ---------- dropdown panel ----------
  PopupWindow {

    visible: root.panelOpen
    color: "transparent"

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
      // pill coords (relative to the bar window) + the bar's own offset on
      // the monitor (Bar.qml margins: top 4, left 2); the catcher is
      // full-screen so monitor coords == its window coords
      const p = root.mapToItem(null, 0, 0);
      anchor.rect.x = p.x + 2;
      anchor.rect.y = p.y + 4 + root.height + 6;
      anchor.rect.width = root.width;
      anchor.rect.height = 1;
    }

    Rectangle {
      anchors.fill: parent
      color: "#161719"
      radius: 6
      border.color: "#282a2e"
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

        // ----- header: ring + time -----
        Item {
          width: 240
          height: 48

          Canvas {
            id: ring
            x: 4; y: 2
            width: 44; height: 44
            onPaint: {
              const ctx = getContext("2d");
              ctx.reset();
              ctx.lineWidth = 3;
              ctx.lineCap = "round";
              ctx.strokeStyle = "#282a2e";
              ctx.beginPath();
              ctx.arc(22, 22, 18, 0, Math.PI * 2);
              ctx.stroke();
              if (root.progress > 0.003) {
                ctx.strokeStyle = root.phaseColor;
                ctx.beginPath();
                ctx.arc(22, 22, 18, -Math.PI / 2, -Math.PI / 2 + root.progress * Math.PI * 2);
                ctx.stroke();
              }
            }
          }

          Text {
            x: 4; y: 2
            width: 44; height: 44
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: root.phase === "work" ? "\uf017" : (root.phase === "long" ? "\uf186" : "\uf0f4")
            font.family: "Agave Nerd Font"
            font.pixelSize: 13
            color: root.phaseColor
            Behavior on color { ColorAnimation { duration: 300 } }
          }

          Text {
            x: 58
            y: 6
            font.family: "Agave Nerd Font"
            font.bold: true
            font.pixelSize: 21
            color: root.phaseColor
            text: {
              const m = Math.floor(root.remaining / 60);
              const s = root.remaining % 60;
              return m + ":" + ("0" + s).slice(-2);
            }
            Behavior on color { ColorAnimation { duration: 300 } }
          }

          Text {
            x: 58
            y: 31
            font.family: "Agave Nerd Font"
            font.pixelSize: 10
            color: root.cMuted
            text: root.phaseName(root.phase) + " · session " + (root.phase === "work" ? root.cycle + 1 : root.cycle) + " of " + root.longEvery
          }
        }

        // ----- controls -----
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 6

          Rectangle {
            width: 96; height: 28; radius: 6
            color: root.running ? root.cSurface : root.cWork
            Behavior on color { ColorAnimation { duration: 200 } }
            scale: playMa.containsMouse ? 1.04 : 1
            Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

            Text {
              anchors.centerIn: parent
              font.family: "Agave Nerd Font"
              font.bold: true
              font.pixelSize: 13
              color: root.running ? root.cText : root.cDark
              Behavior on color { ColorAnimation { duration: 200 } }
              text: root.running ? "\uf04c  pause" : (root.runState === "pause" ? "\uf04b  resume" : "\uf04b  start")
            }

            MouseArea {
              id: playMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.runState = root.running ? "pause" : "run"
            }
          }

          Rectangle {
            width: 34; height: 28; radius: 6
            color: rb.containsMouse ? root.cHover : root.cSurface
            Behavior on color { ColorAnimation { duration: 150 } }
            Text {
              anchors.centerIn: parent
              font.family: "Agave Nerd Font"
              font.pixelSize: 13
              color: root.cText
              text: "\uf0e2"
            }
            MouseArea {
              id: rb
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.reset()
            }
          }

          Rectangle {
            width: 34; height: 28; radius: 6
            color: sb.containsMouse ? root.cHover : root.cSurface
            Behavior on color { ColorAnimation { duration: 150 } }
            Text {
              anchors.centerIn: parent
              font.family: "Agave Nerd Font"
              font.pixelSize: 13
              color: root.cText
              text: "\uf04e"
            }
            MouseArea {
              id: sb
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.advance(false)
            }
          }
        }

        // ----- presets -----
        component ChipRow: Row {
          id: chipRow

          property string title
          property color accent: root.cWork
          property string current
          property var values: []
          property var pick: null

          spacing: 4

          Text {
            width: 40
            text: chipRow.title
            font.family: "Agave Nerd Font"
            font.pixelSize: 10
            color: root.cMuted
            anchors.verticalCenter: parent.verticalCenter
          }

          Repeater {
            model: chipRow.values

            Rectangle {
              id: chip

              required property var modelData
              readonly property bool sel: chipRow.current === String(modelData)

              width: chipText.implicitWidth + 12
              height: 20
              radius: 5
              color: sel ? chipRow.accent : (chipMa.containsMouse ? root.cHover : root.cSurface)
              Behavior on color { ColorAnimation { duration: 150 } }
              scale: chipMa.containsMouse ? 1.07 : 1
              Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

              Text {
                id: chipText
                anchors.centerIn: parent
                font.family: "Agave Nerd Font"
                font.pixelSize: 10
                font.bold: chip.sel
                color: chip.sel ? root.cDark : root.cText
                Behavior on color { ColorAnimation { duration: 150 } }
                text: chip.modelData
              }

              MouseArea {
                id: chipMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: if (chipRow.pick) chipRow.pick(chip.modelData)
              }
            }
          }
        }

        ChipRow {
          title: "focus"
          accent: root.cWork
          values: ["5m", "15m", "25m", "45m", "60m"]
          current: Math.round(root.workDuration / 60) + "m"
          pick: v => {
            root.workDuration = parseInt(v) * 60;
            if (root.phase === "work" && !root.running) root.remaining = root.workDuration;
          }
        }

        ChipRow {
          title: "break"
          accent: root.cBreak
          values: ["5m", "10m", "15m", "30m"]
          current: Math.round(root.shortBreak / 60) + "m"
          pick: v => {
            root.shortBreak = parseInt(v) * 60;
            if (root.phase === "short" && !root.running) root.remaining = root.shortBreak;
          }
        }

        ChipRow {
          title: "long"
          accent: root.cWork
          values: ["3", "4", "6"]
          current: String(root.longEvery)
          pick: v => { root.longEvery = parseInt(v); }
        }

        ChipRow {
          title: "long"
          accent: root.cBreak
          values: ["15m", "20m", "30m"]
          current: Math.round(root.longBreak / 60) + "m"
          pick: v => {
            root.longBreak = parseInt(v) * 60;
            if (root.phase === "long" && !root.running) root.remaining = root.longBreak;
          }
        }

        // ----- toggles -----
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 14

          Repeater {
            model: [
              { label: "auto-break", get: () => root.autoBreak, set: v => root.autoBreak = v },
              { label: "auto-work", get: () => root.autoFocus, set: v => root.autoFocus = v }
            ]

            Row {
              required property var modelData
              spacing: 5

              Text {
                text: modelData.label
                font.family: "Agave Nerd Font"
                font.pixelSize: 10
                color: root.cMuted
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 26; height: 14; radius: 7
                color: modelData.get() ? root.cWork : root.cSurface
                Behavior on color { ColorAnimation { duration: 180 } }

                Rectangle {
                  x: modelData.get() ? parent.width - width - 2 : 2
                  anchors.verticalCenter: parent.verticalCenter
                  width: 10; height: 10; radius: 5
                  color: modelData.get() ? root.cDark : root.cMuted
                  Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                  Behavior on color { ColorAnimation { duration: 180 } }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: modelData.set(!modelData.get())
                }
              }
            }
          }
        }

        // ----- stats -----
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          font.family: "Agave Nerd Font"
          font.pixelSize: 10
          color: root.cMuted
          text: root.sessions + " sessions · " + root.focusMinutes + "m focus today"
        }
      }
    }
  }
}
