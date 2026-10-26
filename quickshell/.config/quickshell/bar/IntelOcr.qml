import Quickshell
import Quickshell.Io
import QtQuick
import "../hyprconf"

// ocr tab of the intelligence central.
//
// The small card is a drop target: paste an image from the Wayland clipboard
// (Ctrl+V anywhere in the tab, or click the card) and tesseract writes what it
// recognised to stdout. On success the card grows into a full-height result
// box with a scrollable, auto-copying text block (SelText, same as the chat)
// and a copy-all chip. Nothing leaves the machine — tesseract runs locally.
Item {
  id: root

  // copy requests go through the host, which owns wl-copy and the toast
  signal copyRequested(string text)

  property bool panelActive: false
  property string stage: "paste"    // paste | reading | done
  property string text: ""
  property string error: ""
  // tesseract languages are resolved once from `--list-langs`; Portuguese and
  // English are preferred when installed, otherwise the first text language
  property string lang: ""
  property bool langReady: false
  property string langError: ""
  property bool pendingPaste: false   // Ctrl+V arrived before the lang probe

  readonly property bool big: root.stage === "done"
  readonly property string langLabel: root.lang === "" ? "?" : root.lang
  // one temp file per tab instance (one intelligence dock per monitor); a run
  // is guarded by `stage === "reading"`
  readonly property int tmpTag: Math.floor(Math.random() * 1000000000)
  readonly property string tmpImage: {
    const dir = Quickshell.env("XDG_RUNTIME_DIR");
    return (dir && dir !== "" ? dir : "/tmp")
        + "/quickshell-ocr-" + Quickshell.processId + "-" + root.tmpTag + ".png";
  }

  // The docked panel is its own keyboard surface, separate from the bar's
  // hiddenInput. Once the card/result is clicked the popup owns the key
  // events and there is no text editor here to forward Ctrl+V, so the tab
  // focuses itself while active and catches the paste; keys from a focused
  // child (e.g. the read-only SelText) bubble up to this handler too.
  focus: root.visible && root.panelActive
  Keys.onPressed: event => {
    if (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)) {
      event.accepted = true;
      root.pasteImage();
    }
  }

  function reset() {
    root.stage = "paste";
    root.text = "";
    root.error = "";
  }

  // Ctrl+V / click on the card. The clipboard image is written to a temp file
  // first (argv only — the path is shell $1, never interpolated), then
  // tesseract reads that file and prints the text to stdout.
  function pasteImage() {
    if (root.stage === "reading") return;
    if (!root.langReady) {
      // the probe is normally done long before the tab opens; if it is not,
      // remember the paste and run it as soon as the probe settles
      root.pendingPaste = true;
      root.error = "checking tesseract…";
      if (!langProc.running) {
        langProc.running = true;
        langTimeout.restart();
      }
      return;
    }
    if (root.langError !== "") {
      root.pendingPaste = false;
      root.stage = "paste";
      root.text = "";
      root.error = root.langError;
      return;
    }
    root.pendingPaste = false;
    root.stage = "reading";
    root.text = "";
    root.error = "";
    grabProc.running = true;
  }

  function langSettled() {
    if (!root.pendingPaste) return;
    root.pendingPaste = false;
    // outside the current process callback: start the grab once the language
    // state (and its possible error) is fully committed
    Qt.callLater(() => root.pasteImage());
  }

  function resolveLangs(out) {
    langTimeout.stop();
    const all = out.split("\n").map(s => s.trim())
        .filter(s => s !== "" && s !== "osd" && s.indexOf(" ") === -1);
    const want = [];
    if (all.indexOf("por") !== -1) want.push("por");
    if (all.indexOf("eng") !== -1) want.push("eng");
    root.lang = want.length > 0 ? want.join("+") : (all.length > 0 ? all[0] : "");
    root.langError = root.lang === "" ? "no tesseract language data" : "";
    root.langReady = true;
    root.langSettled();
  }

  // a missing tesseract binary makes Process fail to start without an `exited`
  // signal, so the language probe cannot be the only thing that resolves it
  Timer {
    id: langTimeout
    interval: 2500
    onTriggered: if (!root.langReady) {
      root.langError = "tesseract not available";
      root.langReady = true;
      root.langSettled();
    }
  }

  Component.onCompleted: {
    langProc.running = true;
    langTimeout.restart();
  }

  Process {
    id: langProc
    command: ["tesseract", "--list-langs"]
    stdout: StdioCollector {
      onStreamFinished: root.resolveLangs(text)
    }
    onExited: code => {
      langTimeout.stop();
      if (!root.langReady) {
        root.langError = code === 0 ? "no tesseract language data"
                                    : "tesseract not available";
        root.langReady = true;
        root.langSettled();
      }
    }
  }

  Process {
    id: grabProc
    command: ["sh", "-c",
      'f="$1"; rm -f "$f"; ' +
      'for t in image/png image/jpeg image/webp image/bmp image/tiff image/gif; do ' +
      '  if wl-paste -n -t "$t" >"$f" 2>/dev/null && [ -s "$f" ]; then exit 0; fi; ' +
      'done; rm -f "$f"; exit 1', "ocr", root.tmpImage]
    onExited: code => {
      if (code !== 0) {
        root.stage = "paste";
        root.error = "no image in clipboard";
        return;
      }
      tesseractProc.running = true;
    }
  }

  Process {
    id: tesseractProc
    // stdout and the exit are independent: a StdioCollector can finish after
    // the process exits (it owns the pipe), so the result is only committed
    // once BOTH flags are in. Otherwise a long page flashes "no text found"
    // for a frame before the real text lands.
    property bool exitedOk: false
    property bool outDone: false
    property string raw: ""
    property string err: ""

    command: ["tesseract", root.tmpImage, "stdout", "-l", root.lang, "--psm", "3"]

    stdout: StdioCollector {
      onStreamFinished: {
        tesseractProc.raw = text;
        tesseractProc.outDone = true;
        root.finishOcr();
      }
    }
    stderr: SplitParser {
      onRead: data => tesseractProc.err += data + "\n"
    }
    onStarted: {
      tesseractProc.exitedOk = false;
      tesseractProc.outDone = false;
      tesseractProc.raw = "";
      tesseractProc.err = "";
    }
    onExited: code => {
      Quickshell.execDetached(["rm", "-f", root.tmpImage]);
      if (code !== 0) {
        root.stage = "paste";
        root.text = "";
        const lines = tesseractProc.err.trim().split("\n").filter(l => l !== "");
        root.error = lines.length > 0 ? lines[lines.length - 1] : "tesseract failed";
        return;
      }
      tesseractProc.exitedOk = true;
      root.finishOcr();
    }
  }

  function finishOcr() {
    if (!tesseractProc.exitedOk || !tesseractProc.outDone) return;
    // strip the form feed tesseract puts on the last page and trailing spaces
    root.text = tesseractProc.raw.replace(/\f/g, "")
        .replace(/[ \t]+$/gm, "").replace(/\n{3,}/g, "\n\n").trim();
    root.error = "";
    root.stage = "done";
  }

  Rectangle {
    id: card

    // small while it is a drop target, large once there is text to read
    readonly property bool big: root.big

    x: card.big ? 0 : Math.round((parent.width - card.width) / 2)
    y: card.big ? 0 : Math.round((parent.height - card.height) / 2)
    width: card.big ? parent.width : Math.min(360, parent.width)
    height: card.big ? parent.height : 190
    radius: card.big ? 6 : 8
    color: card.big ? Theme.bg
         : pasteMa.containsMouse && root.stage !== "reading" ? Theme.hover : Theme.surface
    border.width: 1
    border.color: !card.big && root.panelActive ? Theme.muted : Theme.border
    // width/height animate from the centered position; x/y follow the binding
    Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    Behavior on height { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    Behavior on radius { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    Behavior on color { ColorAnimation { duration: 180 } }
    Behavior on border.color { ColorAnimation { duration: 180 } }

    // ----- small: paste / reading card -----
    Item {
      id: pastePane
      anchors.fill: parent
      opacity: card.big ? 0 : 1
      visible: opacity > 0
      Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

      Column {
        anchors.centerIn: parent
        width: Math.min(parent.width - 30, 300)
        spacing: 7

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.stage === "reading" ? "◌" : "\uf03e"   // picture / loader
          font.family: Theme.font
          font.pixelSize: 26
          color: root.stage === "reading" ? Theme.accent : Theme.muted
          SequentialAnimation on opacity {
            running: root.stage === "reading"
            loops: Animation.Infinite
            NumberAnimation { to: 0.3; duration: 600 }
            NumberAnimation { to: 1; duration: 600 }
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.stage === "reading" ? "reading image…" : "paste an image"
          font.family: Theme.font
          font.bold: true
          font.pixelSize: 12
          color: root.stage === "reading" ? Theme.accent : Theme.text
        }

        Text {
          visible: root.stage !== "reading"
          anchors.horizontalCenter: parent.horizontalCenter
          text: "click here or press Ctrl+V"
          font.family: Theme.font
          font.pixelSize: 10
          color: Theme.muted
        }

        Text {
          visible: root.langReady && root.lang !== ""
          anchors.horizontalCenter: parent.horizontalCenter
          text: "tesseract · " + root.langLabel
          font.family: Theme.font
          font.pixelSize: 9
          color: Theme.muted
        }

        Text {
          visible: root.error !== "" || root.langError !== ""
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          text: root.error !== "" ? root.error : root.langError
          font.family: Theme.font
          font.pixelSize: 9
          color: Theme.err
        }
      }

      MouseArea {
        id: pasteMa
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.stage !== "reading" && !card.big
        cursorShape: root.stage === "reading" ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: root.pasteImage()
      }
    }

    // ----- large: recognised text -----
    Item {
      id: resultPane
      anchors.fill: parent
      anchors.margins: 10
      opacity: card.big ? 1 : 0
      visible: opacity > 0
      enabled: card.big
      Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

      Item {
        id: resultHead
        width: parent.width
        height: 22

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "tesseract · " + root.langLabel + " · " + root.text.length + " chars"
          font.family: Theme.font
          font.pixelSize: 9
          color: Theme.muted
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 6

          // back to the small paste card for another image
          Rectangle {
            width: newLabel.implicitWidth + 16
            height: 20
            radius: 5
            color: newMa.containsMouse ? Theme.hover : Theme.surface
            Behavior on color { ColorAnimation { duration: 180 } }

            Text {
              id: newLabel
              anchors.centerIn: parent
              text: "new image"
              font.family: Theme.font
              font.pixelSize: 9
              color: Theme.text
            }

            MouseArea {
              id: newMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.reset()
            }
          }

          // copy everything (selection already auto-copies through SelText)
          Rectangle {
            width: copyLabel.implicitWidth + 16
            height: 20
            radius: 5
            color: copyMa.containsMouse && root.text !== ""
                   ? Theme.hover : Theme.surface
            Behavior on color { ColorAnimation { duration: 180 } }

            Text {
              id: copyLabel
              anchors.centerIn: parent
              text: "copy all"
              font.family: Theme.font
              font.bold: true
              font.pixelSize: 9
              color: root.text !== "" ? Theme.text : Theme.muted
            }

            MouseArea {
              id: copyMa
              anchors.fill: parent
              hoverEnabled: true
              enabled: root.text !== ""
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.text !== "") root.copyRequested(root.text)
            }
          }
        }
      }

      Flickable {
        id: outFlick
        anchors.top: resultHead.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        contentWidth: width
        contentHeight: outText.height
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        SelText {
          id: outText
          width: outFlick.width
          height: contentHeight
          text: root.text
          textFormat: TextEdit.PlainText
          font.pixelSize: 13
          color: Theme.text
          onCopied: root.copyRequested("")
          // a focused read-only TextEdit can swallow Ctrl+V itself; catch it
          // before the editor's paste action so a new image can replace this
          // result even while its text is selected
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: event => {
            if (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)) {
              event.accepted = true;
              root.pasteImage();
            }
          }
        }
      }

      Text {
        visible: root.text === ""
        anchors.centerIn: outFlick
        text: "no text found in image"
        font.family: Theme.font
        font.pixelSize: 11
        color: Theme.muted
      }
    }
  }
}
