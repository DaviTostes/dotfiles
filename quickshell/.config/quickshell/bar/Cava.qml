pragma Singleton
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import QtQuick

// One cava process shared by every bar's Player pill.
//
// The Player pill is instantiated once per monitor, so running cava inside it
// would spawn one process per screen. This singleton owns the single process
// and publishes the bar levels; each pill just reads `levels` / `live`.
//
// cava runs with its own config (cava.conf next to shell.qml, reached through
// Quickshell.shellPath) and emits raw ASCII frames on stdout — one line per
// frame. Frames are normalised to 0..1 and (up/down)sampled onto `bars`
// values. When cava is not installed, or stops feeding, `live` goes false and
// the pill falls back to its synthetic animation, so the shell works fine
// without the dependency.
Item {
  id: root

  readonly property int bars: 11

  // normalized 0..1 levels, one per bar — the Player pill renders these
  property var levels: []

  // true while cava frames are arriving (gates the pill's fallback animation)
  property bool live: false

  // flips false once cava is known to be missing/crashed, so we stop trying
  property bool available: true

  readonly property bool anyPlaying: {
    const ps = Mpris.players.values;
    for (let i = 0; i < ps.length; i++)
      if (ps[i].playbackState === MprisPlaybackState.Playing) return true;
    return false;
  }

  // cava only runs while something is actually playing
  readonly property bool want: root.available && root.anyPlaying

  // retry on the next playback start, so a transient failure (or installing
  // cava mid-session) recovers without a shell reload
  onAnyPlayingChanged: if (root.anyPlaying) root.available = true

  Process {
    id: proc
    // stdbuf forces line buffering: cava's stdout is a pipe, which C stdio
    // would otherwise block-buffer, delaying every frame by ~4KB.
    command: ["stdbuf", "-oL", "cava", "-p", Quickshell.shellPath("cava.conf")]
    running: root.want
    stdout: SplitParser { onRead: data => root.applyFrame(data) }

    onExited: (exitCode, exitStatus) => {
      root.live = false;
      // a non-zero exit while we still wanted it running means cava failed
      // (or is not installed — stdbuf exits 127); give up until the next
      // playback start (see onAnyPlayingChanged)
      if (root.want && exitCode !== 0) root.available = false;
    }
  }

  // if no frame arrives for a while, stop trusting the last one
  Timer { id: watchdog; interval: 1500; onTriggered: root.live = false }

  function applyFrame(line) {
    const parts = line.split(";");
    const n = root.bars;
    const out = [];
    for (let i = 0; i < n; i++) {
      const src = Math.min(parts.length - 1, Math.floor(i * parts.length / n));
      const v = parseFloat(parts[src]);
      out.push(isNaN(v) ? 0 : Math.max(0, Math.min(1, v / 1000)));
    }
    root.levels = out;
    root.live = true;
    watchdog.restart();
  }

  Component.onCompleted: {
    const a = [];
    for (let i = 0; i < root.bars; i++) a.push(0);
    root.levels = a;
  }
}
