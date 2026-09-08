import Quickshell.Io
import QtQuick
import "../hyprconf"

// calculator tab of the intelligence central.
//
// A display fed by a button grid; `=` shells the expression out to
// python3 (sanitized to arithmetic characters only) since QML has no
// expression evaluator. Clicking the result copies it.
Item {
  id: root

  property string expr: ""
  property string result: ""
  property bool justEvaluated: false

  signal copyRequested(string text)

  readonly property var keys: [
    ["C", "(", ")", "⌫"],
    ["7", "8", "9", "÷"],
    ["4", "5", "6", "×"],
    ["1", "2", "3", "−"],
    ["0", ".", "+", "="]
  ]

  function press(k) {
    if (k === "C") { root.expr = ""; root.result = ""; root.justEvaluated = false; return; }
    if (k === "⌫") {
      root.expr = root.expr.slice(0, -1);
      root.justEvaluated = false;
      root.liveEval();
      return;
    }
    if (root.justEvaluated && !"+−×÷%".includes(k)) root.expr = "";
    root.justEvaluated = false;
    // display glyphs → arithmetic
    const op = { "×": "*", "÷": "/", "−": "-" }[k] || k;
    root.expr += op;
    root.liveEval();
  }

  function equals() {
    if (root.expr === "") return;
    // arithmetic chars only — python3 eval never sees anything else
    if (!/^[0-9+\-*/(). %]*$/.test(root.expr)) {
      root.result = "erro";
      return;
    }
    pyProc.expr = root.expr;
    pyProc.running = true;
  }

  function liveEval() {
    // live result while typing
    if (root.expr === "" || !/^[0-9+\-*/(). %]*$/.test(root.expr)) {
      if (root.expr !== "") root.result = "";
      return;
    }
    liveProc.expr = root.expr;
    liveProc.running = true;
  }

  Process {
    id: liveProc
    property string expr: ""
    command: ["python3", "-c", "import sys; print(eval(sys.argv[1]))", liveProc.expr]
    stdout: SplitParser { onRead: data => liveProc.liveResult = data.trim() }
    property string liveResult: ""
    onLiveResultChanged: if (root.expr !== "") root.result = liveResult
    onExited: code => { if (code !== 0 && root.expr !== "") root.result = ""; }
  }

  Process {
    id: pyProc
    property string expr: ""
    command: ["python3", "-c", "import sys; print(eval(sys.argv[1]))", pyProc.expr]
    stdout: SplitParser {
      onRead: data => pyProc.pyOut = data.trim()
    }
    property string pyOut: ""
    onPyOutChanged: {
      if (pyOut === "") return;
      root.expr = pyOut;
      root.result = "";
      root.justEvaluated = true;
    }
    onExited: code => { if (code !== 0) root.result = "erro"; }
  }

  Column {
    anchors.fill: parent
    spacing: 8

    // ----- display -----
    Rectangle {
      width: parent.width
      height: 84
      radius: 6
      color: Theme.surface
      border.color: Theme.border
      border.width: 1

      MouseArea {
        anchors.fill: parent
        enabled: root.result !== ""
        cursorShape: Qt.PointingHandCursor
        onClicked: root.copyRequested(root.result)
      }

      Text {
        id: exprText
        anchors.top: parent.top
        anchors.topMargin: 10
        anchors.right: parent.right
        anchors.rightMargin: 12
        text: root.expr.replace(/\*/g, "×").replace(/\//g, "÷")
        font.family: Theme.font
        font.pixelSize: 16
        color: Theme.text
        elide: Text.ElideLeft
        width: parent.width - 24
        horizontalAlignment: Text.AlignRight
      }

      Text {
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 10
        anchors.right: parent.right
        anchors.rightMargin: 12
        text: root.result === "" ? (root.expr === "" ? "0" : "") : root.result
        font.family: Theme.font
        font.bold: true
        font.pixelSize: 24
        color: root.result === "erro" ? Theme.err : Theme.live
        elide: Text.ElideRight
        width: parent.width - 24
        horizontalAlignment: Text.AlignRight
      }
    }

    // ----- keypad -----
    Grid {
      id: pad
      width: parent.width
      height: parent.height - 84 - 8 - 8
      columns: 4
      rows: 5
      spacing: 6

      Repeater {
        model: {
          const out = [];
          for (const r of root.keys) for (const k of r) out.push(k);
          return out;
        }

        delegate: Rectangle {
          required property string modelData

          width: (pad.width - 6 * 3) / 4
          height: (pad.height - 6 * 4) / 5
          radius: 6
          color: keyMa.containsMouse ? Theme.hover : Theme.surface
          Behavior on color { ColorAnimation { duration: 200 } }
          scale: keyMa.pressed ? 0.94 : 1
          Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

          Text {
            anchors.centerIn: parent
            // ⌫ renders oddly in the font — use the FA backspace glyph
            text: parent.modelData === "⌫" ? "\uf55a" : parent.modelData
            font.family: Theme.font
            font.bold: parent.modelData === "=" || parent.modelData === "C"
            font.pixelSize: parent.modelData === "⌫" ? 17 : 20
            color: parent.modelData === "C" ? Theme.err
                 : parent.modelData === "=" ? Theme.live : Theme.text
          }

          MouseArea {
            id: keyMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              const k = parent.modelData;
              if (k === "=") root.equals();
              else root.press(k);
            }
          }
        }
      }
    }
  }
}
