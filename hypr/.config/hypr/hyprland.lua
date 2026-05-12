--------------------
---- MONITORS ----
--------------------

hl.monitor({ output = "DP-2", mode = "1920x1080@120", position = "0x0", scale = 1 })
hl.monitor({ output = "HDMI-A-1", mode = "1920x1080@75", position = "1920x0", scale = 1 })

hl.workspace_rule({ workspace = "1", monitor = "DP-2", default = false })
hl.workspace_rule({ workspace = "2", monitor = "HDMI-A-1", default = true })

-- hl.monitor({ output = "eDP-1",    mode = "1920x1080@60", position = "0x0",    scale = 1 })
-- hl.monitor({ output = "HDMI-A-1", mode = "1920x1080@75", position = "1920x0", scale = 1 })

---------------------
---- MY PROGRAMS ----
---------------------

local terminal    = "kitty"
local fileManager = "pcmanfm"
local menu        = "wofi --width 750 --height 355 --show drun"
local clipHistory = "cliphist list | wofi -S dmenu | cliphist decode | wl-copy"
local browser     = "zen-browser"
local discord     = "vesktop"
local btManager   = "bzmenu -l custom --launcher-command 'wofi --show dmenu'"
local wifiManager = "iwmenu -l custom --launcher-command 'wofi --show dmenu'"

-------------------
---- AUTOSTART ----
-------------------

hl.on("hyprland.start", function()
  hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP")
  hl.exec_cmd("swaync")
  hl.exec_cmd("hypridle")
  hl.exec_cmd("hyprpaper")
  hl.exec_cmd("swayosd-server")
  hl.exec_cmd("wl-paste --watch cliphist store")
end)

-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------

hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")

hl.env("LIBVA_DRIVER_NAME", "radeonsi")

hl.env("XCURSOR_THEME", "Bibata-Modern-Classic")
hl.env("XCURSOR_SIZE", "28")
hl.env("HYPRCURSOR_SIZE", "28")

hl.env("QT_QPA_PLATFORMTHEME", "qt5ct")

-----------------------
---- LOOK AND FEEL ----
-----------------------

hl.config({
  general = {
    gaps_in          = 0,
    gaps_out         = 0,

    border_size      = 2,

    col              = {
      active_border   = "rgba(60,60,60,1)",
      inactive_border = "rgba(32,32,32,1)",
    },

    resize_on_border = false,
    allow_tearing    = false,
    layout           = "dwindle",
  },

  decoration = {
    rounding         = 1,
    rounding_power   = 2,

    active_opacity   = 1.0,
    inactive_opacity = 1.0,

    shadow           = {
      enabled      = true,
      range        = 4,
      render_power = 3,
      color        = 0xee1a1a1a,
    },

    blur             = {
      enabled  = true,
      size     = 3,
      passes   = 1,
      vibrancy = 0.1696,
    },
  },

  animations = {
    enabled = true,
  },

  dwindle = {
    preserve_split = true,
  },

  master = {
    new_status = "master",
  },

  misc = {
    force_default_wallpaper = -1,
    disable_hyprland_logo   = false,
    focus_on_activate       = false,
  },

  input = {
    kb_layout    = "us",
    kb_variant   = "",
    kb_model     = "",
    kb_options   = "",
    kb_rules     = "",

    follow_mouse = 1,
    sensitivity  = 0,

    touchpad     = {
      natural_scroll = false,
    },
  },

  cursor = {
    no_hardware_cursors = true,
  },

  xwayland = {
    force_zero_scaling = true,
  },
})

hl.device({
  name        = "epic-mouse-v1",
  sensitivity = -0.5,
})

--------------------
---- ANIMATIONS ----
--------------------

hl.curve("easeOutQuint", { type = "bezier", points = { { 0.23, 1 }, { 0.32, 1 } } })
hl.curve("easeInOutCubic", { type = "bezier", points = { { 0.65, 0.05 }, { 0.36, 1 } } })
hl.curve("linear", { type = "bezier", points = { { 0, 0 }, { 1, 1 } } })
hl.curve("almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1 } } })
hl.curve("quick", { type = "bezier", points = { { 0.15, 0 }, { 0.1, 1 } } })

hl.animation({ leaf = "global", enabled = true, speed = 10, bezier = "default" })
hl.animation({ leaf = "border", enabled = true, speed = 5.39, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows", enabled = true, speed = 4.79, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 4.1, bezier = "easeOutQuint", style = "popin 87%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.49, bezier = "linear", style = "popin 87%" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 1.73, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 1.46, bezier = "almostLinear" })
hl.animation({ leaf = "fade", enabled = true, speed = 3.03, bezier = "quick" })
hl.animation({ leaf = "layers", enabled = true, speed = 3.81, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 4, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 1.5, bezier = "linear", style = "fade" })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 1.79, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 1.39, bezier = "almostLinear" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesIn", enabled = true, speed = 1.21, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesOut", enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "zoomFactor", enabled = true, speed = 7, bezier = "quick" })

----------------------
---- WINDOW RULES ----
----------------------

hl.window_rule({
  name  = "firefox-pip",
  match = { class = "firefox", title = "Picture-in-Picture" },
  float = true,
})

hl.window_rule({
  name       = "steam-games-fullscreen",
  match      = {
    content = "game",
    class   = "steam_app_%d+|gamescope",
    title   = "negative:^(?i)(.*(Launcher|NetEase Game Security).*)$",
  },
  fullscreen = true,
})

hl.window_rule({
  name         = "claude-quick-entry",
  match        = { class = "claude-quick-entry" },
  border_size  = 0,
  no_blur      = true,
  rounding     = 0,
  no_shadow    = true,
  stay_focused = true,
})

hl.window_rule({
  name   = "albus-response",
  match  = { title = "albus-response" },
  float  = true,
  center = true,
  size   = { 800, 600 },
})

---------------------
---- KEYBINDINGS ----
---------------------

local mainMod = "SUPER"

hl.bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + C", hl.dsp.window.close())
hl.bind(mainMod .. " + M", hl.dsp.exec_cmd("command -v hyprshutdown >/dev/null 2>&1 && hyprshutdown || hyprctl dispatch 'hl.dsp.exit()'"))
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager))
hl.bind(mainMod .. " + V", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + space", hl.dsp.exec_cmd(menu))
hl.bind("SUPER + ALT + space", hl.dsp.exec_cmd(clipHistory))

hl.bind(mainMod .. " + P", hl.dsp.window.pseudo())
hl.bind(mainMod .. " + T", hl.dsp.layout("togglesplit"))

hl.bind(mainMod .. " + B", hl.dsp.exec_cmd(browser))
hl.bind(mainMod .. " + D", hl.dsp.exec_cmd(discord))
hl.bind(mainMod .. " + S", hl.dsp.exec_cmd("steam"))
hl.bind(mainMod .. " + Z", hl.dsp.exec_cmd("zapzap"))
hl.bind("SUPER + SHIFT + Z", hl.dsp.exec_cmd("Telegram"))
hl.bind(mainMod .. " + A", hl.dsp.exec_cmd("claude-desktop --toggle"))
hl.bind("SUPER + SHIFT + B", hl.dsp.exec_cmd(btManager))
hl.bind("SUPER + SHIFT + W", hl.dsp.exec_cmd(wifiManager))
hl.bind("SUPER + SHIFT + I", hl.dsp.exec_cmd("kitty btop"))
hl.bind("SUPER + SHIFT + M", hl.dsp.exec_cmd("kitty maily"))
hl.bind(mainMod .. " + W", hl.dsp.exec_cmd("pgrep -x waybar && killall waybar || waybar"))
hl.bind(mainMod .. " + U", hl.dsp.exec_cmd("pavucontrol"))

hl.bind("F9", hl.dsp.exec_cmd("pkill -SIGUSR1 albus"))
hl.bind("F9", hl.dsp.exec_cmd("pkill -SIGUSR2 albus"), { release = true })

hl.bind("PRINT", hl.dsp.exec_cmd("hyprshot -m window"))
hl.bind("SHIFT + PRINT", hl.dsp.exec_cmd("hyprshot -m region"))
hl.bind("SUPER + SHIFT + L", hl.dsp.exec_cmd("hyprlock"))

hl.bind("SUPER + SHIFT + C", hl.dsp.exec_cmd("hyprpicker -a"))

hl.bind(mainMod .. " + R", hl.dsp.exec_cmd("fish -c record"))

hl.bind(mainMod .. " + H", hl.dsp.focus({ direction = "l" }))
hl.bind(mainMod .. " + L", hl.dsp.focus({ direction = "r" }))
hl.bind(mainMod .. " + K", hl.dsp.focus({ direction = "u" }))
hl.bind(mainMod .. " + J", hl.dsp.focus({ direction = "d" }))

for i = 1, 9 do
  hl.bind(mainMod .. " + " .. i, hl.dsp.focus({ workspace = i }))
  hl.bind("SUPER + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }))
end
hl.bind(mainMod .. " + 0", hl.dsp.focus({ workspace = 10 }))
hl.bind("SUPER + SHIFT + 0", hl.dsp.window.move({ workspace = 10 }))

hl.bind(mainMod .. " + Tab", hl.dsp.workspace.toggle_special("magic"))
hl.bind("SUPER + SHIFT + Tab", hl.dsp.window.move({ workspace = "special:magic" }))

hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))

hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("swayosd-client --output-volume raise"), { repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("swayosd-client --output-volume lower"), { repeating = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("swayosd-client --output-volume mute-toggle"), { locked = true })

hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightnessctl set +5%"), { repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 5%-"), { repeating = true })
