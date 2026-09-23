pragma Singleton
import QtQuick

// Palette + font for the hypr config panel.
// Colors match the bar's Pomodoro pill / dropdown style.
QtObject {
    readonly property string font: "Agave Nerd Font"

    readonly property color bg: "#161719"       // panel background
    readonly property color border: "#282a2e"   // panel border / ring track
    readonly property color surface: "#1e2126"  // cards / buttons / chips
    readonly property color hover: "#282c33"    // hover surface
    readonly property color deep: "#101216"     // text on accent fills
    readonly property color text: "#e4e8ee"     // primary text
    readonly property color muted: "#949eab"    // secondary text
    readonly property color accent: "#d3d9e0"   // selected / accent fills
    readonly property color accent2: "#8b95a3"  // secondary accent

    // chrome + status colors shared with the bar pills
    readonly property color pill: "#222222"     // pill background chrome
    readonly property color live: "#a6e3a1"     // running / streaming
    readonly property color err: "#d2686a"      // errors / destructive
    readonly property color idleText: "#7d8791" // idle / dimmed pill text
    readonly property color paused: "#4a505a"   // dimmed state accent

    // Per-prefix tag colors (bar/Tasks.qml). A prefix is hashed to an index,
    // so the same prefix always maps to the same color across restarts.
    // Deliberately vivid: these are meant to stand out against the muted
    // chrome and group tasks at a glance.
    readonly property var tagColors: [
        "#ff6b6b", // red
        "#ffa94d", // orange
        "#ffd43b", // yellow
        "#51cf66", // green
        "#22d3ee", // cyan
        "#4dabf7", // blue
        "#9775fa", // violet
        "#f783ac"  // pink
    ]
}
