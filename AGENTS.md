# AGENTS.md

Guidance for AI agents working in this dotfiles repo.

## Layout

XDG-style tree managed with GNU stow (or manual symlinks): each top-level
directory mirrors `$HOME`, e.g. `quickshell/.config/quickshell/shell.qml`
lands at `~/.config/quickshell/shell.qml`.

- `quickshell/` — quickshell shell config (bar + hypr settings panel +
  Super+Space launcher + Super+Alt+Space clipboard history)
- `hypr/` — Hyprland + hyprpaper/hyprlock/hypridle configs (Hyprland itself is
  configured in Lua via `hyprland.lua`, which drives Hyprland through the `hl` API)
- `waybar/`, `swaync/`, `swayosd/`, `kitty/`, `fish/`, `tmux/`, `nvim/` — their respective app configs
  (there is no `wofi/` any more: quickshell serves all four binds it used to)
- `gtk/` — `Quickshell-Dark` GTK 3/4 theme mirroring the quickshell palette
  (installed via symlink at `~/.local/share/themes/`, plus the libadwaita
  override symlinked at `~/.config/gtk-4.0/gtk.css`)
- `backgrounds/` — wallpapers

## Quickshell (`quickshell/.config/quickshell/`)

- `shell.qml` is the entry point; `bar/` holds the bar and its pill widgets;
  `hyprconf/` holds the Hypr Config dropdown panel (edits hyprpaper / hyprlock /
  hypridle confs via `Quickshell.Io.FileView`, parsing logic in `Conf.js`).
  The panel is a `PopupWindow` anchored under the bar's settings pill
  (Pomodoro-style, one per monitor); click-outside close uses
  `HyprlandFocusGrab` — do not turn it back into a standalone window.
- The dropdown has five tabs, in `HyprConfig.tabs` order: Wallpaper, Lock
  Screen, Idle, **Bluetooth** (`BluetoothTab.qml`), **Wi-Fi** (`WifiTab.qml`).
  The bar's `openSettings(name)` resolves a tab by name and the IPC
  `qs ipc call settings open bluetooth|wifi` (SUPER+SHIFT+B / SUPER+SHIFT+W)
  opens straight on one; clicking a tab button still owns `root.tab`.
  `HyprConfig.tabIndex()` normalises names (`wifi` == `Wi-Fi`).
- `BluetoothTab.qml` drives BlueZ through `Quickshell.Bluetooth` (no bzmenu).
  Device *icons* are mapped from BlueZ icon names to Nerd Font glyphs —
  `Quickshell.iconPath()` does not reliably resolve names like
  `audio-headset` here. Quickshell 0.3.1 has no pairing agent, so devices
  needing PIN/passkey confirmation cannot be paired from the panel.
- `WifiTab.qml` drives **iwd** through `iwctl` (`Process`), *not*
  `Quickshell.Networking` — that module only supports NetworkManager (enum
  `None`/`NetworkManager`) and this machine runs iwd with NetworkManager
  inactive. The iwctl tables are fixed-width + ANSI coloured (signal "stars"
  are dimmed for unfilled slots), and `iwctl` prints errors on **stdout** with
  exit code 1. Never shell-interpolate user text: commands are argv arrays
  (`Process.command`), and the passphrase goes through `--passphrase`.
- `bar/Launcher.qml` is the Super+Space app launcher. It is a fullscreen
  `Overlay` layer-shell `PanelWindow` with `Exclusive` keyboard focus, so it is
  typed into directly — no hidden-TextInput workaround like the bar popups.
  Opened via `qs ipc call launcher toggle`. Launcher, clipboard history and the
  two settings tabs cover all four binds wofi used to serve, and wofi/bzmenu/
  iwmenu are gone from the system.
- Launcher ordering is **frecency** (launch count + recency), persisted at
  `Quickshell.stateDir/launcher-usage.json` (i.e.
  `~/.local/state/quickshell/by-shell/<hash>/launcher-usage.json`) through
  `Quickshell.Io.FileView` — quickshell creates that directory itself. Usage
  only breaks ties among matches (capped bonus); it fully drives the
  empty-query list. Reset with `qs ipc call launcher clearUsage`. Note desktop
  entry ids have **no** `.desktop` suffix (`mpv`, not `mpv.desktop`).
- `bar/ClipHistory.qml` is the Super+Alt+Space clipboard history. It only
  replaces wofi's role as the picker — `cliphist` stays as the store (sqlite,
  images included, fed by the `wl-paste --watch cliphist store` autostart).
  It runs `cliphist list` through a `Quickshell.Io.Process` +
  `StdioCollector` (parsing `<id>\t<preview>`, first tab only) and copies with
  `cliphist decode <id> | wl-copy` (the pipe is what keeps images working).
  Opened via `qs ipc call clipboard toggle`; same fullscreen `Overlay` +
  `Exclusive` keyboard approach as the launcher. `results` is only filled on
  open (that is when `cliphist list` runs), so nothing queries it while closed.
- Per-component QML files are registered in `hyprconf/qmldir`; shared state
  lives in singletons (`HyprSettings`, `Theme`) and is referenced directly by
  name from files in the same directory — no import needed.
- **Style:** everything must follow the Pomodoro dropdown palette, defined
  once in `hyprconf/Theme.qml` (bg `#161719`, border `#282a2e`, surface
  `#1e2126`, hover `#282c33`, text `#a9afb8`, muted `#5c6470`, accent
  `#d3d9e0`, secondary accent `#8b95a3`, dark-on-accent `#101216`, font
  `Agave Nerd Font`). Never hardcode colors or the font family in
  components — reference `Theme.*`.
- Interactions use Pomodoro-style motion: `ColorAnimation` 150–200ms on
  colors, small hover scale pops (`1.04`–`1.07`) with `OutCubic` easing.
- Validate changes with `qmllint <file>.qml` (run from
  `quickshell/.config/quickshell/`) before finishing. Live reload with
  `qs` only if the user asks for it.

## Hyprland configs

- `hyprland.lua` uses the Lua config API (`hl.env`, `hl.exec`, …) — keep new
  settings in Lua, don't create a parallel `hyprland.conf`.
- The quickshell `hyprconf/` panel writes `hyprpaper.conf`,
  `hyprlock.conf`, and `hypridle.conf` in place; keep its parse/serialize
  round-trip (`Conf.js`) lossless when touching that code.

## Conventions

- QML: 4-space indent in `hyprconf/`, 2-space in `bar/` — match the file
  you are editing.
- No build system or dependency install; plain file edits are the whole
  workflow.
