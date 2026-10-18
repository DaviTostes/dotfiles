import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root

    property bool dirty: false
    property bool silent: false

    // general
    property int gapsIn: 2
    property int gapsOut: 2
    property int borderSize: 2
    property string activeBorder: "rgba(60,60,60,1)"
    property string inactiveBorder: "rgba(32,32,32,1)"
    property bool resizeOnBorder: false
    property bool allowTearing: false
    property string layoutName: "dwindle"

    // decoration
    property int rounding: 8
    property real roundingPower: 2
    property real activeOpacity: 1.0
    property real inactiveOpacity: 1.0

    // shadow
    property bool shadowEnabled: true
    property int shadowRange: 4
    property int shadowRenderPower: 3
    property string shadowColor: "0xee1a1a1a"

    // blur
    property bool blurEnabled: true
    property int blurSize: 3
    property int blurPasses: 1
    property real blurVibrancy: 0.1696

    // animations master toggle
    property bool animationsEnabled: true

    spacing: 10

    function markDirty() {
        if (!root.silent) root.dirty = true;
    }

    function loadFrom(model) {
        root.silent = true;
        const g = model.general;
        const d = model.decoration;
        root.gapsIn = g.gaps_in;
        root.gapsOut = g.gaps_out;
        root.borderSize = g.border_size;
        root.activeBorder = g.active_border;
        root.inactiveBorder = g.inactive_border;
        root.resizeOnBorder = g.resize_on_border;
        root.allowTearing = g.allow_tearing;
        root.layoutName = g.layout;

        root.rounding = d.rounding;
        root.roundingPower = d.rounding_power;
        root.activeOpacity = d.active_opacity;
        root.inactiveOpacity = d.inactive_opacity;

        root.shadowEnabled = d.shadow.enabled;
        root.shadowRange = d.shadow.range;
        root.shadowRenderPower = d.shadow.render_power;
        root.shadowColor = d.shadow.color;

        root.blurEnabled = d.blur.enabled;
        root.blurSize = d.blur.size;
        root.blurPasses = d.blur.passes;
        root.blurVibrancy = d.blur.vibrancy;

        root.animationsEnabled = model.animationsEnabled;
        root.dirty = false;
        root.silent = false;
    }

    function writeTo(model) {
        model.general.gaps_in = Math.round(root.gapsIn);
        model.general.gaps_out = Math.round(root.gapsOut);
        model.general.border_size = Math.round(root.borderSize);
        model.general.active_border = root.activeBorder;
        model.general.inactive_border = root.inactiveBorder;
        model.general.resize_on_border = root.resizeOnBorder;
        model.general.allow_tearing = root.allowTearing;
        model.general.layout = root.layoutName;

        model.decoration.rounding = Math.round(root.rounding);
        model.decoration.rounding_power = root.roundingPower;
        model.decoration.active_opacity = root.activeOpacity;
        model.decoration.inactive_opacity = root.inactiveOpacity;

        model.decoration.shadow.enabled = root.shadowEnabled;
        model.decoration.shadow.range = Math.round(root.shadowRange);
        model.decoration.shadow.render_power = Math.round(root.shadowRenderPower);
        model.decoration.shadow.color = root.shadowColor;

        model.decoration.blur.enabled = root.blurEnabled;
        model.decoration.blur.size = Math.round(root.blurSize);
        model.decoration.blur.passes = Math.round(root.blurPasses);
        model.decoration.blur.vibrancy = root.blurVibrancy;

        model.animationsEnabled = root.animationsEnabled;
    }

    SectionCard {
        Layout.fillWidth: true
        title: "Look & Feel — General"

        Grid {
            columns: 2
            columnSpacing: 14
            rowSpacing: 8

            Text { text: "Gaps (in / out)"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            Row {
                spacing: 10
                NumField {
                    from: 0
                    to: 100
                    value: root.gapsIn
                    onValueEdited: v => { root.gapsIn = Math.round(v); root.markDirty(); }
                }
                NumField {
                    from: 0
                    to: 100
                    value: root.gapsOut
                    onValueEdited: v => { root.gapsOut = Math.round(v); root.markDirty(); }
                }
            }

            Text { text: "Border size"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            NumField {
                from: 0
                to: 20
                value: root.borderSize
                onValueEdited: v => { root.borderSize = Math.round(v); root.markDirty(); }
            }

            Text { text: "Active border"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            TextEntry {
                width: 240
                text: root.activeBorder
                onEditingFinished: if (text !== root.activeBorder) { root.activeBorder = text; root.markDirty(); }
            }

            Text { text: "Inactive border"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            TextEntry {
                width: 240
                text: root.inactiveBorder
                onEditingFinished: if (text !== root.inactiveBorder) { root.inactiveBorder = text; root.markDirty(); }
            }

            Text { text: "Layout"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            SegRow {
                options: ["dwindle", "master"]
                value: root.layoutName
                onPicked: v => { root.layoutName = v; root.markDirty(); }
            }

            Text { text: "Options"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            Row {
                spacing: 14
                CheckRow {
                    label: "Resize on border"
                    checked: root.resizeOnBorder
                    onToggled: c => { root.resizeOnBorder = c; root.markDirty(); }
                }
                CheckRow {
                    label: "Allow tearing"
                    checked: root.allowTearing
                    onToggled: c => { root.allowTearing = c; root.markDirty(); }
                }
            }
        }
    }

    SectionCard {
        Layout.fillWidth: true
        title: "Look & Feel — Decoration"

        Grid {
            columns: 2
            columnSpacing: 14
            rowSpacing: 8

            Text { text: "Rounding (radius / power)"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            Row {
                spacing: 10
                NumField {
                    from: 0
                    to: 50
                    value: root.rounding
                    onValueEdited: v => { root.rounding = Math.round(v); root.markDirty(); }
                }
                NumField {
                    from: 1
                    to: 10
                    step: 0.5
                    decimals: 1
                    value: root.roundingPower
                    onValueEdited: v => { root.roundingPower = v; root.markDirty(); }
                }
            }

            Text { text: "Opacity (active / inactive)"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            Row {
                spacing: 10
                NumField {
                    from: 0.1
                    to: 1.0
                    step: 0.05
                    decimals: 2
                    value: root.activeOpacity
                    onValueEdited: v => { root.activeOpacity = v; root.markDirty(); }
                }
                NumField {
                    from: 0.1
                    to: 1.0
                    step: 0.05
                    decimals: 2
                    value: root.inactiveOpacity
                    onValueEdited: v => { root.inactiveOpacity = v; root.markDirty(); }
                }
            }

            Text { text: "Shadow"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            CheckRow {
                label: "Enable drop shadow"
                checked: root.shadowEnabled
                onToggled: c => { root.shadowEnabled = c; root.markDirty(); }
            }

            Text { text: "Shadow (range / power)"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            Row {
                spacing: 10
                NumField {
                    from: 0
                    to: 100
                    value: root.shadowRange
                    onValueEdited: v => { root.shadowRange = Math.round(v); root.markDirty(); }
                }
                NumField {
                    from: 1
                    to: 4
                    value: root.shadowRenderPower
                    onValueEdited: v => { root.shadowRenderPower = Math.round(v); root.markDirty(); }
                }
            }

            Text { text: "Shadow color"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            TextEntry {
                width: 200
                text: root.shadowColor
                onEditingFinished: if (text !== root.shadowColor) { root.shadowColor = text; root.markDirty(); }
            }

            Text { text: "Blur"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            CheckRow {
                label: "Enable background blur"
                checked: root.blurEnabled
                onToggled: c => { root.blurEnabled = c; root.markDirty(); }
            }

            Text { text: "Blur (size / passes)"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            Row {
                spacing: 10
                NumField {
                    from: 1
                    to: 30
                    value: root.blurSize
                    onValueEdited: v => { root.blurSize = Math.round(v); root.markDirty(); }
                }
                NumField {
                    from: 1
                    to: 10
                    value: root.blurPasses
                    onValueEdited: v => { root.blurPasses = Math.round(v); root.markDirty(); }
                }
            }

            Text { text: "Blur vibrancy"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            NumField {
                from: 0
                to: 1
                step: 0.05
                decimals: 4
                value: root.blurVibrancy
                onValueEdited: v => { root.blurVibrancy = v; root.markDirty(); }
            }

            Text { text: "Animations"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            CheckRow {
                label: "Enable global animations"
                checked: root.animationsEnabled
                onToggled: c => { root.animationsEnabled = c; root.markDirty(); }
            }
        }
    }
}
