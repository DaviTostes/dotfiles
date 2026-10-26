pragma Singleton
import Quickshell
import Quickshell.Io
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
    // opened it (per monitor); galleryRow is the pick target (>= 0 is a
    // wallpaper row, -1 = every monitor + lock screen, -2 = lock screen).
    property bool galleryOpen: false
    property var galleryHost: null
    property int galleryRow: -1
    property string galleryPicked: ""

    // ---- compositor window chrome --------------------------------------
    // Read straight from hyprland.lua (the single compositor config) so shell
    // surfaces that Hyprland manages as REAL toplevels — the standalone full
    // opencode chat — can match the compositor's own window rounding and
    // border instead of hardcoding a corner. A mismatched radius makes the
    // client's rounded surface pull away from the inside of Hyprland's border,
    // leaving a transparent gap at the corners that shows the wallpaper
    // through. Re-read whenever the file changes on disk (watchChanges), so a
    // hand edit + `hyprctl reload` is picked up live.
    readonly property string compositorLua: mainFile.text()
    readonly property int hyprRounding: {
        const m = /decoration\s*=\s*\{[\s\S]*?\brounding\s*=\s*(-?\d+)/.exec(compositorLua);
        return m ? Number(m[1]) : 8;
    }
    readonly property int hyprBorderSize: {
        const m = /general\s*=\s*\{[\s\S]*?\bborder_size\s*=\s*(-?\d+)/.exec(compositorLua);
        return m ? Number(m[1]) : 2;
    }
    // Corner radius a client surface should use to sit flush against the
    // inside of Hyprland's border: the outer rounding minus the border
    // thickness (the border is drawn in that inset ring, so the concentric
    // inner radius is rounding - border_size).
    readonly property int hyprWindowRadius: Math.max(0, hyprRounding - hyprBorderSize)

    // QtObject has no default property, so the FileView is held on an
    // explicit property instead of being a bare child.
    property FileView mainFile: FileView {
        path: confDir + "/hyprland.lua"
        blockAllReads: true
        preload: true
        watchChanges: true
        onFileChanged: reload()
    }
}
