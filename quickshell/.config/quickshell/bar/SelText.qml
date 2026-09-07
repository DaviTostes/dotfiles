import QtQuick
import "../hyprconf"

// Selectable, auto-copying read-only text block for chat messages:
// mouse-select copies to the clipboard as soon as the drag settles.
// Inverted theme colors make the selection obvious.
TextEdit {
  id: base

  signal copied

  readOnly: true
  persistentSelection: true
  wrapMode: TextEdit.Wrap
  font.family: Theme.font
  selectionColor: Theme.accent
  selectedTextColor: Theme.deep
  color: Theme.text

  onSelectedTextChanged: {
    if (selectedText === "") return;
    // selection settled (drag released or paused) → copy. Restarting on
    // every change keeps mid-drag updates from spamming the clipboard
    copyTimer.restart();
  }

  Timer {
    id: copyTimer
    interval: 250
    onTriggered: {
      if (base.selectedText !== "") { base.copy(); base.copied(); }
    }
  }
}
