import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls.Basic
import "../hyprconf"

// Tasks pill: opens a Pomodoro-style dropdown with a small todo list.
//
// Two tabs — pending and done. A task carries a name, an optional description
// and an optional prefix (same prefix → same color, customizable per prefix
// from the editor). Clicking a row opens the editor sub-panel below the list;
// the "+" icon in the header opens it blank for a new task. Tasks are
// reordered with the row's up/down buttons, checked off and deleted from the
// row. The list is persisted per shell in Quickshell.stateDir/tasks.json
// (same store trick as the launcher's usage).
//
// Keyboard: the visible fields live in the PopupWindow, which cannot hold
// the compositor keyboard on its own — the BAR does while a panel is open
// (Bar.qml focusable ← tasksPanelOpen), exactly like the settings dropdown's
// TextEntry fields.
Pill {
  id: root

  property bool panelOpen: false
  property int tab: 0               // 0 = pending, 1 = done

  // editor sub-panel, opened below the list: editingId "" = new task,
  // otherwise the id of the task being edited
  property bool editorOpen: false
  property string editingId: ""
  // prefix color picked in the editor ("" = auto, i.e. the hashed default)
  property string editingColor: ""

  // per-prefix color overrides: lowercased prefix → "#rrggbb". Persisted
  // separately so a prefix keeps its color across restarts.
  property var prefixColors: ({})

  // stored tasks: { id, name, desc, prefix, done, created, doneAt }. Always
  // replaced wholesale on mutation (never edited in place) so the filtered
  // bindings below re-evaluate.
  property var tasks: []

  readonly property var pendingTasks: root.tasks.filter(t => !t.done)
  readonly property var doneTasks: root.tasks.filter(t => t.done)
  readonly property var shown: root.tab === 0 ? root.pendingTasks : root.doneTasks

  readonly property string storePath: Quickshell.stateDir + "/tasks.json"
  readonly property string prefixColorsPath: Quickshell.stateDir + "/tasks-prefix-colors.json"
  readonly property int rowHeight: 42

  // ---------- pill ----------
  implicitWidth: label.implicitWidth + 14

  Text {
    id: label
    anchors.centerIn: parent
    font.family: Theme.font
    font.pixelSize: 13
    color: root.panelOpen ? Theme.accent : Theme.text
    Behavior on color { ColorAnimation { duration: 200 } }
    text: root.pendingTasks.length > 0
        ? "\uf0ae " + root.pendingTasks.length : "\uf0ae"
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.panelOpen = !root.panelOpen
  }

  // ---------- persistence ----------
  // stateDir is created by quickshell; printErrors off so the (expected)
  // "file does not exist" warning on first run stays quiet. FileView caches
  // the text, so a hand-edit only takes effect after a config reload.
  // prefix color overrides (see prefixColors above)
  FileView {
    id: tasksFile
    path: root.storePath
    blockAllReads: true
    preload: true
    printErrors: false
    watchChanges: false
  }

  FileView {
    id: prefixColorsFile
    path: root.prefixColorsPath
    blockAllReads: true
    preload: true
    printErrors: false
    watchChanges: false
  }

  function loadTasks() {
    root.tasks = [];

    const raw = tasksFile.text();
    if (!raw) return;

    let parsed = null;
    try { parsed = JSON.parse(raw); } catch (e) { return; }
    if (!Array.isArray(parsed)) return;

    const out = [];
    for (let i = 0; i < parsed.length; i++) {
      const t = parsed[i];
      if (!t || typeof t.name !== "string") continue;
      out.push({
        id: String(t.id !== undefined ? t.id : Date.now() + "-" + i),
        name: t.name,
        desc: typeof t.desc === "string" ? t.desc : "",
        prefix: typeof t.prefix === "string" ? t.prefix : "",
        done: !!t.done,
        created: typeof t.created === "number" ? t.created : 0,
        doneAt: typeof t.doneAt === "number" ? t.doneAt : 0
      });
    }
    root.tasks = out;
  }

  function saveTasks() { tasksFile.setText(JSON.stringify(root.tasks)); }

  function loadPrefixColors() {
    root.prefixColors = {};

    const raw = prefixColorsFile.text();
    if (!raw) return;

    let parsed = null;
    try { parsed = JSON.parse(raw); } catch (e) { return; }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return;

    const out = {};
    for (const k in parsed) {
      if (typeof parsed[k] === "string" && /^#[0-9a-fA-F]{6}$/.test(parsed[k]))
        out[k.toLowerCase()] = parsed[k];
    }
    root.prefixColors = out;
  }

  function savePrefixColors() { prefixColorsFile.setText(JSON.stringify(root.prefixColors)); }

  // set a custom color for a prefix; falsy color removes the override (auto)
  function setPrefixColor(prefix, color) {
    const key = (prefix || "").toLowerCase();
    if (key === "") return;
    const next = Object.assign({}, root.prefixColors);
    if (color) next[key] = color;
    else delete next[key];
    root.prefixColors = next;
    root.savePrefixColors();
  }

  // open the editor sub-panel; pass a task to edit it, or null to create one
  function openEditor(task) {
    root.editingId = task ? task.id : "";
    nameField.text = task ? task.name : "";
    descField.text = task ? task.desc : "";
    prefixField.text = task ? task.prefix : "";
    root.editingColor = (task && task.prefix)
        ? (root.prefixColors[task.prefix.toLowerCase()] || "") : "";
    root.editorOpen = true;
  }

  function newTask() { root.openEditor(null); }

  function editTask(id) {
    const t = root.tasks.find(x => x.id === id);
    if (t) root.openEditor(t);
  }

  function closeEditor() {
    root.editorOpen = false;
    root.editingId = "";
  }

  function saveEditor() {
    const name = nameField.text.trim();
    if (name === "") return;
    const desc = descField.text.trim();
    const prefix = prefixField.text.trim();

    if (root.editingId === "") {
      const now = Date.now();
      const t = {
        id: now + "-" + Math.floor(Math.random() * 1e6),
        name: name,
        desc: desc,
        prefix: prefix,
        done: false,
        created: now,
        doneAt: 0
      };
      root.tasks = [t].concat(root.tasks);   // newest first
      root.tab = 0;                          // reveal the new (pending) task
    } else {
      root.tasks = root.tasks.map(t => t.id === root.editingId
          ? Object.assign({}, t, { name: name, desc: desc, prefix: prefix })
          : t);
    }

    root.saveTasks();
    if (prefix !== "") root.setPrefixColor(prefix, root.editingColor);
    root.closeEditor();
  }

  function toggleTask(id) {
    root.tasks = root.tasks.map(t => t.id === id
        ? Object.assign({}, t, { done: !t.done, doneAt: !t.done ? Date.now() : 0 })
        : t);
    root.saveTasks();
  }

  function removeTask(id) {
    root.tasks = root.tasks.filter(t => t.id !== id);
    root.saveTasks();
  }

  // reorder within the visible tab: swap with the neighbour at index+delta.
  // The store mixes pending/done, but both views are filters, so rebuilding
  // as (reordered current group) + (other group untouched) keeps every view
  // consistent.
  function moveTask(id, delta) {
    const cur = root.shown.slice();
    const i = cur.findIndex(t => t.id === id);
    const j = i + delta;
    if (i < 0 || j < 0 || j >= cur.length) return;

    const tmp = cur[i]; cur[i] = cur[j]; cur[j] = tmp;

    const inGroup = {};
    for (let k = 0; k < cur.length; k++) inGroup[cur[k].id] = true;
    const other = root.tasks.filter(t => !inGroup[t.id]);

    root.tasks = cur.concat(other);
    root.saveTasks();
  }

  // Prefix → color: a custom override wins; otherwise the same prefix always
  // hashes to the same swatch (case-insensitive) across restarts. Empty
  // prefix → no tag color.
  function tagColor(prefix) {
    const p = (prefix || "").toLowerCase();
    if (p === "") return Theme.accent2;
    if (root.prefixColors[p]) return root.prefixColors[p];

    let h = 0;
    for (let i = 0; i < p.length; i++) h = (h * 31 + p.charCodeAt(i)) >>> 0;
    return Theme.tagColors[h % Theme.tagColors.length];
  }

  Component.onCompleted: {
    root.loadTasks();
    root.loadPrefixColors();
  }

  // ---------- open / close ----------
  onPanelOpenChanged: {
    root.closeEditor();
    if (root.panelOpen) {
      hideAnim.stop();
      root.tab = 0;
    } else {
      hideAnim.restart();
    }
  }

  // the popup maps a beat after the state flips; re-assert the editor focus
  onEditorOpenChanged: {
    if (root.editorOpen) {
      Qt.callLater(() => nameField.forceActiveFocus());
      focusTimer.restart();
    }
  }

  Timer {
    id: focusTimer
    interval: 160
    onTriggered: if (root.editorOpen) nameField.forceActiveFocus()
  }

  // click-outside catcher (Pomodoro-style: full-screen, release-shielded)
  Catcher {
    active: root.panelOpen
    onClicked: root.panelOpen = false
  }

  // Escape closes the panel. Application scope: layer surfaces do not map
  // onto Qt's "active window", so a window-scoped Shortcut would be silent.
  // Enabled only while open, so it never collides with the launcher's or the
  // chat panel's Escape shortcuts (two enabled ones are treated as ambiguous).
  Shortcut {
    sequence: "Escape"
    context: Qt.ApplicationShortcut
    enabled: root.panelOpen
    onActivated: {
      // first Esc backs out of the editor, a second closes the panel
      if (root.editorOpen) root.closeEditor();
      else root.panelOpen = false;
    }
  }

  // ---------- dropdown panel ----------
  PopupWindow {
    id: panel

    // stays mapped briefly while closing so the fade can play
    visible: root.panelOpen || hideAnim.running
    color: "transparent"

    Timer { id: hideAnim; interval: 220 }

    implicitWidth: 340
    implicitHeight: body.implicitHeight + 24
    onVisibleChanged: if (visible) anchor.updateAnchor()
    onImplicitHeightChanged: if (visible) anchor.updateAnchor()

    anchor {
      window: root.QsWindow.window
      edges: Edges.Top
      gravity: Edges.Bottom
      onAnchoring: {
        // pill coords are relative to the bar window; hang the popup below
        // the pill, right-aligned with its right edge
        const p = root.mapToItem(null, 0, 0);
        anchor.rect.x = p.x + root.width - panel.implicitWidth;
        anchor.rect.y = p.y + root.height + 6;
        anchor.rect.width = panel.implicitWidth;
        anchor.rect.height = 1;
      }
    }

    Rectangle {
      anchors.fill: parent
      color: Theme.bg
      radius: 6
      border.color: Theme.border
      border.width: 1
    }

    Column {
      id: body

      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: 12
      spacing: 10

      opacity: root.panelOpen ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

      transform: Translate {
        y: root.panelOpen ? 0 : -8
        Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      }

      // ----- header: tabs + add icon (top right) -----
      Item {
        width: parent.width
        height: 26

        Row {
          id: tabsRow
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: 6

          Repeater {
            model: [
              { label: "pending", idx: 0 },
              { label: "done", idx: 1 }
            ]

            delegate: Rectangle {
              id: tabBtn

              required property var modelData
              readonly property bool sel: root.tab === tabBtn.modelData.idx
              readonly property int count: tabBtn.modelData.idx === 0
                  ? root.pendingTasks.length : root.doneTasks.length

              width: tabText.implicitWidth + 20
              height: 26
              radius: 6
              color: tabBtn.sel ? Theme.accent
                   : tabMa.containsMouse ? Theme.hover : Theme.surface
              Behavior on color { ColorAnimation { duration: 200 } }
              scale: tabMa.containsMouse ? 1.04 : 1
              Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

              Text {
                id: tabText
                anchors.centerIn: parent
                font.family: Theme.font
                font.pixelSize: 11
                font.bold: tabBtn.sel
                color: tabBtn.sel ? Theme.deep : Theme.text
                Behavior on color { ColorAnimation { duration: 200 } }
                text: tabBtn.modelData.label + "  " + tabBtn.count
              }

              MouseArea {
                id: tabMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.tab = tabBtn.modelData.idx
              }
            }
          }
        }

        // add icon only (opens the blank editor below)
        Rectangle {
          id: addBtn
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: 26; height: 26; radius: 6
          color: addMa.containsMouse ? Theme.hover : Theme.surface
          Behavior on color { ColorAnimation { duration: 200 } }

          Text {
            anchors.centerIn: parent
            font.family: Theme.font
            font.pixelSize: 12
            color: addMa.containsMouse ? Theme.accent : Theme.text
            Behavior on color { ColorAnimation { duration: 150 } }
            text: "\uf067"
          }

          MouseArea {
            id: addMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.newTask()
          }
        }
      }

      // ----- empty state -----
      Text {
        visible: root.shown.length === 0
        width: parent.width
        topPadding: 10
        bottomPadding: 10
        horizontalAlignment: Text.AlignHCenter
        font.family: Theme.font
        font.pixelSize: 11
        color: Theme.muted
        text: root.tab === 0 ? "no pending tasks" : "no done tasks"
      }

      // ----- task list -----
      ListView {
        id: list

        visible: root.shown.length > 0
        width: parent.width
        height: Math.min(root.shown.length * root.rowHeight
                         + Math.max(0, root.shown.length - 1) * spacing, 262)
        clip: true
        spacing: 2
        model: root.shown
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          id: taskRow

          required property var modelData
          required property int index

          readonly property bool hasPrefix: taskRow.modelData.prefix !== ""
          readonly property color tag: root.tagColor(taskRow.modelData.prefix)
          // dim the tag on done tasks so the border/bar don't shout there
          readonly property color tagFg: taskRow.modelData.done
              ? Qt.rgba(taskRow.tag.r, taskRow.tag.g, taskRow.tag.b, 0.5)
              : taskRow.tag

          width: list.width
          height: root.rowHeight
          radius: 6
          color: taskRow.modelData.id === root.editingId ? Theme.surface
               : rowMa.containsMouse ? Theme.hover : "transparent"
          Behavior on color { ColorAnimation { duration: 150 } }

          // prefix accent bar: groups tasks that share a prefix
          Rectangle {
            visible: taskRow.hasPrefix
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 3
            radius: 1.5
            color: taskRow.tagFg
          }

          // click anywhere on the row (the toggle/delete buttons sit on top)
          // to edit the task; the editor opens below the list
          MouseArea {
            id: rowMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.editTask(taskRow.modelData.id)
          }

          // ----- toggle done / restore -----
          Rectangle {
            id: toggleBtn

            anchors.left: parent.left
            anchors.leftMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 22; height: 22; radius: 5
            color: toggleMa.containsMouse ? Theme.hover : Theme.surface
            Behavior on color { ColorAnimation { duration: 150 } }

            Text {
              anchors.centerIn: parent
              font.family: Theme.font
              font.pixelSize: 12
              color: taskRow.modelData.done ? Theme.live : Theme.muted
              text: taskRow.modelData.done ? "\uf00c" : "\uf10c"
            }

            MouseArea {
              id: toggleMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleTask(taskRow.modelData.id)
            }
          }

          // ----- reorder + delete (sit above the row click area) -----
          Row {
            id: rowActions

            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Rectangle {
                width: 20; height: 18; radius: 4
                color: upMa.containsMouse && upMa.enabled ? Theme.hover : "transparent"
                opacity: upMa.enabled ? 1 : 0.25
                Behavior on color { ColorAnimation { duration: 150 } }

                Text {
                  anchors.centerIn: parent
                  font.family: Theme.font
                  font.pixelSize: 11
                  color: Theme.muted
                  text: "\uf106"
                }

                MouseArea {
                  id: upMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  enabled: taskRow.index > 0
                  onClicked: root.moveTask(taskRow.modelData.id, -1)
                }
              }

              Rectangle {
                width: 20; height: 18; radius: 4
                color: downMa.containsMouse && downMa.enabled ? Theme.hover : "transparent"
                opacity: downMa.enabled ? 1 : 0.25
                Behavior on color { ColorAnimation { duration: 150 } }

                Text {
                  anchors.centerIn: parent
                  font.family: Theme.font
                  font.pixelSize: 11
                  color: Theme.muted
                  text: "\uf107"
                }

                MouseArea {
                  id: downMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  enabled: taskRow.index < root.shown.length - 1
                  onClicked: root.moveTask(taskRow.modelData.id, 1)
                }
              }
            }

            Rectangle {
              id: delBtn

              anchors.verticalCenter: parent.verticalCenter
              width: 22; height: 22; radius: 5
              color: delMa.containsMouse ? Theme.err : "transparent"
              Behavior on color { ColorAnimation { duration: 150 } }

              Text {
                anchors.centerIn: parent
                font.family: Theme.font
                font.pixelSize: 12
                color: delMa.containsMouse ? Theme.deep : Theme.muted
                Behavior on color { ColorAnimation { duration: 150 } }
                text: "\uf1f8"
              }

              MouseArea {
                id: delMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.removeTask(taskRow.modelData.id)
              }
            }
          }

          // ----- prefix + name + description -----
          Column {
            anchors.left: toggleBtn.right
            anchors.leftMargin: 8
            anchors.right: rowActions.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Row {
              width: parent.width
              spacing: 6

              // prefix badge, tinted with the prefix color
              Rectangle {
                id: badge
                visible: taskRow.hasPrefix
                anchors.verticalCenter: parent.verticalCenter
                width: visible ? Math.min(badgeText.implicitWidth + 10, 120) : 0
                height: 14
                radius: 4
                color: Qt.rgba(taskRow.tag.r, taskRow.tag.g, taskRow.tag.b,
                               taskRow.modelData.done ? 0.08 : 0.2)

                Text {
                  id: badgeText
                  anchors.centerIn: parent
                  width: Math.min(implicitWidth, 110)
                  text: taskRow.modelData.prefix
                  font.family: Theme.font
                  font.pixelSize: 9
                  font.bold: true
                  color: taskRow.tagFg
                  elide: Text.ElideRight
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - (badge.visible ? badge.width + parent.spacing : 0)
                text: taskRow.modelData.name
                font.family: Theme.font
                font.pixelSize: 12
                font.strikeout: taskRow.modelData.done
                color: taskRow.modelData.done ? Theme.muted : Theme.text
                elide: Text.ElideRight
              }
            }

            Text {
              visible: taskRow.modelData.desc !== ""
              width: parent.width
              // single-line row: show only the first line of a multiline desc
              text: taskRow.modelData.desc.split("\n")[0]
              font.family: Theme.font
              font.pixelSize: 10
              color: Theme.muted
              elide: Text.ElideRight
            }
          }
        }
      }

      // ----- editor sub-panel: new / edit, opens below the list -----
      Rectangle {
        id: editor
        visible: root.editorOpen
        width: parent.width
        implicitHeight: editorCol.implicitHeight + 20
        radius: 6
        color: Theme.surface
        border.color: Theme.border
        border.width: 1

        Column {
          id: editorCol
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: 10
          spacing: 6

          Row {
            width: parent.width
            spacing: 6

            Text {
              id: editorTitle
              anchors.verticalCenter: parent.verticalCenter
              text: root.editingId === "" ? "new task" : "edit task"
              font.family: Theme.font
              font.pixelSize: 10
              color: Theme.muted
            }

            Item {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(parent.width - editorTitle.implicitWidth
                              - saveHint.implicitWidth - parent.spacing * 2, 0)
              height: 1
            }

            Text {
              id: saveHint
              anchors.verticalCenter: parent.verticalCenter
              font.family: Theme.font
              font.pixelSize: 10
              color: Theme.muted
              opacity: 0.7
              text: "Ctrl+Enter saves"
            }
          }

          Row {
            width: parent.width
            spacing: 6

            TextEntry {
              id: nameField
              width: parent.width - prefixField.width - parent.spacing
              placeholderText: "task name"
              onAccepted: root.saveEditor()
            }

            TextEntry {
              id: prefixField
              width: 96
              placeholderText: "prefix"
              onAccepted: root.saveEditor()
            }
          }

          // multiline description in a scrollable box: Enter breaks the line,
          // Ctrl+Enter saves
          Flickable {
            id: descScroll
            width: parent.width
            height: 110
            contentWidth: width
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            TextArea.flickable: TextArea {
              id: descField
              width: descScroll.width
              height: Math.max(descScroll.height, implicitHeight)
              placeholderText: "description (optional)"
              placeholderTextColor: Theme.muted
              color: Theme.text
              selectionColor: Theme.accent
              selectedTextColor: Theme.deep
              font.family: Theme.font
              font.pixelSize: 12
              leftPadding: 8
              rightPadding: 8
              topPadding: 7
              bottomPadding: 7
              wrapMode: TextEdit.Wrap

              background: Rectangle {
                radius: 6
                color: descField.activeFocus ? Theme.hover : Theme.surface
                border.color: descField.activeFocus ? Theme.accent : Theme.border
                Behavior on color { ColorAnimation { duration: 150 } }
                Behavior on border.color { ColorAnimation { duration: 150 } }
              }

              Keys.onReturnPressed: event => {
                if (event.modifiers & Qt.ControlModifier) {
                  event.accepted = true;
                  root.saveEditor();
                } else {
                  // explicit newline: don't rely on the control's default
                  // handling (it never fires inside this popup)
                  descField.insert(descField.cursorPosition, "\n");
                  event.accepted = true;
                }
              }
              Keys.onEnterPressed: event => {
                if (event.modifiers & Qt.ControlModifier) {
                  event.accepted = true;
                  root.saveEditor();
                } else {
                  descField.insert(descField.cursorPosition, "\n");
                  event.accepted = true;
                }
              }
            }

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          }

          // prefix color: auto (hashed) + one swatch per Theme.tagColors.
          // The pick is stored per prefix, so every task sharing it changes.
          Row {
            visible: prefixField.text.trim() !== ""
            width: parent.width
            spacing: 6

            Text {
              anchors.verticalCenter: parent.verticalCenter
              font.family: Theme.font
              font.pixelSize: 10
              color: Theme.muted
              text: "color"
            }

            // live preview of the resolved color for the typed prefix
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: 10; height: 10; radius: 5
              color: root.editingColor !== ""
                  ? root.editingColor : root.tagColor(prefixField.text)
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: 20; height: 20; radius: 10
              color: "transparent"
              border.width: 2
              border.color: root.editingColor === "" ? Theme.accent : Theme.border

              Text {
                anchors.centerIn: parent
                font.family: Theme.font
                font.pixelSize: 10
                color: Theme.muted
                text: "A"
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.editingColor = ""
              }
            }

            Repeater {
              model: Theme.tagColors

              delegate: Rectangle {
                required property string modelData
                readonly property bool sel: root.editingColor === modelData

                anchors.verticalCenter: parent.verticalCenter
                width: 20; height: 20; radius: 10
                color: modelData
                border.width: 2
                border.color: sel ? Theme.text : "transparent"
                scale: swMa.containsMouse ? 1.15 : 1
                Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

                MouseArea {
                  id: swMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.editingColor = modelData
                }
              }
            }
          }

          Row {
            width: parent.width
            spacing: 6

            Rectangle {
              id: cancelBtn
              width: 76
              height: 26
              radius: 6
              color: cancelMa.containsMouse ? Theme.hover : Theme.bg
              Behavior on color { ColorAnimation { duration: 200 } }

              Text {
                anchors.centerIn: parent
                font.family: Theme.font
                font.pixelSize: 11
                color: Theme.text
                text: "cancel"
              }

              MouseArea {
                id: cancelMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.closeEditor()
              }
            }

            Rectangle {
              id: saveBtn
              width: parent.width - cancelBtn.width - parent.spacing
              height: 26
              radius: 6
              color: saveMa.containsMouse ? Theme.accent2 : Theme.accent
              Behavior on color { ColorAnimation { duration: 200 } }

              Text {
                anchors.centerIn: parent
                font.family: Theme.font
                font.bold: true
                font.pixelSize: 11
                color: Theme.deep
                text: root.editingId === "" ? "add task" : "save"
              }

              MouseArea {
                id: saveMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.saveEditor()
              }
            }
          }
        }
      }
    }
  }
}
