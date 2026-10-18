import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root

    property bool dirty: false
    property bool silent: false

    property string kbLayout: "us"
    property string kbVariant: ""
    property string kbModel: ""
    property string kbOptions: ""
    property string kbRules: ""
    property int followMouse: 1
    property real sensitivity: 0
    property bool naturalScroll: false

    spacing: 10

    function markDirty() {
        if (!root.silent) root.dirty = true;
    }

    function loadFrom(model) {
        root.silent = true;
        const inp = model.input;
        root.kbLayout = inp.kb_layout;
        root.kbVariant = inp.kb_variant;
        root.kbModel = inp.kb_model;
        root.kbOptions = inp.kb_options;
        root.kbRules = inp.kb_rules;
        root.followMouse = inp.follow_mouse;
        root.sensitivity = inp.sensitivity;
        root.naturalScroll = inp.natural_scroll;
        root.dirty = false;
        root.silent = false;
    }

    function writeTo(model) {
        model.input.kb_layout = root.kbLayout;
        model.input.kb_variant = root.kbVariant;
        model.input.kb_model = root.kbModel;
        model.input.kb_options = root.kbOptions;
        model.input.kb_rules = root.kbRules;
        model.input.follow_mouse = Math.round(root.followMouse);
        model.input.sensitivity = root.sensitivity;
        model.input.natural_scroll = root.naturalScroll;
    }

    SectionCard {
        Layout.fillWidth: true
        title: "Input"

        Grid {
            columns: 2
            columnSpacing: 14
            rowSpacing: 8

            Text { text: "Keyboard layout"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            TextEntry {
                width: 160
                text: root.kbLayout
                placeholderText: "us"
                onEditingFinished: if (text !== root.kbLayout) { root.kbLayout = text; root.markDirty(); }
            }

            Text { text: "Keyboard variant"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            TextEntry {
                width: 160
                text: root.kbVariant
                placeholderText: "(none)"
                onEditingFinished: if (text !== root.kbVariant) { root.kbVariant = text; root.markDirty(); }
            }

            Text { text: "Follow mouse"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            SegRow {
                options: ["0", "1", "2", "3"]
                value: String(root.followMouse)
                onPicked: v => { root.followMouse = parseInt(v, 10); root.markDirty(); }
            }

            Text { text: "Mouse sensitivity"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            NumField {
                from: -1
                to: 1
                step: 0.1
                decimals: 2
                value: root.sensitivity
                onValueEdited: v => { root.sensitivity = v; root.markDirty(); }
            }

            Text { text: "Touchpad"; color: Theme.muted; font.family: Theme.font; font.pixelSize: 12 }
            CheckRow {
                label: "Natural scroll"
                checked: root.naturalScroll
                onToggled: c => { root.naturalScroll = c; root.markDirty(); }
            }
        }
    }
}
