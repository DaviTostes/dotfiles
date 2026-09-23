import QtQuick

// Renders a wallpaper file, playing it when it is an animated GIF so live
// wallpapers are actually live in the panel. GIFs go through AnimatedImage;
// everything else keeps the lighter Image path.
Item {
    id: root

    property url source: ""
    property int fillMode: Image.PreserveAspectCrop
    property bool asynchronous: true
    property size sourceSize: Qt.size(0, 0)

    // GIFs only advance while this is true. Callers gate it on the panel /
    // gallery being open so nothing animates off-screen.
    property bool animate: true

    readonly property bool isGif:
        /\.gif$/i.test(String(root.source).split("?")[0].split("#")[0])

    // mirror Image.status so callers can fade in once the frame is ready
    readonly property int status: loader.item ? loader.item.status : Image.Null

    Loader {
        id: loader
        anchors.fill: parent
        sourceComponent: root.isGif ? gifComponent : stillComponent
    }

    Component {
        id: stillComponent
        Image {
            anchors.fill: parent
            source: root.source
            fillMode: root.fillMode
            asynchronous: root.asynchronous
            sourceSize: root.sourceSize
        }
    }

    Component {
        id: gifComponent
        AnimatedImage {
            anchors.fill: parent
            source: root.source
            fillMode: root.fillMode
            asynchronous: root.asynchronous
            sourceSize: root.sourceSize
            playing: root.animate
            // do not hold every decoded frame in the shared pixmap cache
            cache: false
        }
    }
}
