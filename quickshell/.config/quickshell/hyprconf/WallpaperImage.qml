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

    // Decode at the item's display size when the caller did not ask for a
    // specific size. Without this an Image on an untouched `sourceSize` loads
    // the file at NATIVE resolution: the wallpaper card's 300x120 preview of a
    // 3840x2160 GIF cost 33 MB (72 MB for a 5824x3264 PNG), and every preview
    // the shell had ever shown stayed resident. Thumbnails/cards pass an
    // explicit sourceSize and keep it.
    readonly property size effectiveSourceSize: {
        if (root.sourceSize.width > 0 && root.sourceSize.height > 0)
            return root.sourceSize;
        const w = Math.round(root.width);
        const h = Math.round(root.height);
        return Qt.size(w > 0 ? w : 300, h > 0 ? h : 120);
    }

    // file:// URL -> filesystem path
    readonly property string srcPath: {
        const s = String(root.source);
        return s.startsWith("file://") ? decodeURIComponent(s.slice(7)) : s;
    }

    // where extracted first frames are cached (ffmpeg output)
    readonly property string frameDir:
        (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/qs-gifframes"
    property string frameUrl: ""

    // Re-extract whenever the file changes. frameUrl MUST be cleared here:
    // a row that switches from one GIF to another used to keep rendering the
    // previous GIF's frame forever (the old source's cached still).
    function kickExtract() {
        kickTimer.stop();
        root.frameUrl = "";
        extract.running = false;
        if (!root.isGif || root.srcPath === "") return;
        extract.command = ["sh", "-c",
            'mkdir -p "$1"; out="$1/$(printf %s "$2" | md5sum | cut -d" " -f1).png"; ' +
            '[ -s "$out" ] || ffmpeg -y -loglevel error -i "$2" -frames:v 1 "$out" 2>/dev/null; ' +
            '[ -s "$out" ] && printf "%s\\t%s" "$out" "$2"',
            "sh", root.frameDir, root.srcPath];
        // short hop so a previous run has actually stopped first
        kickTimer.restart();
    }

    onSrcPathChanged: kickExtract()
    Component.onCompleted: kickExtract()

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
            sourceSize: root.effectiveSourceSize
        }
    }

    Image {
        id: frameImg
        anchors.fill: parent
        visible: root.isGif
        source: root.isGif ? root.frameUrl : ""
        fillMode: root.fillMode
        asynchronous: root.asynchronous
        sourceSize: root.effectiveSourceSize
    }

    // extract the first frame once per file (cached by path hash)
    Process {
        id: extract
        stdout: StdioCollector {
            onStreamFinished: {
                const t = text.trim();
                if (t === "") return;
                const i = t.lastIndexOf("\t");
                if (i < 0) return;
                // discard output from a run whose source is already stale
                if (t.slice(i + 1) !== root.srcPath) return;
                root.frameUrl = "file://" + t.slice(0, i);
            }
        }
    }

    Timer {
        id: kickTimer
        interval: 16
        onTriggered: extract.running = true
    }
}
