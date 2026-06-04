-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------

local cursorSize = "22"

local envs = {
  XDG_CURRENT_DESKTOP  = "Hyprland",
  XDG_SESSION_TYPE     = "wayland",
  XDG_SESSION_DESKTOP  = "Hyprland",

  LIBVA_DRIVER_NAME    = "radeonsi",

  XCURSOR_THEME        = "Sunity-cursors-white",
  XCURSOR_SIZE         = cursorSize,
  HYPRCURSOR_SIZE      = cursorSize,

  QT_QPA_PLATFORMTHEME = "qt5ct",
}

for k, v in pairs(envs) do
  hl.env(k, v)
end

-------------------
---- AUTOSTART ----
-------------------

local autostart = {
  "dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP",
  "waybar",
  "swaync",
  "hypridle",
  "hyprpaper",
  "swayosd-server",
  "wl-paste --watch cliphist store",
}

hl.on("hyprland.start", function()
  for _, cmd in ipairs(autostart) do
    hl.exec_cmd(cmd)
  end
end)

--------------------
---- MONITORS ----
--------------------

local primaryMonitor   = "DP-2"
local secondaryMonitor = "HDMI-A-1"
local resolution       = "1920x1080"

hl.monitor({ output = primaryMonitor, mode = resolution .. "@120", position = "0x0", scale = 1 })
hl.monitor({ output = secondaryMonitor, mode = resolution .. "@75", position = "1920x0", scale = 1 })

hl.workspace_rule({ workspace = "1", monitor = primaryMonitor, default = false })
hl.workspace_rule({ workspace = "2", monitor = secondaryMonitor, default = true })

-- hl.monitor({ output = "eDP-1",    mode = "1920x1080@60", position = "0x0",    scale = 1 })
-- hl.monitor({ output = "HDMI-A-1", mode = "1920x1080@75", position = "1920x0", scale = 1 })

---------------------
---- MY PROGRAMS ----
---------------------

local terminal    = "kitty"
local fileManager = "pcmanfm"
local menu        = "wofi --width 750 --height 355 --show drun"
local clipHistory = "cliphist list | wofi -S dmenu | cliphist decode | wl-copy"
local browser     = "helium-browser"
local discord     = "vesktop"
local btManager   = "bzmenu -l custom --launcher-command 'wofi --show dmenu'"
local wifiManager = "iwmenu -l custom --launcher-command 'wofi --show dmenu'"

local function termRun(cmd) return terminal .. " " .. cmd end

-----------------------
---- LOOK AND FEEL ----
-----------------------

hl.config({
  general = {
    gaps_in          = 0,
    gaps_out         = 2,

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
    rounding         = 8,
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

local curves = {
  easeOutQuint   = { { 0.23, 1 }, { 0.32, 1 } },
  easeInOutCubic = { { 0.65, 0.05 }, { 0.36, 1 } },
  linear         = { { 0, 0 }, { 1, 1 } },
  almostLinear   = { { 0.5, 0.5 }, { 0.75, 1 } },
  quick          = { { 0.15, 0 }, { 0.1, 1 } },
}

for name, points in pairs(curves) do
  hl.curve(name, { type = "bezier", points = points })
end

local animations = {
  { leaf = "global",        enabled = true, speed = 10,   bezier = "default" },
  { leaf = "border",        enabled = true, speed = 5.39, bezier = "easeOutQuint" },
  { leaf = "windows",       enabled = true, speed = 4.79, bezier = "easeOutQuint" },
  { leaf = "windowsIn",     enabled = true, speed = 4.1,  bezier = "easeOutQuint", style = "popin 87%" },
  { leaf = "windowsOut",    enabled = true, speed = 1.49, bezier = "linear",       style = "popin 87%" },
  { leaf = "fadeIn",        enabled = true, speed = 1.73, bezier = "almostLinear" },
  { leaf = "fadeOut",       enabled = true, speed = 1.46, bezier = "almostLinear" },
  { leaf = "fade",          enabled = true, speed = 3.03, bezier = "quick" },
  { leaf = "layers",        enabled = true, speed = 3.81, bezier = "easeOutQuint" },
  { leaf = "layersIn",      enabled = true, speed = 4,    bezier = "easeOutQuint", style = "fade" },
  { leaf = "layersOut",     enabled = true, speed = 1.5,  bezier = "linear",       style = "fade" },
  { leaf = "fadeLayersIn",  enabled = true, speed = 1.79, bezier = "almostLinear" },
  { leaf = "fadeLayersOut", enabled = true, speed = 1.39, bezier = "almostLinear" },
  { leaf = "workspaces",    enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" },
  { leaf = "workspacesIn",  enabled = true, speed = 1.21, bezier = "almostLinear", style = "fade" },
  { leaf = "workspacesOut", enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" },
  { leaf = "zoomFactor",    enabled = true, speed = 7,    bezier = "quick" },
}

for _, a in ipairs(animations) do hl.animation(a) end

----------------------
---- WINDOW RULES ----
----------------------

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

local mainMod    = "SUPER"
local superShift = mainMod .. " + SHIFT"
local superAlt   = mainMod .. " + ALT"

local function mod(suffix) return mainMod .. " + " .. suffix end
local function shift(suffix) return superShift .. " + " .. suffix end
local function alt(suffix) return superAlt .. " + " .. suffix end

local exec = hl.dsp.exec_cmd

local function osd(arg) return exec("swayosd-client " .. arg) end
local function brightness(arg) return exec("brightnessctl set " .. arg) end

hl.bind(mod("Return"), exec(terminal))
hl.bind(mod("C"), hl.dsp.window.close())
hl.bind(mod("M"), exec("command -v hyprshutdown >/dev/null 2>&1 && hyprshutdown || hyprctl dispatch 'hl.dsp.exit()'"))
hl.bind(mod("E"), exec(fileManager))
hl.bind(mod("V"), hl.dsp.window.float({ action = "toggle" }))
hl.bind(mod("space"), exec(menu))
hl.bind(alt("space"), exec(clipHistory))

hl.bind(mod("P"), hl.dsp.window.pseudo())
hl.bind(mod("T"), hl.dsp.layout("togglesplit"))

hl.bind(mod("B"), exec(browser))
hl.bind(mod("D"), exec(discord))
hl.bind(mod("S"), exec("steam"))
hl.bind(mod("Z"), exec("zapzap"))
hl.bind(shift("Z"), exec("Telegram"))
hl.bind(mod("A"), exec("claude-desktop --toggle"))
hl.bind(shift("B"), exec(btManager))
hl.bind(shift("W"), exec(wifiManager))
hl.bind(shift("I"), exec(termRun("btop")))
hl.bind(shift("M"), exec(termRun("maily")))
hl.bind(mod("W"), exec("pgrep -x waybar && killall waybar || waybar"))
hl.bind(mod("U"), exec("pavucontrol"))

hl.bind("F9", exec("pkill -SIGUSR1 albus"))
hl.bind("F9", exec("pkill -SIGUSR2 albus"), { release = true })

hl.bind("PRINT", exec("hyprshot -m window"))
hl.bind("SHIFT + PRINT", exec("hyprshot -m region"))
hl.bind(shift("L"), exec("hyprlock"))

hl.bind(shift("C"), exec("hyprpicker -a"))

hl.bind(mod("R"), exec("fish -c record"))

local directions = { H = "l", L = "r", K = "u", J = "d" }
for key, dir in pairs(directions) do
  hl.bind(mod(key), hl.dsp.focus({ direction = dir }))
end

local maxWorkspaces = 9
for i = 1, maxWorkspaces do
  hl.bind(mod(i), hl.dsp.focus({ workspace = i }))
  hl.bind(shift(i), hl.dsp.window.move({ workspace = i }))
end
hl.bind(mod(0), hl.dsp.focus({ workspace = 10 }))
hl.bind(shift(0), hl.dsp.window.move({ workspace = 10 }))

local specialWs = "magic"
hl.bind(mod("Tab"), hl.dsp.workspace.toggle_special(specialWs))
hl.bind(shift("Tab"), hl.dsp.window.move({ workspace = "special:" .. specialWs }))

hl.bind(mod("mouse_down"), hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mod("mouse_up"), hl.dsp.focus({ workspace = "e-1" }))

hl.bind(mod("mouse:272"), hl.dsp.window.drag(), { mouse = true })
hl.bind(mod("mouse:273"), hl.dsp.window.resize(), { mouse = true })

hl.bind("XF86AudioRaiseVolume", osd("--output-volume raise"), { repeating = true })
hl.bind("XF86AudioLowerVolume", osd("--output-volume lower"), { repeating = true })
hl.bind("XF86AudioMute", osd("--output-volume mute-toggle"), { locked = true })

hl.bind("XF86MonBrightnessUp", brightness("+5%"), { repeating = true })
hl.bind("XF86MonBrightnessDown", brightness("5%-"), { repeating = true })
