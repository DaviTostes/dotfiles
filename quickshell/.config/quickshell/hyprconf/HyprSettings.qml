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

    // Directory the wallpaper gallery starts in (kept for the session).
    property string wallpaperDir: Quickshell.env("HOME") + "/.config/backgrounds"

    // Wallpaper gallery popup state — host is the panel instance that
    // opened it (per monitor); galleryTab is 0 (hyprpaper rows) or
    // 1 (hyprlock background); galleryRow indexes that tab's target.
    property bool galleryOpen: false
    property var galleryHost: null
    property int galleryTab: 0
    property int galleryRow: -1
    property string galleryPicked: ""
}
