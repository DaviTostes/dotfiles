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

  QT_QPA_PLATFORMTHEME = "qt6ct",
}

for k, v in pairs(envs) do
  hl.env(k, v)
end

--------------------
---- MONITORS ----
--------------------

hl.monitor({ output = "DP-2", mode = "1920x1080@144", position = "0x0", scale = 1 })
hl.monitor({ output = "HDMI-A-1", mode = "1920x1080@75", position = "-1920x0", scale = 1 })

--------------------
---- AUTOSTART ----
--------------------

hl.on("hyprland.start", function()
  hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP")
  hl.exec_cmd("systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP")

  hl.exec_cmd("quickshell")
  hl.exec_cmd("hypridle")
  hl.exec_cmd("awww-daemon")
  hl.exec_cmd("$HOME/.config/hypr/scripts/wallpaper-apply")
  hl.exec_cmd("swayosd-server")
  hl.exec_cmd("wl-paste --watch cliphist store")
  hl.exec_cmd("goytn")
  hl.exec_cmd("maily")
  hl.exec_cmd("ksecretd")
  hl.exec_cmd("setsid -f $HOME/.local/bin/xembed-tray")

  -- DLNA renderer: auror announces this machine as a UPnP MediaRenderer and
  -- plays casts through mpv; the right bar's Auror pill drives it over its
  -- local HTTP API. Skip the spawn if one is already running.
  hl.exec_cmd("pgrep -x auror >/dev/null 2>&1 || setsid -f auror")
end)

--------------------
---- WORKSPACES ----
--------------------

-- local primaryMonitor   = "DP-2"
-- local secondaryMonitor = "HDMI-A-1"
--
-- hl.workspace_rule({ workspace = "2", monitor = primaryMonitor, default = false })
-- hl.workspace_rule({ workspace = "1", monitor = secondaryMonitor, default = true })

---------------------
---- MY PROGRAMS ----
---------------------

local terminal    = "kitty"
local fileManager = "pcmanfm"
local menu        = "qs ipc call launcher toggle"
local clipHistory = "qs ipc call clipboard toggle"
local browser     = "helium-browser"
local discord     = "vesktop"
local btManager   = "qs ipc call settings open bluetooth"
local wifiManager = "qs ipc call settings open wifi"
local vpnManager  = "qs ipc call settings open vpn"

local function termRun(cmd) return terminal .. " --title \"" .. cmd .. "\" " .. cmd end

-----------------------
---- LOOK AND FEEL ----
-----------------------

hl.config({
  general = {
    gaps_in          = 2,
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
    active_opacity   = 1,
    inactive_opacity = 1,
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

  dwindle = {
    preserve_split = true,
  },

  master = {
    new_status = "master",
  },

  misc = {
    force_default_wallpaper = -1,
    disable_hyprland_logo   = false,
    focus_on_activate       = true,
    -- VRR (FreeSync) fica DESLIGADO de propósito. Ligar so faz sentido com o
    -- VSync do jogo desligado, e o Classic Beta ignora `vsync "0"` no
    -- Config.wtf (ele sobrescreve de volta), entao a unica forma seria
    -- desligar pelo menu a cada sessao. Com VRR on + VSync on nao se ganha
    -- nenhum dos dois: o monitor nao varia a refresh (o jogo trava a
    -- apresentacao em 144) e o vsync segue julgando deadline normal.
    -- Para usar VRR de verdade: `vrr = 1` aqui + VSync off em Esc > Graficos,
    -- e ai os drops de vsync viram refresh variavel em vez de cair pra metade.
    vrr = 0,
  },

  cursor = {
    -- cursor por software (original desta maquina). Hardware cursor ocupa um
    -- plano no CRTC e atrapalha o direct scanout, o que custa frames num jogo
    -- que depende do caminho XWayland -> compositor. Medido como perda aqui,
    -- entao volta ao padrao.
    no_hardware_cursors = true,
  },

  xwayland = {
    force_zero_scaling = true,
  },
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
hl.animation({ leaf = "specialWorkspace", enabled = true, speed = 3, bezier = "default", style = "slidevert" })
hl.animation({ leaf = "zoomFactor", enabled = true, speed = 7, bezier = "quick" })

hl.device({
  name        = "epic-mouse-v1",
  sensitivity = -0.5,
})

----------------------
---- WINDOW RULES ----
----------------------

hl.window_rule({
  name   = "octo-launcher",
  match  = { title = "Octo Launcher" },
  float  = true,
  center = true,
  size   = { 1200, 800 }
})

hl.window_rule({
  name      = "magic-keep",
  match     = { class = "magic-keep" },
  workspace = "special:magic",
  no_focus  = true,
  float     = true,
  move      = { 10, 10 },
  size      = { 10, 10 },
})

hl.window_rule({
  name       = "wow-fullscreen",
  match      = { title = "World of Warcraft" },
  fullscreen = true,
  -- the bar, the lock screen and quickshell layers are layer-shell surfaces
  -- the compositor still has to process while the game is up. Skipping blur
  -- and the drop shadow for the game window keeps that work off the frame path.
  no_blur    = true,
  no_shadow  = true,
})

-- Proton Authenticator is a Tauri/WebKitGTK app whose tauri-plugin-window-state
-- restores the saved "maximized": true from ~/.config/me.proton.authenticator/
-- .window-state.json on every launch, so it opened filling the whole workspace
-- (hyprctl reports fullscreen=1 / the maximize state) and could not be tiled.
-- Ignore the maximize request; the app then maps as a normal tile.
hl.window_rule({
  name           = "proton-authenticator-no-maximize",
  match          = { class = "proton-authenticator" },
  suppress_event = "maximize",
})

-- kitty 0.49.1 sends xdg_toplevel.set_maximized on map even when started
-- with --start-as=normal: 'normal' and 'maximized' are indistinguishable, so
-- every new terminal swallows the whole work area and ignores the split
-- until it is dragged. There is no kitty.conf key for it (start_as is
-- CLI-only), so the fix has to live here. Side effect: double-click on
-- kitty's own titlebar can no longer maximize it.
hl.window_rule({
  name           = "kitty-no-maximize",
  match          = { class = "kitty" },
  suppress_event = "maximize",
})

local sideApps = { "warbler", "omm", "maily", "btop", "calc" }

for _, app in ipairs(sideApps) do
  hl.window_rule({
    name  = app,
    match = { title = app },
    float = true,
    move  = { 1086, 50 },
    size  = { 800, 1000 },
  })
end

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
hl.bind(shift("M"), exec("command -v hyprshutdown >/dev/null 2>&1 && hyprshutdown || hyprctl dispatch 'hl.dsp.exit()'"))
hl.bind(mod("E"), exec(fileManager))
hl.bind(mod("V"), hl.dsp.window.float({ action = "toggle" }))
hl.bind(mod("space"), exec(menu))
hl.bind(alt("space"), exec(clipHistory))

hl.bind(mod("P"), hl.dsp.window.pseudo())
hl.bind(mod("T"), hl.dsp.layout("togglesplit"))

hl.bind(mod("B"), exec(browser))
hl.bind(mod("D"), exec(discord))
hl.bind(mod("Z"), exec("zapfast"))
hl.bind(shift("Z"), exec("Telegram"))
hl.bind(shift("T"), exec("qs ipc call typetest toggle"))  -- desktop typing test on/off
hl.bind(shift("B"), exec(btManager))
hl.bind(shift("W"), exec(wifiManager))
hl.bind(shift("V"), exec(vpnManager))
hl.bind(mod("I"), exec(termRun("btop")))
hl.bind(mod("M"), exec(termRun("maily")))
hl.bind(mod("W"), exec("sh -c 'killall quickshell 2>/dev/null; sleep 0.5; setsid -f quickshell'"))
hl.bind(mod("U"), exec("pavucontrol"))
hl.bind(mod("N"), exec("qs ipc call notifs toggle"))    -- calendar + notifications panel
hl.bind(shift("N"), exec("qs ipc call notifs clear"))
hl.bind(shift("G"), exec("qs ipc call github toggle"))   -- GitHub PRs / actions panel

hl.bind(mod("A"), exec("qs ipc call opencode toggleExpanded"))
hl.bind(shift("A"), exec("qs ipc call opencode voice"))      -- docked (small) panel, straight into Voice Mode

hl.bind("PRINT", exec("hyprshot -m window"))
hl.bind("SHIFT + PRINT", exec("hyprshot -m region"))
hl.bind(shift("L"), exec("hyprlock"))

hl.bind(shift("C"), exec(termRun("calc")))

hl.bind(shift("R"), exec("fish -c record"))

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

-- 0.56.2's toggle_special dispatcher silently no-ops; the monitor methods
-- below are the working primitives (verified). An empty special workspace
-- cannot be created by any dispatcher, so the first SUPER+Tab parks a tiny
-- helper window on special:magic (created via the magic-keep rule) and the
-- workspace.created event then reveals it.
local specialWs   = "magic"
local magicPending = false

hl.on("workspace.created", function(ws)
  if magicPending and ws.name == "special:" .. specialWs then
    magicPending = false
    if ws.monitor then
      ws.monitor:set_special_workspace{ workspace = ws.name }
    end
  end
end)

hl.bind(mod("Tab"), function()
  local m = hl.get_active_monitor()
  if m.active_special_workspace then
    m:set_special_workspace{}
    return
  end
  local name = "special:" .. specialWs
  if hl.get_workspace(name) then
    m:set_special_workspace{ workspace = name }
  elseif not magicPending then
    magicPending = true
    hl.exec_cmd("kitty --class magic-keep -e sleep infinity")
  end
end)
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
