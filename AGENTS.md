# AGENTS.md

Guidance for AI agents working in this dotfiles repo.

## Layout

XDG-style tree managed with GNU stow (or manual symlinks): each top-level
directory mirrors `$HOME`, e.g. `quickshell/.config/quickshell/shell.qml`
lands at `~/.config/quickshell/shell.qml`.

- `quickshell/` — quickshell shell config (bar + hypr settings panel)
- `hypr/` — Hyprland + hyprpaper/hyprlock/hypridle configs (Hyprland itself is
  configured in Lua via `hyprland.lua`, which drives Hyprland through the `hl` API)
- `waybar/`, `wofi/`, `swaync/`, `swayosd/`, `kitty/`, `fish/`, `tmux/`, `nvim/` — their respective app configs
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
