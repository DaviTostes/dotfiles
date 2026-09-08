import QtQuick
import QtQuick.Dialogs
import Quickshell
import Quickshell.Io
import "Conf.js" as Conf

// Path entry + browse button. The typed path is checked for existence
// (debounced via test -f): ok border when valid, error border when not.
Row {
    id: root

    property string path: ""
    signal picked(string p)

    readonly property int validity: {
        const t = entry.text.trim();
        if (t === "") return 0;
        return root.exists ? 1 : 2;
    }

    property bool exists: false

    spacing: 6

    TextEntry {
        id: entry
        width: 300
        text: root.path
        placeholderText: "/path/to/image.png"
        validity: root.validity
        onTextChanged: {
            root.exists = false;
            debounce.restart();
        }
        onEditingFinished: {
            if (text !== root.path) root.picked(text);
            text = Qt.binding(() => root.path);
        }
    }

    Timer {
        id: debounce
        interval: 400
        onTriggered: {
            const p = Conf.expandPath(entry.text.trim(), Quickshell.env("HOME"));
            if (p === "") { root.exists = false; return; }
            checkProc.target = p;
            checkProc.running = true;
        }
    }

    Process {
        id: checkProc
        property string target: ""
        command: ["sh", "-c", '[ -f "$1" ] && echo y || echo n', "sh", checkProc.target]
        stdout: StdioCollector {
            // ignore stale results from a previous check
            onStreamFinished: {
                if (checkProc.target === Conf.expandPath(entry.text.trim(), Quickshell.env("HOME")))
                    root.exists = text.trim() === "y";
            }
        }
    }

    TextButton {
        label: "\uf07c browse"
        tooltip: "Browse…"
        onClicked: {
            // suspend the bar's fullscreen catcher while the dialog is up
            HyprSettings.modalDialogOpen = true;
            dialog.open();
        }
    }

    FileDialog {
        id: dialog
        nameFilters: ["Images (*.png *.jpg *.jpeg *.webp *.bmp *.gif *.avif)", "All files (*)"]
        currentFolder: "file://" + Quickshell.env("HOME") + "/Pictures"
        onAccepted: {
            HyprSettings.modalDialogOpen = false;
            const p = Conf.urlToPath(selectedFile);
            // remember the folder for the next browse
            dialog.currentFolder = "file://" + p.substring(0, p.lastIndexOf("/"));
            root.picked(Conf.homeRel(p, Quickshell.env("HOME")));
        }
        onRejected: HyprSettings.modalDialogOpen = false
    }
}
