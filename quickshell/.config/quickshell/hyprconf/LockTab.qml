import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "Conf.js" as Conf

ColumnLayout {
    id: root

    property var cfg: null
    property string status: ""

    // general
    property bool hideCursor: true
    // background
    property string bgPath: ""
    // label (time)
    property string fontFam: "sans-serif"
    property int fontSize: 80
    property string timeColor: "rgba(ffffffff)"
    property real posX: 10
    property real posY: -10
    property string halign: "left"
    property string valign: "top"
    // input-field
    property real inW: 300
    property real inH: 50
    property real outline: 2
    property real dotsSize: 0.25
    property real dotsSpace: 0.3
    property string outerColor: "rgba(ffffffff)"
    property string innerColor: "rgba(0a0a0aff)"
    property string fontColor: "rgba(ffffffff)"
    property string failColor: "rgb(ff4444)"
    property string capsColor: "rgba(ccccccff)"
    property string failText: "failed"
    property bool hideInput: false
    property real inPosY: 150

    spacing: 10

    function reload() {
        let cfg = Conf.parse(fileView.text());
        if (cfg.items.length === 0) seed(cfg);
        root.cfg = cfg;

        root.hideCursor = Conf.get(cfg, "general", "hide_cursor", "true") === "true";
        root.bgPath = Conf.get(cfg, "background", "path", "");
        root.fontFam = Conf.get(cfg, "label", "font_family", "sans-serif");
        root.fontSize = Conf.toInt(Conf.get(cfg, "label", "font_size", "80"), 80);
        root.timeColor = Conf.get(cfg, "label", "color", "rgba(ffffffff)");
        const lp = Conf.parsePair(Conf.get(cfg, "label", "position", "10, -10"));
        root.posX = lp.ok ? lp.x : 10;
        root.posY = lp.ok ? lp.y : -10;
        root.halign = Conf.get(cfg, "label", "halign", "left");
        root.valign = Conf.get(cfg, "label", "valign", "top");

        const sz = Conf.parsePair(Conf.get(cfg, "input-field", "size", "300, 50"));
        root.inW = sz.ok ? sz.x : 300;
        root.inH = sz.ok ? sz.y : 50;
        root.outline = Conf.toFloat(Conf.get(cfg, "input-field", "outline_thickness", "2"), 2);
        root.dotsSize = Conf.toFloat(Conf.get(cfg, "input-field", "dots_size", "0.25"), 0.25);
        root.dotsSpace = Conf.toFloat(Conf.get(cfg, "input-field", "dots_spacing", "0.3"), 0.3);
        root.outerColor = Conf.get(cfg, "input-field", "outer_color", "rgba(ffffffff)");
        root.innerColor = Conf.get(cfg, "input-field", "inner_color", "rgba(0a0a0aff)");
        root.fontColor = Conf.get(cfg, "input-field", "font_color", "rgba(ffffffff)");
        root.failColor = Conf.get(cfg, "input-field", "fail_color", "rgb(ff4444)");
        root.capsColor = Conf.get(cfg, "input-field", "capslock_color", "rgba(ccccccff)");
        root.failText = Conf.get(cfg, "input-field", "fail_text", "failed");
        root.hideInput = Conf.get(cfg, "input-field", "hide_input", "false") === "true";
        const ip = Conf.parsePair(Conf.get(cfg, "input-field", "position", "0, 150"));
        root.inPosY = ip.ok ? ip.y : 150;

        root.status = "";
    }

    function save() {
        const cfg = root.cfg;
        Conf.set(cfg, "general", "hide_cursor", root.hideCursor ? "true" : "false");
        Conf.set(cfg, "background", "path", root.bgPath);
        Conf.set(cfg, "label", "font_family", root.fontFam);
        Conf.set(cfg, "label", "font_size", Conf.fmtInt(root.fontSize));
        Conf.set(cfg, "label", "color", root.timeColor);
        Conf.set(cfg, "label", "position", Conf.fmtInt(root.posX) + ", " + Conf.fmtInt(root.posY));
        Conf.set(cfg, "label", "halign", root.halign);
        Conf.set(cfg, "label", "valign", root.valign);
        Conf.set(cfg, "input-field", "size", Conf.fmtInt(root.inW) + ", " + Conf.fmtInt(root.inH));
        Conf.set(cfg, "input-field", "outline_thickness", Conf.fmtInt(root.outline));
        Conf.set(cfg, "input-field", "dots_size", Conf.fmtFloat(root.dotsSize));
        Conf.set(cfg, "input-field", "dots_spacing", Conf.fmtFloat(root.dotsSpace));
        Conf.set(cfg, "input-field", "outer_color", root.outerColor);
        Conf.set(cfg, "input-field", "inner_color", root.innerColor);
        Conf.set(cfg, "input-field", "font_color", root.fontColor);
        Conf.set(cfg, "input-field", "fail_color", root.failColor);
        Conf.set(cfg, "input-field", "capslock_color", root.capsColor);
        Conf.set(cfg, "input-field", "fail_text", root.failText);
        Conf.set(cfg, "input-field", "hide_input", root.hideInput ? "true" : "false");
        Conf.set(cfg, "input-field", "position", "0, " + Conf.fmtInt(root.inPosY));

        fileView.setText(Conf.serialize(cfg));
        root.status = "Saved hyprlock.conf — applies on next lock";
    }

    // Minimal starter config for an empty/missing hyprlock.conf.
    function seed(cfg) {
        Conf.set(cfg, "general", "hide_cursor", "true");
        Conf.set(cfg, "background", "monitor", "");
        Conf.set(cfg, "background", "path", "");
        Conf.set(cfg, "label", "text", "$TIME");
        Conf.set(cfg, "label", "font_size", "80");
        Conf.set(cfg, "label", "font_family", "sans-serif");
        Conf.set(cfg, "label", "color", "rgba(ffffffff)");
        Conf.set(cfg, "label", "position", "10, -10");
        Conf.set(cfg, "label", "halign", "left");
        Conf.set(cfg, "label", "valign", "top");
        Conf.set(cfg, "input-field", "size", "300, 50");
        Conf.set(cfg, "input-field", "outline_thickness", "2");
        Conf.set(cfg, "input-field", "dots_size", "0.25");
        Conf.set(cfg, "input-field", "dots_spacing", "0.3");
        Conf.set(cfg, "input-field", "dots_center", "true");
        Conf.set(cfg, "input-field", "outer_color", "rgba(ffffffff)");
        Conf.set(cfg, "input-field", "inner_color", "rgba(0a0a0aff)");
        Conf.set(cfg, "input-field", "font_color", "rgba(ffffffff)");
        Conf.set(cfg, "input-field", "fail_text", "failed");
        Conf.set(cfg, "input-field", "fail_color", "rgb(ff4444)");
        Conf.set(cfg, "input-field", "capslock_color", "rgba(ccccccff)");
        Conf.set(cfg, "input-field", "hide_input", "false");
        Conf.set(cfg, "input-field", "position", "0, 150");
        Conf.set(cfg, "input-field", "halign", "center");
        Conf.set(cfg, "input-field", "valign", "bottom");
    }

    FileView {
        id: fileView
        path: HyprSettings.confDir + "/hyprlock.conf"
        blockAllReads: true
        preload: true
    }

    ScrollView {
        id: scroll
        Layout.fillWidth: true
        Layout.fillHeight: true

        ColumnLayout {
            width: scroll.availableWidth
            spacing: 10

            SectionCard {
                Layout.fillWidth: true
                title: "General"

                Grid {
                    columns: 2
                    columnSpacing: 14
                    rowSpacing: 8

                    Text { text: "Options"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    CheckRow {
                        label: "Hide cursor"
                        checked: root.hideCursor
                        onToggled: c => root.hideCursor = c
                    }
                }
            }

            SectionCard {
                Layout.fillWidth: true
                title: "Background"

                Column {
                    spacing: 8
                    width: parent.width - 4

                    PathRow {
                        path: root.bgPath
                        onPicked: p => root.bgPath = p
                    }
                    PreviewBox {
                        width: parent.width
                        path: root.bgPath
                    }
                }
            }

            SectionCard {
                Layout.fillWidth: true
                title: "Clock label"

                Grid {
                    columns: 2
                    columnSpacing: 14
                    rowSpacing: 8

                    Text { text: "Font family"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    TextEntry {
                        width: 300
                        text: root.fontFam
                        onEditingFinished: root.fontFam = text
                    }

                    Text { text: "Time font size"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    NumField {
                        from: 8
                        to: 300
                        value: root.fontSize
                        onValueEdited: v => root.fontSize = Math.round(v)
                    }

                    Text { text: "Time color"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    TextEntry {
                        width: 200
                        text: root.timeColor
                        onEditingFinished: root.timeColor = text
                    }

                    Text { text: "Position"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    Row {
                        spacing: 10
                        NumField {
                            from: -2000
                            to: 2000
                            value: root.posX
                            onValueEdited: v => root.posX = v
                        }
                        NumField {
                            from: -2000
                            to: 2000
                            value: root.posY
                            onValueEdited: v => root.posY = v
                        }
                    }

                    Text { text: "Horizontal align"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    SegRow {
                        options: ["left", "center", "right"]
                        value: root.halign
                        onPicked: v => root.halign = v
                    }

                    Text { text: "Vertical align"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    SegRow {
                        options: ["top", "center", "bottom"]
                        value: root.valign
                        onPicked: v => root.valign = v
                    }
                }
            }

            SectionCard {
                Layout.fillWidth: true
                title: "Input field"

                Grid {
                    columns: 2
                    columnSpacing: 14
                    rowSpacing: 8

                    Text { text: "Size"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    Row {
                        spacing: 10
                        NumField {
                            from: 20
                            to: 2000
                            step: 5
                            value: root.inW
                            onValueEdited: v => root.inW = v
                        }
                        NumField {
                            from: 10
                            to: 1000
                            step: 5
                            value: root.inH
                            onValueEdited: v => root.inH = v
                        }
                    }

                    Text { text: "Outline thickness"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    NumField {
                        from: 0
                        to: 50
                        value: root.outline
                        onValueEdited: v => root.outline = v
                    }

                    Text { text: "Dots"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    Row {
                        spacing: 10
                        NumField {
                            from: 0.01
                            to: 1
                            step: 0.05
                            decimals: 2
                            value: root.dotsSize
                            onValueEdited: v => root.dotsSize = v
                        }
                        NumField {
                            from: 0
                            to: 1
                            step: 0.05
                            decimals: 2
                            value: root.dotsSpace
                            onValueEdited: v => root.dotsSpace = v
                        }
                    }

                    Text { text: "Outer color"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    TextEntry {
                        width: 200
                        text: root.outerColor
                        onEditingFinished: root.outerColor = text
                    }

                    Text { text: "Inner color"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    TextEntry {
                        width: 200
                        text: root.innerColor
                        onEditingFinished: root.innerColor = text
                    }

                    Text { text: "Font color"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    TextEntry {
                        width: 200
                        text: root.fontColor
                        onEditingFinished: root.fontColor = text
                    }

                    Text { text: "Fail color"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    TextEntry {
                        width: 200
                        text: root.failColor
                        onEditingFinished: root.failColor = text
                    }

                    Text { text: "Caps lock color"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    TextEntry {
                        width: 200
                        text: root.capsColor
                        onEditingFinished: root.capsColor = text
                    }

                    Text { text: "Fail text"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    TextEntry {
                        width: 200
                        text: root.failText
                        onEditingFinished: root.failText = text
                    }

                    Text { text: "Options"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    CheckRow {
                        label: "Hide typed input"
                        checked: root.hideInput
                        onToggled: c => root.hideInput = c
                    }

                    Text { text: "Position Y (from bottom)"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
                    NumField {
                        from: -2000
                        to: 2000
                        step: 10
                        value: root.inPosY
                        onValueEdited: v => root.inPosY = v
                    }
                }
            }
        }
    }

    Row {
        Layout.fillWidth: true
        spacing: 12

        TextButton {
            label: "\uf0c7 save"
            accent: true
            onClicked: root.save()
        }

        Text {
            height: 26
            verticalAlignment: Text.AlignVCenter
            text: root.status
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: 11
            elide: Text.ElideRight
            width: 380
        }
    }
}
