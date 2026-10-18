pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick
import "HyprPanel.js" as HyprPanel

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
    // opened it (per monitor); galleryTab is 0 (wallpaper rows) or
    // 1 (hyprlock background); galleryRow indexes that tab's target.
    property bool galleryOpen: false
    property var galleryHost: null
    property int galleryTab: 0
    property int galleryRow: -1
    property string galleryPicked: ""

    // ---- compositor window chrome --------------------------------------
    // Read straight from hyprpanel.lua (the panel-owned source of truth) so
    // shell surfaces that Hyprland manages as REAL toplevels — the standalone
    // full opencode chat — can match the compositor's own window rounding and
    // border instead of hardcoding a corner. A mismatched radius makes the
    // client's rounded surface pull away from the inside of Hyprland's border,
    // leaving a transparent gap at the corners that shows the wallpaper
    // through. Re-read whenever the file changes on disk (the panel writes it
    // and reloads Hyprland), so an edit in the panel is picked up live.
    readonly property var compositorChrome: {
        const m = HyprPanel.parse(panelFile.text());
        return m !== null ? m : HyprPanel.defaultModel();
    }
    readonly property int hyprRounding: compositorChrome.decoration.rounding
    readonly property int hyprBorderSize: compositorChrome.general.border_size
    // Corner radius a client surface should use to sit flush against the
    // inside of Hyprland's border: the outer rounding minus the border
    // thickness (the border is drawn in that inset ring, so the concentric
    // inner radius is rounding - border_size).
    readonly property int hyprWindowRadius: Math.max(0, hyprRounding - hyprBorderSize)

    // QtObject has no default property, so the FileView is held on an
    // explicit property instead of being a bare child.
    property FileView panelFile: FileView {
        path: confDir + "/hyprpanel.lua"
        blockAllReads: true
        preload: true
        watchChanges: true
        onFileChanged: reload()
    }
}
