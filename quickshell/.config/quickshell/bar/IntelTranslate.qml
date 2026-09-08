import Quickshell.Io
import QtQuick
import QtQuick.Controls.Basic
import "../hyprconf"

// translate tab of the intelligence central.
//
// Auto-detects the source language and translates on a debounce while the
// user types. The visible field mirrors the BAR's hiddenInput (the popup
// window is keyboard-less — see Opencode.qml's hiddenInput comment), so
// editing happens there and flows in both ways.
Item {
  id: root

  signal copyRequested(string text)
  signal cursorMoved(int pos)

  // routed from the bar's hiddenInput while the translate tab is open
  property string sourceText: ""
  property string target: "en"
  property string output: ""
  property string detected: ""
  property bool busy: false
  property bool syncing: false
  property bool panelActive: false

  // cursor mirror from the bar's real editor
  function setCursorPos(p) { sourceField.cursorPosition = p; }

  onSourceTextChanged: if (!root.syncing) {
    root.syncing = true;
    sourceField.text = sourceText;
    root.syncing = false;
    autoTimer.restart();
  }

  // ---------- translation (unofficial web endpoint, auto-detect) ----------
  function translate() {
    const q = sourceText.trim();
    if (q === "") { root.output = ""; root.detected = ""; return; }
    root.busy = true;
    curlProc.url = "https://clients5.google.com/translate_a/t"
        + "?client=dict-chrome-ex&sl=auto&tl=" + root.target
        + "&q=" + encodeURIComponent(q);
    curlProc.running = true;
  }

  Process {
    id: curlProc
    property string url: ""
    property string out: ""
    command: ["curl", "-s", "-m", "12", curlProc.url]
    stdout: SplitParser {
      onRead: data => curlProc.out += data
    }
  onStarted: { root.busy = true; curlProc.out = ""; }
    onExited: code => {
      root.busy = false;
      if (code !== 0 || curlProc.out === "") {
        root.output = "tradução falhou";
        root.detected = "";
        return;
      }
      // [[seg, detected], ...] → join the translated segments
      // (single-word replies nest: [[["sexo"]]])
      let data;
      try { data = JSON.parse(curlProc.out); } catch (e) { data = null; }
      if (!data || !data.length) {
        root.output = "tradução falhou";
        root.detected = "";
        return;
      }
      root.detected = (data[0] && data[0].length > 1) ? data[0][1] : "";
      root.output = data.map(seg => {
        if (!seg || !seg.length) return "";
        return Array.isArray(seg[0]) ? (seg[0][0] || "") : (seg[0] || "");
      }).join(" ").trim();
    }
  }

  // debounce: translate ~1s after the last keystroke
  Timer {
    id: autoTimer
    interval: 1000
    onTriggered: root.translate()
  }

  Column {
    anchors.fill: parent
    spacing: 8

    // ----- target language chips (label the output) -----
    Row {
      spacing: 6
      anchors.right: parent.right

      // target selector: one chip per language, swap = set target to the
      // detected source language
      Repeater {
        model: [
          { id: "en", label: "EN" },
          { id: "es", label: "ES" },
          { id: "pt", label: "PT" }
        ]

        Rectangle {
          required property var modelData
          readonly property bool cur: root.target === modelData.id
          width: 34; height: 20; radius: 5
          color: cur ? Theme.accent
               : chipMa.containsMouse ? Theme.hover : Theme.surface
          Behavior on color { ColorAnimation { duration: 200 } }
          Text {
            anchors.centerIn: parent
            text: parent.modelData.label
            font.family: Theme.font
            font.bold: parent.cur
            font.pixelSize: 10
            color: parent.cur ? Theme.deep : Theme.text
          }
          MouseArea {
            id: chipMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.target = parent.modelData.id;
              root.translate();
            }
          }
        }
      }

      // swap: target becomes the detected source language
      Rectangle {
        width: 34; height: 20; radius: 5
        color: swapMa.containsMouse ? Theme.hover : Theme.surface
        Behavior on color { ColorAnimation { duration: 200 } }
        Text {
          anchors.centerIn: parent
          text: "\uf07e"          // exchange arrows
          font.family: Theme.font
          font.pixelSize: 10
          color: root.detected !== "" && root.detected !== root.target
                 ? Theme.accent : Theme.muted
        }
        MouseArea {
          id: swapMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: root.detected !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: {
            if (root.detected === "" || root.detected === root.target) return;
            const map = { "pt-BR": "pt", pt: "pt", es: "es", en: "en" };
            root.target = map[root.detected] || "en";
            root.translate();
          }
        }
      }
    }

    // ----- output (response on top, like a chat) -----
    Rectangle {
      width: parent.width
      height: parent.height - 110 - 20 - 8 - 8 - 8
      radius: 6
      color: Theme.bg
      border.color: Theme.border
      border.width: 1

      Text {
        visible: root.detected !== ""
        anchors.top: parent.top
        anchors.topMargin: 6
        anchors.right: parent.right
        anchors.rightMargin: 10
        text: root.detected + " → " + root.target
        font.family: Theme.font
        font.pixelSize: 9
        color: Theme.muted
      }

      SelText {
        id: outText
        anchors.fill: parent
        anchors.margins: 10
        text: root.output
        textFormat: TextEdit.PlainText
        font.pixelSize: 13
        color: root.output === "tradução falhou" ? Theme.err : Theme.accent
        onCopied: root.copyRequested("")
      }

      // busy hint
      Text {
        visible: root.busy
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: 10
        text: "◌ traduzindo…"
        font.family: Theme.font
        font.pixelSize: 9
        color: Theme.muted
      }

      // copy-all chip
      Rectangle {
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        anchors.right: parent.right
        anchors.rightMargin: 8
        width: copyLabel.implicitWidth + 14
        height: 22
        radius: 5
        color: copyMa.containsMouse ? Theme.hover : Theme.surface
        Behavior on color { ColorAnimation { duration: 200 } }
        Text {
          id: copyLabel
          anchors.centerIn: parent
          text: "copiar"
          font.family: Theme.font
          font.pixelSize: 10
          color: Theme.text
        }
        MouseArea {
          id: copyMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (root.output !== "") {
              root.copyRequested(root.output);
            }
          }
        }
      }
    }

    // ----- source field (input at the bottom, chat-style) -----
    Rectangle {
      width: parent.width
      height: 110
      radius: 6
      color: Theme.surface
      border.color: root.panelActive ? Theme.muted : Theme.border
      border.width: 1

      TextField {
        id: sourceField
        anchors.fill: parent
        anchors.margins: 10
        background: null
        placeholderText: "digite o texto…  (detecta o idioma)"
        placeholderTextColor: Theme.idleText
        color: Theme.accent
        font.family: Theme.font
        font.pixelSize: 13
        wrapMode: TextInput.Wrap
        selectionColor: Theme.hover
        selectedTextColor: Theme.accent
        // the popup is keyboard-less: the bar's hiddenInput is the real
        // editor — fake the caret here while the panel is open
        cursorVisible: root.panelActive
        cursorDelegate: Item {
          implicitWidth: 2
          Rectangle {
            anchors.fill: parent
            radius: 1
            color: Theme.accent
            SequentialAnimation on opacity {
              running: root.panelActive
              loops: Animation.Infinite
              NumberAnimation { to: 1; duration: 600 }
              NumberAnimation { to: 0; duration: 600 }
            }
          }
        }
        onTextChanged: if (!root.syncing) {
          root.syncing = true;
          root.sourceText = text;
          root.syncing = false;
          autoTimer.restart();
        }
        onCursorPositionChanged: if (!root.syncing) {
          root.syncing = true;
          root.cursorMoved(cursorPosition);
          root.syncing = false;
        }
      }
    }
  }

  // keyboard wiring handled by the host (Opencode.qml) — it owns the
  // hiddenInput that mirrors `sourceText` while this tab is open
}
