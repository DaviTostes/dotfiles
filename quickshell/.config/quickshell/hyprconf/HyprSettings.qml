pragma Singleton
import Quickshell
import QtQuick

// Shared state for the hypr config panel.
QtObject {
    // Where the hypr* configs live.
    readonly property string confDir: {
        const e = Quickshell.env("HYPR_CONFIG_DIR");
        if (e && e !== "") return e;
        return Quickshell.env("HOME") + "/.config/hypr";
    }

    // True while a native file dialog is open. The bar's fullscreen
    // catcher sits on the overlay layer above the dialog, so it must be
    // suspended or every click in the dialog closes the panel instead.
    property bool modalDialogOpen: false
}
