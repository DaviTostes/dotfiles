import QtQuick

// Status line for the tab footers: message that fades out a few seconds
// after it is set, plus an optional spinner kept on screen while a
// background process (hyprpaper / hypridle restart) is running.
Row {
    id: root

    property string text: ""
    property bool busy: false
    property int labelWidth: 220

    // spinner keeps spinning for a minimum hold after busy goes false,
    // so a fast-exiting process still shows a visible pulse
    property bool spinShown: false

    spacing: 6
    height: 26

    onBusyChanged: {
        if (busy) {
            spinTimer.stop();
            root.spinShown = true;
        } else if (spinShown) {
            spinTimer.restart();
        }
    }

    onTextChanged: {
        label.opacity = 1;
        if (text !== "") fadeTimer.restart();
        else fadeTimer.stop();
    }

    Timer { id: spinTimer; interval: 1200; onTriggered: root.spinShown = false }
    Timer { id: fadeTimer; interval: 3000; onTriggered: label.opacity = 0 }

    Text {
        id: spin
        visible: root.spinShown
        anchors.verticalCenter: parent.verticalCenter
        text: "\uf110"
        color: Theme.muted
        font.family: Theme.font
        font.pixelSize: 11

        RotationAnimation on rotation {
            loops: Animation.Infinite
            from: 0
            to: 360
            duration: 1200
        }
    }

    Text {
        id: label
        width: root.labelWidth
        height: 26
        verticalAlignment: Text.AlignVCenter
        text: root.text
        color: Theme.muted
        font.family: Theme.font
        font.pixelSize: 11
        elide: Text.ElideRight
        Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
    }
}
