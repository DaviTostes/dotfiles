//@ pragma UseQApplication
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick
import "bar"

Scope {
  id: root

  // bars by monitor name — the IPC bridge routes keybind calls to the
  // focused monitor's bar (panels are per-bar; a per-instance IpcHandler
  // would duplicate the target across monitors)
  property var bars: ({})

  Variants {
    model: Quickshell.screens;

    delegate: Component {
      Bar {
        id: bar

        required property var modelData
        screen: modelData

        Component.onCompleted: {
          const m = Hyprland.monitorFor(screen);
          if (m) root.bars[m.name] = bar;
        }
        Component.onDestruction: {
          const m = Hyprland.monitorFor(screen);
          if (m) delete root.bars[m.name];
        }
      }
    }
  }

  // global keybind bridge — hyprland.lua: SUPER+A → `qs ipc call opencode toggle`,
  // SUPER+N → `qs ipc call notifs toggle` (calendar panel w/ notifications)
  IpcHandler {
    target: "opencode"

    function toggle() {
      const m = Hyprland.focusedMonitor;
      const bar = m ? root.bars[m.name] : null;
      if (bar) bar.toggleChat();
    }

    function open() {
      const m = Hyprland.focusedMonitor;
      const bar = m ? root.bars[m.name] : null;
      if (bar) bar.openChat();
    }

    function close() {
      for (const k in root.bars) root.bars[k].closeChat();
    }
  }

  IpcHandler {
    target: "notifs"

    function toggle() {
      const m = Hyprland.focusedMonitor;
      const bar = m ? root.bars[m.name] : null;
      if (bar) bar.toggleNotifPanel();
    }

    function clear() { Notifs.clearAll(); }
  }
}
