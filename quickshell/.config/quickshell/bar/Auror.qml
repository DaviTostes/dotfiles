import Quickshell
import Quickshell.Io
import QtQuick
import "../hyprconf"

// DLNA renderer pill for the `auror` daemon, stacked right above the volume
// pill. auror announces this machine on the LAN as a UPnP MediaRenderer and
// plays whatever a controller (BubbleUPnP, a smart TV, …) casts to it through
// mpv.
//
// The pill mirrors that: it polls auror's /status JSON (the port it bound to is
// published in ~/.cache/auror/port) and shows whether the renderer is up, what
// it is casting and how far along it is; the dropdown drives playback through
// the local control API (POST /api/play|pause|toggle|stop|seek|volume|next|
// previous). "offline" simply means the daemon is not running.
Pill {
  id: root

  // ---------- state ----------
  property var status: ({})
  property bool online: false

  // A poll can fail for a beat while mpv is (re)starting; never let a single
  // miss read as "offline", or the pill flickers between offline/idle/playing.
  property int missCount: 0
  readonly property int missTolerance: 3

  // Optimistic control state: a click applies locally at once and is held
  // until /status confirms it, so a still-stale poll cannot yank the UI back.
  property int pendingVol: -1        // 0..100, -1 = none
  property int pendingMute: -1       // 0/1, -1 = none
  property real pendingSeek: -1      // seconds, -1 = none

  readonly property bool hasMedia: root.online && (root.status.mpv_running || (root.status.current_url || "") !== "")
  readonly property string state: root.online ? (root.status.transport_state || "") : ""
  readonly property bool playing: root.hasMedia && root.state === "PLAYING"
  readonly property bool paused: root.state === "PAUSED_PLAYBACK"
  readonly property int volume: root.online
      ? (root.pendingVol >= 0 ? root.pendingVol : (root.status.volume || 0)) : 0
  readonly property bool muted: root.pendingMute >= 0
      ? root.pendingMute === 1 : (root.online && root.status.mute === true)

  readonly property real durSec: root.online ? (root.status.duration_seconds || 0) : 0
  readonly property real posSec: root.pendingSeek >= 0
      ? root.pendingSeek : (root.online ? (root.status.position_seconds || 0) : 0)
  readonly property real frac: root.durSec > 0
      ? Math.max(0, Math.min(1, root.posSec / root.durSec)) : 0
  readonly property string posLabel: root.pendingSeek >= 0
      ? root.formatHMS(root.pendingSeek) : (root.status.position || "00:00:00")

  readonly property int panelW: 260

  // Material Design cast glyphs, patched into Agave Nerd Font
  readonly property string icoOff: String.fromCodePoint(0xF078A)   // md-cast-off
  readonly property string icoIdle: String.fromCodePoint(0xF0118)  // md-cast
  readonly property string icoOn: String.fromCodePoint(0xF0119)    // md-cast-connected

  // a cast URL's last path segment, percent-decoded — good enough for a label
  function prettyTitle(u) {
    if (!u) return "";
    let s = ("" + u).split("?")[0].split("#")[0];
    const i = s.lastIndexOf("/");
    if (i >= 0) s = s.slice(i + 1);
    try { s = decodeURIComponent(s); } catch (e) {}
    return s === "" ? u : s;
  }

  function stateLabel() {
    switch (root.state) {
      case "PLAYING": return "playing";
      case "PAUSED_PLAYBACK": return "paused";
      case "STOPPED": return "stopped";
      case "TRANSITIONING": return "buffering";
      case "NO_MEDIA_PRESENT": return "idle";
    }
    return root.online ? "idle" : "offline";
  }

  function applyStatus(t) {
    let s = null;
    if (t && t.trim() !== "") {
      try { s = JSON.parse(t); } catch (e) { s = null; }
    }
    if (!s) {
      // transient miss: keep the last snapshot until it repeats
      root.missCount++;
      if (root.missCount >= root.missTolerance) root.online = false;
      return;
    }
    root.missCount = 0;
    root.status = s;
    root.online = true;

    // release each optimistic override once the server agrees
    if (root.pendingVol >= 0 && Math.abs((s.volume || 0) - root.pendingVol) <= 1)
      root.pendingVol = -1;
    if (root.pendingMute >= 0 && (s.mute === true) === (root.pendingMute === 1))
      root.pendingMute = -1;
    // pendingSeek is left to the timeout: mpv reports its new position a beat
    // after the seek lands, so agreement-based clearing could yank a drag back
  }

  function formatHMS(secs) {
    const t = Math.max(0, Math.floor(secs));
    const p = n => (n < 10 ? "0" : "") + n;
    return p(Math.floor(t / 3600)) + ":" + p(Math.floor((t % 3600) / 60)) + ":" + p(t % 60);
  }

  // safety net: drop optimistic state even if /status never confirms it
  Timer {
    id: pendingClear
    interval: 3000
    onTriggered: {
      root.pendingVol = -1;
      root.pendingMute = -1;
      root.pendingSeek = -1;
    }
  }

  // ---------- status polling ----------
  // one cheap `curl` per tick; adaptive so an absent daemon is almost free
  // while an open panel or running playback stays snappy
  Process {
    id: statusProc

    command: ["sh", "-c",
      "p=$(cat \"$HOME/.cache/auror/port\" 2>/dev/null) || exit 1; " +
      "curl -s -m 1.6 \"http://127.0.0.1:$p/status\""]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true;
  }

  Timer {
    id: poll
    // snappy while playing / panel open / recovering from a miss, lazy otherwise
    interval: (!root.online || root.missCount > 0 || root.panelOpen || root.playing) ? 1000 : 2500
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()

  // ---------- control API ----------
  // plain argv curl (no shell) against the port reported by /status
  Process { id: cmdProc; onExited: refreshSoon.restart() }
  Timer { id: refreshSoon; interval: 200; onTriggered: root.refresh() }

  function api(action, args) {
    if (!root.online) return;
    const cmd = ["curl", "-s", "-o", "/dev/null", "-m", "1.2", "-X", "POST"];
    for (const k in (args || {}))
      cmd.push("--data-urlencode", k + "=" + args[k]);
    cmd.push("http://127.0.0.1:" + root.status.http_port + "/api/" + action);
    cmdProc.command = cmd;
    cmdProc.running = true;
  }

  // ---------- pill ----------
  property bool panelOpen: false
  pillOpen: root.panelOpen

  implicitWidth: label.implicitWidth + 16

  Text {
    id: label
    anchors.centerIn: parent
    text: !root.online ? root.icoOff : (root.hasMedia ? root.icoOn : root.icoIdle)
    font.family: Theme.font
    font.pixelSize: 14
    color: !root.online ? Theme.idleText
        : root.playing ? Theme.live
        : root.paused ? Theme.muted
        : (root.panelOpen || root.hasMedia) ? Theme.accent : Theme.text
    Behavior on color { ColorAnimation { duration: 200 } }
  }

  // thin progress line along the pill's bottom while something is loaded
  Rectangle {
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 3
    anchors.horizontalCenter: parent.horizontalCenter
    width: Math.max(0, (parent.width - 8) * root.frac)
    height: 2
    radius: 1
    visible: root.durSec > 0
    color: root.paused ? Theme.muted : Theme.live
    Behavior on width { NumberAnimation { duration: 300 } }
  }

  MouseArea {
    id: ma
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: mouse => {
      if (mouse.button === Qt.RightButton && root.hasMedia)
        root.api("toggle");                       // play/pause
      else if (mouse.button === Qt.LeftButton)
        root.panelOpen = !root.panelOpen;
    }
    // scroll steps auror's own volume by 5
    onWheel: wheel => {
      if (!root.online) return;
      const step = wheel.angleDelta.y > 0 ? 5 : -5;
      const v = Math.max(0, Math.min(100, root.volume + step));
      root.pendingVol = v;
      pendingClear.restart();
      root.api("volume", { volume: v });
    }
  }

  Tip {
    target: root
    shown: ma.containsMouse && !root.panelOpen
    text: !root.online ? "auror offline"
        : root.hasMedia ? (root.prettyTitle(root.status.current_url) + "  ·  " + root.stateLabel())
        : "auror idle"
  }

  // click-outside close (same pattern as the volume panel)
  Catcher {
    active: root.panelOpen
    onClicked: root.panelOpen = false
  }

  onPanelOpenChanged: {
    if (root.panelOpen) { hideAnim.stop(); root.refresh(); }
    else hideAnim.restart();
  }

  // ---------- reusable bits ----------
  component IconBtn: Item {
    id: ib
    property string glyph
    property bool dim: false
    signal activated
    implicitWidth: 32
    implicitHeight: 28

    Text {
      anchors.centerIn: parent
      text: ib.glyph
      font.family: Theme.font
      font.pixelSize: 15
      color: ib.dim ? Theme.idleText : (ibMa.containsMouse ? Theme.accent : Theme.text)
      Behavior on color { ColorAnimation { duration: 180 } }
    }
    MouseArea {
      id: ibMa
      anchors.fill: parent
      hoverEnabled: true
      enabled: !ib.dim
      cursorShape: Qt.PointingHandCursor
      onClicked: ib.activated()
    }
  }

  // drag bar: `value` 0..1 from outside; drags emit `scrubbed` live (for UI
  // feedback) and `committed` on release (the actual request)
  component Bar: Item {
    id: bar
    property real value: 0
    property bool dim: false
    property real preview: -1
    readonly property real shown: preview >= 0
        ? preview : Math.max(0, Math.min(1, value))
    signal scrubbed(real frac)
    signal committed(real frac)

    implicitWidth: 260
    implicitHeight: 18

    function at(x) { return Math.max(0, Math.min(1, x / Math.max(1, width))); }

    Rectangle {
      id: track
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      height: 5
      radius: 3
      color: Theme.hover

      Rectangle {
        width: parent.width * bar.shown
        height: parent.height
        radius: 3
        color: bar.dim ? Theme.muted : Theme.accent
        Behavior on color { ColorAnimation { duration: 180 } }
      }

      Rectangle {
        x: Math.max(0, Math.min(parent.width, parent.width * bar.shown)) - width / 2
        anchors.verticalCenter: parent.verticalCenter
        width: 11
        height: 11
        radius: 6
        color: Theme.text
        opacity: bar.dim ? 0 : 1
        scale: barMa.containsMouse || barMa.pressed ? 1.2 : 1
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      }
    }

    MouseArea {
      id: barMa
      anchors.fill: parent
      hoverEnabled: true
      enabled: !bar.dim
      cursorShape: Qt.PointingHandCursor
      onPressed: mouse => { bar.preview = at(mouse.x); bar.scrubbed(bar.preview); }
      onPositionChanged: mouse => {
        if (!pressed) return;
        bar.preview = at(mouse.x);
        bar.scrubbed(bar.preview);
      }
      onReleased: {
        const f = bar.preview >= 0 ? bar.preview : bar.shown;
        bar.preview = -1;
        bar.committed(f);
      }
      onCanceled: bar.preview = -1
    }
  }

  // ---------- dropdown panel ----------
  PopupWindow {
    id: panel

    visible: root.panelOpen || hideAnim.running
    color: "transparent"

    Timer { id: hideAnim; interval: 220 }

    implicitWidth: body.implicitWidth + 24
    implicitHeight: body.implicitHeight + 16
    onVisibleChanged: if (visible) anchor.updateAnchor()
    onImplicitWidthChanged: if (visible) anchor.updateAnchor()
    onImplicitHeightChanged: if (visible) anchor.updateAnchor()

    anchor {
      window: root.QsWindow.window
      edges: Edges.Right
      gravity: Edges.Left
    }

    anchor.onAnchoring: {
      // the bar is on the right: open to the LEFT of the pill, vertically
      // centered on it and clamped so the panel never leaves the screen
      const p = root.mapToItem(null, 0, 0);
      const win = root.QsWindow.window;
      const sh = win && win.screen ? win.screen.height : 1080;
      const h = panel.implicitHeight;
      anchor.rect.x = p.x - 7;
      anchor.rect.y = Math.max(0, Math.min(p.y - h / 2 + root.height / 2, sh - h));
      anchor.rect.width = 1;
      anchor.rect.height = h;
    }

    Rectangle {
      anchors.fill: parent
      color: Theme.bg
      radius: 6
      border.color: Theme.border
      border.width: 1
    }

    Item {
      id: body
      anchors.centerIn: parent
      implicitWidth: root.panelW
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

        // ----- header: status dot + device name -----
        Item {
          width: root.panelW
          implicitHeight: 14

          Row {
            anchors.centerIn: parent
            height: 14
            spacing: 6

            Item {
              width: 6
              height: 14
              Rectangle {
                anchors.centerIn: parent
                width: 6; height: 6; radius: 3
                color: !root.online ? Theme.err
                    : root.playing ? Theme.live
                    : root.hasMedia ? Theme.accent : Theme.idleText
                Behavior on color { ColorAnimation { duration: 200 } }
              }
            }

            Text {
              height: 14
              verticalAlignment: Text.AlignVCenter
              text: root.online
                  ? (root.status.device_name || "auror") + "  ·  " + root.stateLabel()
                  : "auror offline"
              font.family: Theme.font
              font.pixelSize: 11
              color: root.online ? Theme.muted : Theme.err
            }
          }
        }

        // ----- now playing -----
        Column {
          width: root.panelW
          spacing: 3

          Text {
            width: parent.width
            elide: Text.ElideRight
            text: root.online
                ? (root.hasMedia ? root.prettyTitle(root.status.current_url) : "nothing cast")
                : "start the auror daemon"
            font.family: Theme.font
            font.bold: true
            font.pixelSize: 12
            color: root.hasMedia ? Theme.accent : Theme.idleText
          }

          Text {
            width: parent.width
            elide: Text.ElideRight
            visible: (root.status.current_sub || "") !== ""
            text: "sub: " + root.prettyTitle(root.status.current_sub)
            font.family: Theme.font
            font.pixelSize: 10
            color: Theme.muted
          }

          Text {
            width: parent.width
            elide: Text.ElideRight
            visible: (root.status.next_url || "") !== ""
            text: "next: " + root.prettyTitle(root.status.next_url)
            font.family: Theme.font
            font.pixelSize: 10
            color: Theme.muted
          }
        }

        // ----- seek -----
        Column {
          width: root.panelW
          spacing: 2
          visible: root.durSec > 0

          Bar {
            width: root.panelW
            value: root.frac
            dim: !root.hasMedia
            onScrubbed: frac => {
              root.pendingSeek = frac * root.durSec;
              pendingClear.restart();
            }
            onCommitted: frac => {
              const pos = Math.round(frac * root.durSec);
              root.pendingSeek = pos;
              pendingClear.restart();
              root.api("seek", { position: pos });
            }
          }

          Row {
            width: root.panelW

            Text {
              width: parent.width / 2
              text: root.posLabel
              font.family: Theme.font
              font.pixelSize: 9
              color: Theme.muted
            }
            Text {
              width: parent.width / 2
              horizontalAlignment: Text.AlignRight
              text: root.status.duration || "00:00:00"
              font.family: Theme.font
              font.pixelSize: 9
              color: Theme.muted
            }
          }
        }

        // ----- transport -----
        Item {
          width: root.panelW
          implicitHeight: 28

          Row {
            anchors.centerIn: parent
            spacing: 6

            IconBtn {
              glyph: "󰒮"          // md-skip_previous
              dim: !root.hasMedia
              onActivated: root.api("previous")
            }

            Rectangle {
              width: 42; height: 28; radius: 6
              color: playMa.containsMouse && root.hasMedia ? Theme.hover : Theme.surface
              Behavior on color { ColorAnimation { duration: 200 } }
              scale: playMa.containsMouse && root.hasMedia ? 1.06 : 1
              Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
              opacity: root.hasMedia ? 1 : 0.5

              Text {
                anchors.centerIn: parent
                text: root.playing ? "󰏤" : "󰐊"   // md-pause / md-play
                font.family: Theme.font
                font.pixelSize: 15
                color: Theme.text
              }

              MouseArea {
                id: playMa
                anchors.fill: parent
                hoverEnabled: true
                enabled: root.hasMedia
                cursorShape: Qt.PointingHandCursor
                onClicked: root.api("toggle")
              }
            }

            IconBtn {
              glyph: "󰒭"          // md-skip_next
              dim: !root.hasMedia
              onActivated: root.api("next")
            }

            IconBtn {
              glyph: "󰓛"          // md-stop
              dim: !root.hasMedia
              onActivated: root.api("stop")
            }
          }
        }

        // ----- volume -----
        Item {
          width: root.panelW
          implicitHeight: 22

          Row {
            anchors.centerIn: parent
            height: 22
            spacing: 8

            Item {
              width: 22
              height: 22

              Text {
                anchors.centerIn: parent
                text: root.muted ? "󰝟" : "󰕾"   // md-volume_mute / md-volume_high
                font.family: Theme.font
                font.pixelSize: 14
                color: root.muted ? Theme.err : (muteMa.containsMouse ? Theme.accent : Theme.text)
                Behavior on color { ColorAnimation { duration: 200 } }
              }

              MouseArea {
                id: muteMa
                anchors.fill: parent
                hoverEnabled: true
                enabled: root.online
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.pendingMute = root.muted ? 0 : 1;
                  pendingClear.restart();
                  root.api("mute");
                }
              }
            }

            Bar {
              width: 178
              value: Math.max(0, Math.min(1, root.volume / 100))
              dim: !root.online
              onScrubbed: frac => root.pendingVol = Math.round(frac * 100)
              onCommitted: frac => {
                const v = Math.round(frac * 100);
                root.pendingVol = v;
                pendingClear.restart();
                root.api("volume", { volume: v });
              }
            }

            Text {
              width: 26
              height: 22
              verticalAlignment: Text.AlignVCenter
              horizontalAlignment: Text.AlignRight
              text: root.online ? (root.muted ? "—" : root.volume + "%") : "—"
              font.family: Theme.font
              font.pixelSize: 10
              color: root.muted ? Theme.muted : Theme.accent
            }
          }
        }
      }
    }
  }
}
