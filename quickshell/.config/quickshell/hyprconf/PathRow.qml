import QtQuick
import QtQuick.Dialogs
import Quickshell
import "Conf.js" as Conf

// Path entry + browse button.
Row {
    id: root

    property string path: ""
    signal picked(string p)

    spacing: 6

    TextEntry {
        width: 300
        text: root.path
        placeholderText: "/path/to/image.png"
        onEditingFinished: if (text !== root.path) root.picked(text)
    }

    TextButton {
        label: "\uf07c browse"
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
