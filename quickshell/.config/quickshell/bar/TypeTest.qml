import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import QtQuick.Shapes
import "../hyprconf"

// The desktop "desk toys": a monkeytype-style typing test and the arcade games
// (2048 / mines / dice / snake, in bar/DeskGames.qml), shown in the middle of
// an empty desktop. A row of tabs at the bottom center picks one; the tabs sit
// buried in the bottom bar (a relief) and all rise together on hover. The old
// arcade bar pill is gone.
//
// It is a fullscreen Bottom-layer surface with a CONSTANT OnDemand keyboard
// request (normal compositor focus semantics, so Hyprland keybinds are never
// swallowed; the surface unmaps whenever a window exists).
PanelWindow {
  id: root

  // ---------- which screen ----------
  readonly property var focusedScreen: {
    const m = Hyprland.focusedMonitor;
    if (!m) return null;
    const ss = Quickshell.screens;
    for (let i = 0; i < ss.length; i++) {
      const sm = Hyprland.monitorFor(ss[i]);
      if (sm && sm.name === m.name) return ss[i];
    }
    return null;
  }

  screen: root.focusedScreen

  // ---------- empty-workspace detection ----------
  readonly property HyprlandMonitor monitor: Hyprland.focusedMonitor
  readonly property bool empty: {
    const m = root.monitor;
    const ws = m ? m.activeWorkspace : null;
    if (!ws) return true;
    const ts = ws.toplevels;
    return !ts || ts.values.length === 0;
  }

  // ---------- window ----------
  visible: root.empty
  color: "transparent"
  anchors { top: true; bottom: true; left: true; right: true }
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Bottom
  WlrLayershell.namespace: "quickshell-desk"
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

  // view: -1 = nothing, 0 = typing test, 1..4 = 2048 / mines / dice / snake
  property int view: -1
  readonly property bool typeOn: root.view === 0
  readonly property bool gameOn: root.view >= 1

  // =======================================================================
  //  typing test state
  // =======================================================================
  property string mode: "time"        // time | words
  property int timeLimit: 30          // seconds
  property int wordCount: 25
  property string difficulty: "normal" // normal | punctuation | numbers

  property var words: []
  property string target: ""
  property string typed: ""
  property bool started: false
  property bool finished: false
  property real startMs: 0
  property real elapsed: 0            // seconds
  property int totalKeys: 0
  property int correctKeys: 0
  property var samples: []
  property int lastSample: 0
  property bool newPb: false

  property real shownWpm: 0
  property real resultWpm: 0
  property real wordsOpacity: 1

  readonly property string key: root.mode + "-" + root.value
  readonly property int value: root.mode === "time" ? root.timeLimit : root.wordCount
  readonly property bool typing: root.started && !root.finished
  readonly property real lineH: Math.round(26 * 1.35)

  readonly property var wordPool: [
    "the", "be", "of", "and", "a", "to", "in", "he", "have", "it", "that",
    "for", "they", "with", "as", "not", "on", "she", "at", "by", "this",
    "we", "you", "do", "but", "from", "or", "which", "one", "would", "all",
    "will", "there", "say", "who", "make", "when", "can", "more", "if",
    "no", "man", "out", "other", "so", "what", "time", "up", "go", "about",
    "than", "into", "could", "state", "only", "new", "year", "some", "take",
    "come", "these", "know", "see", "use", "get", "like", "then", "first",
    "any", "work", "now", "may", "such", "give", "over", "think", "most",
    "even", "find", "day", "also", "after", "way", "many", "must", "look",
    "before", "great", "back", "through", "long", "where", "much", "should",
    "well", "people", "down", "own", "just", "because", "good", "each",
    "those", "feel", "seem", "how", "high", "too", "place", "little",
    "world", "very", "still", "nation", "hand", "old", "life", "tell",
    "write", "become", "here", "show", "house", "both", "between", "need",
    "mean", "call", "develop", "under", "last", "right", "move", "thing",
    "general", "school", "never", "same", "another", "begin", "while",
    "number", "part", "turn", "real", "leave", "might", "want", "point",
    "form", "off", "child", "few", "small", "since", "against", "ask",
    "late", "home", "interest", "large", "person", "end", "open", "public",
    "follow", "during", "present", "without", "again", "hold", "govern",
    "around", "possible", "head", "consider", "word", "program", "problem",
    "however", "lead", "system", "set", "order", "eye", "plan", "run",
    "keep", "face", "fact", "group", "play", "stand", "increase", "early",
    "course", "change", "help", "line"
  ]

  readonly property string cCorrect: Theme.text
  readonly property string cWrong: Theme.err
  readonly property string cPending: Theme.muted

  function punctuate(w) {
    const pre = ["", "", "", "\"", "'", "(", "["];
    const post = [".", ",", "?", "!", ";", ":", "\"", "'", ")", "]"];
    return pre[Math.floor(Math.random() * pre.length)] + w
         + post[Math.floor(Math.random() * post.length)];
  }

  function pickWords(n) {
    const out = [];
    const pool = root.wordPool;
    for (let i = 0; i < n; i++) {
      let w = pool[Math.floor(Math.random() * pool.length)];
      if (root.difficulty === "numbers" && Math.random() < 0.25)
        w = String(1 + Math.floor(Math.random() * 9999));
      else if (root.difficulty === "punctuation" && Math.random() < 0.30)
        w = root.punctuate(w);
      out.push(w);
    }
    return out;
  }

  function newTest() {
    const n = root.mode === "time" ? 160 : root.wordCount;
    root.words = root.pickWords(n);
    root.target = root.words.join(" ");
    root.typed = "";
    root.started = false;
    root.finished = false;
    root.elapsed = 0;
    root.startMs = 0;
    root.totalKeys = 0;
    root.correctKeys = 0;
    root.samples = [];
    root.lastSample = 0;
    root.newPb = false;
    root.shownWpm = 0;
    root.resultWpm = 0;
    if (input.text !== "") input.text = "";
    root.wordsOpacity = 0;
    fadeIn.restart();
    if (root.visible) Qt.callLater(() => input.forceActiveFocus());
  }

  function startTest() {
    root.started = true;
    root.startMs = Date.now();
    root.elapsed = 0;
    root.lastSample = 0;
  }

  function onInputChanged() {
    const t = input.text;
    if (!root.started && t.length > 0) root.startTest();

    const prev = root.typed;
    if (t.length > prev.length) {
      const i = prev.length;
      root.totalKeys++;
      if (i < root.target.length && t[i] === root.target[i]) root.correctKeys++;
    }
    root.typed = t;

    if (!root.finished && root.mode === "words" && t.length >= root.target.length)
      root.finish();
  }

  function tick() {
    root.elapsed = (Date.now() - root.startMs) / 1000;
    root.shownWpm = root.wpm();
    const sec = Math.floor(root.elapsed);
    if (sec > root.lastSample) {
      root.lastSample = sec;
      const s = root.samples.slice();
      s.push(root.rawWpm());
      root.samples = s;
    }
    if (root.mode === "time" && root.elapsed >= root.timeLimit) root.finish();
  }

  function finish() {
    if (root.finished) return;
    root.finished = true;
    tick.stop();
    if (root.elapsed <= 0) root.elapsed = 0.001;
    root.newPb = TypeStore.record(root.key, Math.round(root.wpm()),
                                  Math.round(root.accuracy()), Math.round(root.rawWpm()),
                                  Math.round(root.consistency()));
    resultAnim.from = 0;
    resultAnim.to = root.wpm();
    resultAnim.restart();
  }

  function correctChars() {
    const tgt = root.target, t = root.typed;
    let n = 0;
    const len = Math.min(tgt.length, t.length);
    for (let i = 0; i < len; i++) if (t[i] === tgt[i]) n++;
    return n;
  }

  function minutes() { return Math.max(root.elapsed, 0.001) / 60; }
  function wpm() { return (root.correctChars() / 5) / root.minutes(); }
  function rawWpm() { return (root.typed.length / 5) / root.minutes(); }
  function accuracy() {
    return root.totalKeys > 0 ? (root.correctKeys / root.totalKeys) * 100 : 100;
  }
  function consistency() {
    const s = root.samples;
    if (s.length < 2) return 0;
    let mean = 0;
    for (let i = 0; i < s.length; i++) mean += s[i];
    mean /= s.length;
    if (mean <= 0) return 0;
    let v = 0;
    for (let i = 0; i < s.length; i++) v += (s[i] - mean) * (s[i] - mean);
    const sd = Math.sqrt(v / s.length);
    return Math.max(0, Math.min(100, (1 - sd / mean) * 100));
  }

  readonly property int cursorIndex: Math.min(root.typed.length, root.target.length)

  readonly property real progress: {
    if (root.finished) return 1;
    if (root.mode === "time") return Math.min(1, root.elapsed / root.timeLimit);
    return root.target.length > 0 ? Math.min(1, root.typed.length / root.target.length) : 0;
  }

  readonly property var sparkPoints: {
    const s = root.samples;
    const pts = [];
    if (s.length < 2) return pts;
    const w = 340, h = 54;
    let max = 1;
    for (let i = 0; i < s.length; i++) if (s[i] > max) max = s[i];
    for (let i = 0; i < s.length; i++)
      pts.push(Qt.point((i / (s.length - 1)) * w, h - (s[i] / max) * h));
    return pts;
  }

  function esc(ch) {
    if (ch === "&") return "&amp;";
    if (ch === "<") return "&lt;";
    if (ch === ">") return "&gt;";
    return ch;
  }

  function wordsHtml() {
    const tgt = root.target, t = root.typed, tlen = t.length;

    const ci = root.cursorIndex;
    let ws = ci, we = ci;
    while (ws > 0 && tgt[ws - 1] !== " ") ws--;
    while (we < tgt.length && tgt[we] !== " ") we++;

    let html = "", run = "", runColor = "", runU = false;
    function flush() {
      if (run === "") return;
      html += (runU ? "<u>" : "") + "<font color=\"" + runColor + "\">"
            + run + "</font>" + (runU ? "</u>" : "");
      run = "";
    }

    for (let i = 0; i < tgt.length; i++) {
      const color = i < tlen ? (t[i] === tgt[i] ? root.cCorrect : root.cWrong)
                             : root.cPending;
      const u = i >= ws && i < we;
      if (color !== runColor || u !== runU) { flush(); runColor = color; runU = u; }
      run += root.esc(tgt[i]);
    }
    flush();

    if (tlen > tgt.length) {
      let extra = "";
      for (let i = tgt.length; i < tlen; i++) extra += root.esc(t[i]);
      html += "<font color=\"" + root.cWrong + "\">" + extra + "</font>";
    }
    return html;
  }

  // =======================================================================
  //  lifecycle
  // =======================================================================
  Component.onCompleted: root.newTest()

  onVisibleChanged: if (root.visible && root.typeOn) root.newTest()

  onViewChanged: {
    if (root.typeOn && root.visible) root.newTest();
    else tick.stop();
    if (root.view >= 0 && root.visible) Qt.callLater(() => input.forceActiveFocus());
  }

  Timer {
    id: tick
    interval: 100
    repeat: true
    running: root.visible && root.typeOn && root.started && !root.finished
    onTriggered: root.tick()
  }

  NumberAnimation {
    id: fadeIn
    target: root; property: "wordsOpacity"
    to: 1; duration: 200; easing.type: Easing.OutCubic
  }

  NumberAnimation {
    id: resultAnim
    target: root; property: "resultWpm"
    duration: 650; easing.type: Easing.OutCubic
  }

  // hidden keyboard sink: the surface is focused, so this is typed into
  // directly (launcher model)
  TextInput {
    id: input
    width: 0; height: 0
    opacity: 0
    // focused whenever a toy is shown, so the games get the keys too
    focus: root.view >= 0 && root.visible
    onTextChanged: {
      if (root.typeOn) root.onInputChanged();
      else if (text !== "") text = "";   // games: never accumulate text
    }

    Keys.onPressed: event => {
      // esc leaves whatever is open (typing test or any game)
      if (event.key === Qt.Key_Escape) {
        root.view = -1;
        event.accepted = true;
        return;
      }
      if (root.gameOn) { games.handleKey(event); return; }
      if (event.key === Qt.Key_Tab) {
        root.newTest();
        event.accepted = true;
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (root.finished) { root.newTest(); event.accepted = true; }
      }
    }
  }

  // =======================================================================
  //  UI
  // =======================================================================
  Item {
    anchors.fill: parent

    // ------------------------- typing test -------------------------
    Item {
      id: panelWrap

      visible: root.typeOn
      width: content.width + 68
      height: content.implicitHeight + 60
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(56, parent.height * 0.5 - height * 0.5)

      opacity: root.typeOn ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
      transform: Translate {
        y: root.typeOn ? 0 : 18
        Behavior on y { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
      }

      Rectangle {
        anchors.fill: parent
        radius: 18
        color: Qt.alpha(Theme.bg, 0.95)
        border.color: Theme.border
        border.width: 1
      }

      Column {
        id: content

        anchors.centerIn: parent
        width: Math.min(root.width - 200, 900)
        spacing: 22

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 8
          opacity: root.typing ? 0.22 : 1
          Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

          component Chip: Rectangle {
            property string label
            property bool sel: false
            signal activated

            width: labelText.implicitWidth + 20
            height: 26
            radius: 6
            color: sel ? Theme.accent
                 : chipMa.containsMouse ? Theme.hover : Qt.alpha(Theme.surface, 0.8)
            Behavior on color { ColorAnimation { duration: 180 } }
            scale: chipMa.pressed ? 0.95 : (chipMa.containsMouse ? 1.05 : 1)
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

            Text {
              id: labelText
              anchors.centerIn: parent
              text: parent.label
              font.family: Theme.font
              font.pixelSize: 11
              font.bold: parent.sel
              color: parent.sel ? Theme.deep : Theme.text
            }

            MouseArea {
              id: chipMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: parent.activated()
            }
          }

          Chip { label: "time"; sel: root.mode === "time"
                 onActivated: { root.mode = "time"; root.newTest(); } }
          Chip { label: "words"; sel: root.mode === "words"
                 onActivated: { root.mode = "words"; root.newTest(); } }

          Item { width: 10; height: 1 }

          Repeater {
            model: root.mode === "time" ? [15, 30, 60] : [10, 25, 50]
            delegate: Chip {
              required property int modelData
              label: String(modelData)
              sel: root.value === modelData
              onActivated: {
                if (root.mode === "time") root.timeLimit = modelData;
                else root.wordCount = modelData;
                root.newTest();
              }
            }
          }

          Item { width: 10; height: 1 }

          Repeater {
            model: [
              { label: "normal", v: "normal" },
              { label: "punct", v: "punctuation" },
              { label: "num", v: "numbers" }
            ]
            delegate: Chip {
              required property var modelData
              label: modelData.label
              sel: root.difficulty === modelData.v
              onActivated: { root.difficulty = modelData.v; root.newTest(); }
            }
          }
        }

        Item {
          width: parent.width
          height: 44

          Text {
            anchors.left: parent.left
            anchors.top: parent.top
            font.family: Theme.font
            font.bold: true
            font.pixelSize: 16
            color: Theme.accent2
            text: root.mode === "time"
                ? Math.max(0, Math.ceil(root.timeLimit - root.elapsed))
                : Math.min(root.words.length,
                           root.typed === "" ? 0 : root.typed.split(" ").length)
                  + "/" + root.words.length
          }

          Row {
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: 18

            Text {
              font.family: Theme.font; font.pixelSize: 12; color: Theme.muted
              textFormat: Text.RichText
              text: "wpm <font color=\"" + Theme.accent + "\">"
                    + Math.round(root.shownWpm) + "</font>"
            }
            Text {
              font.family: Theme.font; font.pixelSize: 12; color: Theme.muted
              textFormat: Text.RichText
              text: "acc <font color=\"" + Theme.accent + "\">"
                    + Math.round(root.accuracy()) + "%</font>"
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 3
            radius: 1.5
            color: Qt.alpha(Theme.surface, 0.8)

            Rectangle {
              width: parent.width * root.progress
              height: parent.height
              radius: 1.5
              color: root.finished ? Theme.live : Theme.accent
              Behavior on color { ColorAnimation { duration: 200 } }
              Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            }
          }
        }

        Item {
          id: stage
          width: parent.width
          implicitHeight: root.finished ? resultBox.implicitHeight
                                        : Math.max(wordsText.contentHeight, 150)

          Item {
            id: wordsWrap
            visible: !root.finished
            width: parent.width
            height: parent.height
            opacity: root.wordsOpacity

            TextEdit {
              id: wordsText
              width: parent.width
              height: contentHeight
              readOnly: true
              selectByMouse: false
              activeFocusOnPress: false
              cursorVisible: false
              textFormat: TextEdit.RichText
              wrapMode: TextEdit.Wrap
              font.family: Theme.font
              font.pixelSize: 26
              color: Theme.muted
              text: root.wordsHtml()
            }

            Rectangle {
              id: caret
              readonly property var rect: wordsText.positionToRectangle(root.cursorIndex)
              x: rect.x
              y: rect.y
              width: 2
              height: rect.height > 0 ? rect.height : root.lineH
              radius: 1
              color: Theme.accent
              opacity: root.typing ? 1 : 0.5
              Behavior on x { NumberAnimation { duration: 80; easing.type: Easing.OutCubic } }
              Behavior on y { NumberAnimation { duration: 80; easing.type: Easing.OutCubic } }

              SequentialAnimation on opacity {
                loops: Animation.Infinite
                running: !root.finished
                NumberAnimation { to: 0.15; duration: 520; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.0; duration: 520; easing.type: Easing.InOutSine }
              }
            }
          }

          Column {
            id: resultBox
            visible: root.finished
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 8

            opacity: root.finished ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            transform: Translate {
              y: root.finished ? 0 : 12
              Behavior on y { NumberAnimation { duration: 340; easing.type: Easing.OutCubic } }
            }

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: 10

              Text {
                anchors.baseline: wpmBig.baseline
                font.family: Theme.font; font.pixelSize: 14; color: Theme.muted
                text: "wpm"
              }
              Text {
                id: wpmBig
                font.family: Theme.font; font.bold: true; font.pixelSize: 58
                color: Theme.accent
                text: Math.round(root.resultWpm)
              }
              Text {
                anchors.baseline: wpmBig.baseline
                visible: root.newPb
                font.family: Theme.font; font.bold: true; font.pixelSize: 13
                color: Theme.live
                text: "new pb!"
                SequentialAnimation on scale {
                  loops: Animation.Infinite
                  running: root.newPb
                  NumberAnimation { to: 1.12; duration: 520; easing.type: Easing.InOutSine }
                  NumberAnimation { to: 1.0; duration: 520; easing.type: Easing.InOutSine }
                }
              }
            }

            Shape {
              anchors.horizontalCenter: parent.horizontalCenter
              width: 340
              height: 54
              visible: root.sparkPoints.length >= 2
              layer.enabled: true

              ShapePath {
                strokeColor: Theme.accent2
                strokeWidth: 2
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathPolyline { path: root.sparkPoints }
              }
            }

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              topPadding: 4
              spacing: 26

              Repeater {
                model: [
                  { l: "acc", v: Math.round(root.accuracy()) + "%" },
                  { l: "raw", v: String(Math.round(root.rawWpm())) },
                  { l: "consistency", v: Math.round(root.consistency()) + "%" },
                  { l: "time", v: Math.round(root.elapsed) + "s" }
                ]
                delegate: Column {
                  required property var modelData
                  spacing: 2

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
                    text: parent.modelData.l
                  }
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    font.family: Theme.font; font.bold: true; font.pixelSize: 18
                    color: Theme.text
                    text: parent.modelData.v
                  }
                }
              }
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              topPadding: 8
              font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
              text: "tab — new test · esc — close"
            }
          }
        }

        Item {
          width: parent.width
          height: 18

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.finished
            font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
            opacity: root.started ? 0 : 0.75
            Behavior on opacity { NumberAnimation { duration: 300 } }
            text: "start typing…"
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
            text: {
              const pb = TypeStore.pb(root.key);
              return pb ? "pb " + Math.round(pb.wpm) + " wpm · "
                          + Math.round(pb.acc) + "%" : "";
            }
          }
        }
      }
    }

    // ------------------------- games -------------------------
    Item {
      id: gamesWrap

      visible: root.gameOn
      width: Math.max(games.implicitWidth, 300) + 56
      height: games.implicitHeight + 56
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(56, parent.height * 0.5 - height * 0.5)

      opacity: root.gameOn ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
      transform: Translate {
        y: root.gameOn ? 0 : 18
        Behavior on y { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
      }

      Rectangle {
        anchors.fill: parent
        radius: 18
        color: Qt.alpha(Theme.bg, 0.95)
        border.color: Theme.border
        border.width: 1
      }

      // "new" for the two games that have a board to reset
      Rectangle {
        id: gameNewBtn

        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 12
        visible: root.view === 1 || root.view === 2 || root.view === 4
        width: newGameText.implicitWidth + 16
        height: 24
        radius: 6
        color: gameNewMa.containsMouse ? Theme.hover : Theme.surface
        Behavior on color { ColorAnimation { duration: 200 } }

        Text {
          id: newGameText
          anchors.centerIn: parent
          font.family: Theme.font
          font.pixelSize: 10
          color: gameNewMa.containsMouse ? Theme.accent : Theme.text
          text: "new"
        }

        MouseArea {
          id: gameNewMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: games.resetCurrent()
        }
      }

      Item {
        anchors.centerIn: parent
        width: games.implicitWidth
        height: games.implicitHeight

        DeskGames {
          id: games
          anchors.fill: parent
          active: root.visible && root.gameOn
          tab: Math.max(0, root.view - 1)
        }
      }
    }

    // ------------------------- dock -------------------------
    // A row of tabs, one per toy. Idle they sit flush against each other in the
    // bar's colour with only their outer top corners rounded — a single "mound"
    // of the bar. Bringing the pointer near opens the gaps, lifts them and
    // turns them into pills, all in one animation.
    Item {
      id: dock

      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      width: 5 * 40 + 4 * 6
      height: 64

      HoverHandler { id: dockHover }
      readonly property bool shown: dockHover.hovered

      Row {
        id: dockRow
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: dock.shown ? 6 : 0
        Behavior on spacing { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
        y: dock.shown ? 2 : 50
        Behavior on y {
          NumberAnimation { duration: 460; easing.type: Easing.OutBack; easing.overshoot: 1.25 }
        }

        Repeater {
          model: [
            { v: 0, icon: "\uf11c" },   // keyboard — typing test
            { v: 1, icon: "\uf00a" },   // grid — 2048
            { v: 2, icon: "\uf1e2" },   // bomb — mines
            { v: 3, icon: "\uf522" },   // dice
            { v: 4, icon: "\uf0c1" }    // snake
          ]

          delegate: Rectangle {
            id: dockTab

            required property var modelData
            required property int index
            readonly property bool sel: root.view === dockTab.modelData.v
            readonly property bool first: dockTab.index === 0
            readonly property bool last: dockTab.index === 4

            width: 40
            height: 40
            // hidden: only the outer ends round, so the flush row reads as ONE
            // mound; shown: every corner rounds into a pill
            topLeftRadius: dock.shown ? 10 : (dockTab.first ? 7 : 0)
            topRightRadius: dock.shown ? 10 : (dockTab.last ? 7 : 0)
            bottomLeftRadius: dock.shown ? 10 : 0
            bottomRightRadius: dock.shown ? 10 : 0
            color: dock.shown
                 ? (dockTab.sel ? Theme.accent
                    : dockTabMa.containsMouse ? Theme.hover : Theme.pill)
                 : Theme.bg
            border.width: 1
            border.color: dock.shown
                        ? (dockTab.sel ? Theme.accent : Theme.border) : "transparent"
            Behavior on color { ColorAnimation { duration: 260 } }
            Behavior on border.color { ColorAnimation { duration: 260 } }
            Behavior on topLeftRadius { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
            Behavior on topRightRadius { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
            Behavior on bottomLeftRadius { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
            Behavior on bottomRightRadius { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
            scale: dockTabMa.pressed ? 0.9 : (dockTabMa.containsMouse ? 1.08 : 1)
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

            Text {
              anchors.centerIn: parent
              text: dockTab.modelData.icon
              font.family: Theme.font
              font.pixelSize: 15
              color: dockTab.sel ? Theme.deep : Theme.text
              opacity: dock.shown ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
              Behavior on color { ColorAnimation { duration: 200 } }
            }

            MouseArea {
              id: dockTabMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.view = (root.view === dockTab.modelData.v ? -1 : dockTab.modelData.v)
            }
          }
        }
      }
    }
  }
}
