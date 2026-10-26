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

  // Super+Space app launcher. One instance for all monitors — it moves
  // itself to the focused monitor when opened (see Launcher.openFocused),
  // so unlike the bars it is not part of the Variants above.
  Launcher {
    id: launcher
  }

  // Super+Alt+Space clipboard history (same fullscreen-overlay trick).
  ClipHistory {
    id: clipboard
  }

  // Monkeytype-style typing test, shown in the middle of the desktop while the
  // focused workspace has no windows. `qs ipc call typetest toggle` (or the
  // widget's hide button) turns it on/off; the choice persists.
  TypeTest {
    id: typeTest
  }

  // Standalone full-size opencode chat: a second Opencode instance pinned to
  // full mode and hosted in a hidden window, so its FloatingWindow can be open
  // at the same time as a bar's docked intelligence central. Both instances
  // share the same chat selection through the OpencodeShared singleton.
  PanelWindow {
    id: opencodeFullHost
    visible: false
    implicitWidth: 1
    implicitHeight: 1
    color: "transparent"

    Opencode {
      id: opencodeFull
      standalone: true
    }
  }

  // global keybind bridge — hyprland.lua: SUPER+A → `qs ipc call opencode
  // toggle`, SUPER+N → `qs ipc call notifs toggle` (calendar panel with
  // notifications)
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

    // open the docked panel straight on a mode: chat | calc | translate | ocr
    function openMode(mode: string) {
      const m = Hyprland.focusedMonitor;
      const bar = m ? root.bars[m.name] : null;
      if (bar) bar.openIntel(mode);
    }

    // SUPER+A — the standalone full chat window (independent of the docked
    // intelligence central, so both can be open at once)
    function toggleExpanded() { root.toggleFullChat(); }

    // SUPER+SHIFT+A — the standalone full chat, straight into live Voice Mode
    function voiceFull() { root.toggleFullVoice(); }

    function close() {
      for (const k in root.bars) root.bars[k].closeChat();
    }

    function voice() {
      const m = Hyprland.focusedMonitor;
      const bar = m ? root.bars[m.name] : null;
      if (bar) bar.toggleVoiceChat();
    }
  }

  // the standalone full chat is its own Opencode instance; shared toggle for
  // the keybind and the `opencodeFull` IPC handler
  function toggleFullChat() {
    if (opencodeFull.panelOpen) opencodeFull.panelOpen = false;
    else opencodeFull.openStandalone(false);
  }

  // SUPER+SHIFT+A: closed → open the standalone in Voice Mode; already open in
  // Voice Mode → close it; open as a text chat → start Voice Mode on it.
  function toggleFullVoice() {
    if (!opencodeFull.panelOpen) opencodeFull.openStandalone(true);
    else if (opencodeFull.voiceMode) opencodeFull.panelOpen = false;
    else opencodeFull.startVoiceMode();
  }

  IpcHandler {
    target: "opencodeFull"

    function toggle() { root.toggleFullChat(); }
    function voice() { root.toggleFullVoice(); }
    function open() { opencodeFull.openStandalone(false); }
    function openVoice() { opencodeFull.openStandalone(true); }
    function close() { opencodeFull.panelOpen = false; }
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

  // GitHub pill: `qs ipc call github toggle` (SUPER+SHIFT+G)
  IpcHandler {
    target: "github"

    function toggle() {
      const m = Hyprland.focusedMonitor;
      const bar = m ? root.bars[m.name] : null;
      if (bar) bar.toggleGithub();
    }

    function close() {
      for (const k in root.bars) root.bars[k].closeGithub();
    }

    function status(): string {
      return "prs=" + Github.prCount + " unread=" + Github.unreadCount
          + " runs=" + Github.runningCount + " loading=" + Github.loading
          + " panels=" + Github.panelsOpen
          + " repos=" + Github.recentRepos.length
          + " error=" + (Github.error === "" ? "none" : Github.error);
    }

    function repos(): string { return Github.recentRepos.join(","); }
  }

  // SUPER+Space — app launcher (replaces wofi --show drun)
  IpcHandler {
    target: "launcher"

    function toggle() {
      // the two overlays are both fullscreen + Exclusive: never stack them
      if (!launcher.open) clipboard.close();
      launcher.toggle();
    }

    function close() { launcher.close(); }

    // wipes the frecency history (usage ordering)
    function clearUsage() { launcher.clearUsage(); }
  }

  // SUPER+ALT+Space — clipboard history (replaces wofi -S dmenu)
  IpcHandler {
    target: "clipboard"

    function toggle() {
      if (!clipboard.open) launcher.close();
      clipboard.toggle();
    }

    function close() { clipboard.close(); }
  }

  // desk typing test on/off (the dock's type tab does the same)
  IpcHandler {
    target: "typetest"

    function toggle() { typeTest.view = typeTest.view === 0 ? -1 : 0; }
    function enable() { typeTest.view = 0; }
    function disable() { if (typeTest.view === 0) typeTest.view = -1; }
  }

  // settings dropdown, straight on a tab by name: `qs ipc call settings open
  // bluetooth` (SUPER+SHIFT+B) / `open wifi` (SUPER+SHIFT+W) /
  // `open vpn` (SUPER+SHIFT+V). Tab names live in HyprConfig.tabs.
  IpcHandler {
    target: "settings"

    function open(tab: string) {
      const m = Hyprland.focusedMonitor;
      const bar = m ? root.bars[m.name] : null;
      if (bar) bar.openSettings(tab);
    }

    function close() {
      for (const k in root.bars) root.bars[k].closeSettings();
    }
  }
}
