# AGENTS.md

Guidance for AI agents working in this dotfiles repo.

## Layout

XDG-style tree managed with GNU stow (or manual symlinks): each top-level
directory mirrors `$HOME`, e.g. `quickshell/.config/quickshell/shell.qml`
lands at `~/.config/quickshell/shell.qml`.

- `quickshell/` — quickshell shell config (bar + hypr settings panel +
  Super+Space launcher + Super+Alt+Space clipboard history)
- `hypr/` — Hyprland + awww/hyprlock/hypridle configs (Hyprland itself is
  configured in Lua via `hyprland.lua`, which drives Hyprland through the `hl` API)
- `waybar/`, `swaync/`, `swayosd/`, `kitty/`, `fish/`, `tmux/`, `nvim/` — their respective app configs
  (there is no `wofi/` any more: quickshell serves all four binds it used to)
- `gtk/` — `Quickshell-Dark` GTK 3/4 theme mirroring the quickshell palette
  (installed via symlink at `~/.local/share/themes/`, plus the libadwaita
  override symlinked at `~/.config/gtk-4.0/gtk.css`)
- `backgrounds/` — wallpapers

## Quickshell (`quickshell/.config/quickshell/`)

- `shell.qml` is the entry point; `bar/` holds the bar and its pill widgets;
  `hyprconf/` holds the Hypr Config dropdown panel (edits wallpaper / hyprlock /
  hypridle confs via `Quickshell.Io.FileView`, parsing logic in `Conf.js`).
  The panel is a `PopupWindow` anchored under the bar's settings pill
  (Pomodoro-style, one per monitor); click-outside close uses
  `HyprlandFocusGrab` — do not turn it back into a standalone window.
- The dropdown has six tabs, in `HyprConfig.tabs` order: Wallpaper, Lock
  Screen, Idle, **Bluetooth** (`BluetoothTab.qml`), **Wi-Fi** (`WifiTab.qml`),
  **VPN** (`VpnTab.qml`).
  The bar's `openSettings(name)` resolves a tab by name and the IPC
  `qs ipc call settings open bluetooth|wifi|vpn` (SUPER+SHIFT+B / SUPER+SHIFT+W
  / SUPER+SHIFT+V) opens straight on one; clicking a tab button still owns
  `root.tab`. `HyprConfig.tabIndex()` normalises names (`wifi` == `Wi-Fi`).
- `BluetoothTab.qml` drives BlueZ through `Quickshell.Bluetooth` (no bzmenu):
  bonded devices connect/disconnect/forget natively. Device *icons* are mapped
  from BlueZ icon names to Nerd Font glyphs — `Quickshell.iconPath()` does not
  reliably resolve names like `audio-headset` here. BlueZ refuses the HID
  profile to a non-bonded device and Quickshell 0.3.1 registers no pairing
  agent, so a fresh device is paired by shelling out to `bluetoothctl`
  (pair → trust → connect via `Process`), which brings its own Just Works
  agent; devices demanding host PIN/passkey entry still can't be paired here.
- `WifiTab.qml` drives **iwd** through `iwctl` (`Process`), *not*
  `Quickshell.Networking` — that module only supports NetworkManager (enum
  `None`/`NetworkManager`) and this machine runs iwd with NetworkManager
  inactive. The iwctl tables are fixed-width + ANSI coloured (signal "stars"
  are dimmed for unfilled slots), and `iwctl` prints errors on **stdout** with
  exit code 1. Never shell-interpolate user text: commands are argv arrays
  (`Process.command`), and the passphrase goes through `--passphrase`.
- `VpnTab.qml` drives Proton VPN CLI (`protonvpn`) through `Process` with argv
  arrays (no shell). Parses `status` (Connected + Server/Load/Protocol),
  `info` (account), `countries list` and `cities list <code>` (tabulate
  tables, header/separator skipped). Actions: fastest, random, per-country,
  per-city, manual server ID, disconnect; P2P / Secure Core / Tor flags append
  to the next connect. Like Wi-Fi it loads lazily (`loadVpnIfVisible`, tab 5).
- `bar/Launcher.qml` is the Super+Space app launcher. It is a fullscreen
  `Overlay` layer-shell `PanelWindow` with `Exclusive` keyboard focus, so it is
  typed into directly — no hidden-TextInput workaround like the bar popups.
  Opened via `qs ipc call launcher toggle`. Launcher, clipboard history and the
  two settings tabs cover all four binds wofi used to serve, and wofi/bzmenu/
  iwmenu are gone from the system.
- `bar/Tasks.qml` is the tasks pill: a Pomodoro-style dropdown (one per bar)
  with **pending** / **done** tabs and a **+** icon top-right that opens the
  editor. A task carries a name, an optional description and an optional
  **prefix**; tasks sharing a prefix get the same color (custom override in
  `tasks-prefix-colors.json`, else a deterministic hash → vivid
  `Theme.tagColors`), drawn as a colored left accent bar + badge on the row.
  Clicking a row opens the same editor sub-panel below the list to update it;
  the editor also carries the per-prefix color swatches. Rows reorder with
  up/down chevrons (`moveTask` swaps within the visible tab), and are checked
  off (or restored) and deleted from the row. The list persists at
  `Quickshell.stateDir/tasks.json` via `Quickshell.Io.FileView` (the same store
  trick as the launcher). Text entry reuses `hyprconf/TextEntry.qml`; the bar
  holds the keyboard while the panel is open (`Bar.focusable ←
  tasksPanelOpen`), like the settings dropdown. Opened via
  `qs ipc call tasks toggle` (SUPER+O, moved off the omm launcher).
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
- `WallpaperImage.qml` renders wallpaper paths for the gallery grid
  (`WallpaperGrid.qml`) and the `PreviewBox` used by the Wallpaper and Lock
  Screen tabs. It swaps `Image` for `AnimatedImage` on `.gif` sources so live
  wallpapers animate in the panel; `animate` gates playback and callers bind it
  to the panel/gallery being open (via `panelOpen` / `galleryWin.open`) so
  nothing animates off-screen. Needs `qt6-imageformats` (libqgif).
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
- The quickshell `hyprconf/` panel writes `wallpaper.conf`,
  `hyprlock.conf`, and `hypridle.conf` in place; keep its parse/serialize
  round-trip (`Conf.js`) lossless when touching that code.
- Wallpapers run through **awww** (swww's successor), not hyprpaper, so
  animated GIFs work. `wallpaper.conf` is the source of truth
  (`transition = <awww type>` plus one hyprpaper-style `wallpaper { … }`
  block per monitor); `scripts/wallpaper-apply` parses it and issues
  `awww img -o <monitor> --resize <fit_mode>`, and is the single apply path
  used by both the autostart in `hyprland.lua` and the panel's Save.
  `awww-daemon` must be running first — the script polls `awww query` for it.

## Conventions

- QML: 4-space indent in `hyprconf/`, 2-space in `bar/` — match the file
  you are editing.
- No build system or dependency install; plain file edits are the whole
  workflow.
