import QtQuick
import Quickshell
import Quickshell.Io

// Renders a wallpaper file. GIFs are shown as a STILL first frame extracted
// with ffmpeg: quickshell 0.3.2 + Qt 6.12 crashes (stack overflow) inside
// AnimatedImage / the gif image plugin, so we avoid that path entirely. The
// real wallpaper still animates on the desktop via awww. Non-GIFs use Image.
Item {
    id: root

    property url source: ""
    property int fillMode: Image.PreserveAspectCrop
    property bool asynchronous: true
    property size sourceSize: Qt.size(0, 0)

    // kept for API compatibility (GIFs are static here now)
    property bool animate: true

    readonly property bool isGif:
        /\.gif$/i.test(String(root.source).split("?")[0].split("#")[0])

    // file:// URL -> filesystem path
    readonly property string srcPath: {
        const s = String(root.source);
        return s.startsWith("file://") ? decodeURIComponent(s.slice(7)) : s;
    }

    // where extracted first frames are cached (ffmpeg output)
    readonly property string frameDir:
        (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/qs-gifframes"
    property string frameUrl: ""

    // mirror Image.status so callers can fade in once the frame is ready
    readonly property int status: root.isGif
        ? frameImg.status
        : (loader.item ? loader.item.status : Image.Null)

    Loader {
        id: loader
        anchors.fill: parent
        active: !root.isGif
        sourceComponent: Image {
            anchors.fill: parent
            source: root.source
            fillMode: root.fillMode
            asynchronous: root.asynchronous
            sourceSize: root.sourceSize
        }
    }

    Image {
        id: frameImg
        anchors.fill: parent
        visible: root.isGif
        source: root.isGif ? root.frameUrl : ""
        fillMode: root.fillMode
        asynchronous: root.asynchronous
        sourceSize: root.sourceSize
    }

    // extract the first frame once per file (cached by path hash)
    Process {
        id: extract
        running: root.isGif && root.srcPath !== "" && root.frameUrl === ""
        command: ["sh", "-c",
            'mkdir -p "$1"; out="$1/$(printf %s "$2" | md5sum | cut -d" " -f1).png"; ' +
            '[ -s "$out" ] || ffmpeg -y -loglevel error -i "$2" -frames:v 1 "$out" 2>/dev/null; ' +
            '[ -s "$out" ] && printf %s "$out"',
            "sh", root.frameDir, root.srcPath]
        stdout: StdioCollector {
            onStreamFinished: {
                const t = text.trim();
                if (t !== "") root.frameUrl = "file://" + t;
            }
        }
    }
}
