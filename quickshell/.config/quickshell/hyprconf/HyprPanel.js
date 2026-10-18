.pragma library

// Deterministic parser and renderer for ~/.config/hypr/hyprpanel.lua.
//
// The file is panel-owned and uses a fixed subset of the Hyprland Lua API:
//   - hl.monitor({ output = ..., mode = ..., position = ..., scale = ... })
//   - hl.config({ general = {...}, decoration = {...}, animations = {...}, input = {...} })
//   - hl.curve(name, { type = "bezier", points = { { x1, y1 }, { x2, y2 } } })
//   - hl.animation({ leaf = ..., enabled = ..., speed = ..., bezier = ..., style = ... })
//   - hl.on("hyprland.start", function() hl.exec_cmd(...) ... end)

function defaultModel() {
    return {
        monitors: [
            { output: "DP-2", mode: "1920x1080@144", position: "0x0", scale: "1" },
            { output: "HDMI-A-1", mode: "1920x1080@75", position: "-1920x0", scale: "1" }
        ],
        general: {
            gaps_in: 2,
            gaps_out: 2,
            border_size: 2,
            active_border: "rgba(60,60,60,1)",
            inactive_border: "rgba(32,32,32,1)",
            resize_on_border: false,
            allow_tearing: false,
            layout: "dwindle"
        },
        decoration: {
            rounding: 8,
            rounding_power: 2,
            active_opacity: 1,
            inactive_opacity: 1,
            shadow: {
                enabled: true,
                range: 4,
                render_power: 3,
                color: "0xee1a1a1a"
            },
            blur: {
                enabled: true,
                size: 3,
                passes: 1,
                vibrancy: 0.1696
            }
        },
        animationsEnabled: true,
        input: {
            kb_layout: "us",
            kb_variant: "",
            kb_model: "",
            kb_options: "",
            kb_rules: "",
            follow_mouse: 1,
            sensitivity: 0,
            natural_scroll: false
        },
        curves: [
            { name: "easeOutQuint", spec: "{ type = \"bezier\", points = { { 0.23, 1 }, { 0.32, 1 } } }" },
            { name: "easeInOutCubic", spec: "{ type = \"bezier\", points = { { 0.65, 0.05 }, { 0.36, 1 } } }" },
            { name: "linear", spec: "{ type = \"bezier\", points = { { 0, 0 }, { 1, 1 } } }" },
            { name: "almostLinear", spec: "{ type = \"bezier\", points = { { 0.5, 0.5 }, { 0.75, 1 } } }" },
            { name: "quick", spec: "{ type = \"bezier\", points = { { 0.15, 0 }, { 0.1, 1 } } }" }
        ],
        animations: [
            { leaf: "global", enabled: true, speed: 10, bezier: "default", style: "" },
            { leaf: "border", enabled: true, speed: 5.39, bezier: "easeOutQuint", style: "" },
            { leaf: "windows", enabled: true, speed: 4.79, bezier: "easeOutQuint", style: "" },
            { leaf: "windowsIn", enabled: true, speed: 4.1, bezier: "easeOutQuint", style: "popin 87%" },
            { leaf: "windowsOut", enabled: true, speed: 1.49, bezier: "linear", style: "popin 87%" },
            { leaf: "fadeIn", enabled: true, speed: 1.73, bezier: "almostLinear", style: "" },
            { leaf: "fadeOut", enabled: true, speed: 1.46, bezier: "almostLinear", style: "" },
            { leaf: "fade", enabled: true, speed: 3.03, bezier: "quick", style: "" },
            { leaf: "layers", enabled: true, speed: 3.81, bezier: "easeOutQuint", style: "" },
            { leaf: "layersIn", enabled: true, speed: 4, bezier: "easeOutQuint", style: "fade" },
            { leaf: "layersOut", enabled: true, speed: 1.5, bezier: "linear", style: "fade" },
            { leaf: "fadeLayersIn", enabled: true, speed: 1.79, bezier: "almostLinear", style: "" },
            { leaf: "fadeLayersOut", enabled: true, speed: 1.39, bezier: "almostLinear", style: "" },
            { leaf: "workspaces", enabled: true, speed: 1.94, bezier: "almostLinear", style: "fade" },
            { leaf: "workspacesIn", enabled: true, speed: 1.21, bezier: "almostLinear", style: "fade" },
            { leaf: "workspacesOut", enabled: true, speed: 1.94, bezier: "almostLinear", style: "fade" },
            { leaf: "specialWorkspace", enabled: true, speed: 3, bezier: "default", style: "slidevert" },
            { leaf: "zoomFactor", enabled: true, speed: 7, bezier: "quick", style: "" }
        ],
        autostart: [
            "dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP",
            "systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP",
            "quickshell",
            "hypridle",
            "awww-daemon",
            "$HOME/.config/hypr/scripts/wallpaper-apply",
            "swayosd-server",
            "wl-paste --watch cliphist store",
            "ollama serve",
            "goytn",
            "maily",
            "ksecretd",
            "setsid -f $HOME/.local/bin/xembed-tray"
        ]
    };
}

function unescapeLuaStr(s) {
    s = String(s).trim();
    if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
        s = s.slice(1, -1);
    }
    return s.replace(/\\(["'\\nrt])/g, (_, c) => {
        if (c === "n") return "\n";
        if (c === "r") return "\r";
        if (c === "t") return "\t";
        return c;
    });
}

function escapeLuaStr(s) {
    return '"' + String(s === undefined || s === null ? "" : s)
        .replace(/\\/g, "\\\\")
        .replace(/"/g, '\\"')
        .replace(/\n/g, "\\n")
        .replace(/\r/g, "\\r")
        .replace(/\t/g, "\\t") + '"';
}

function fmtNum(v, def) {
    const n = Number(v);
    if (isNaN(n)) return String(def !== undefined ? def : 0);
    return String(n);
}

function fmtBool(v) {
    return v ? "true" : "false";
}

function fmtScale(s) {
    const t = String(s === undefined || s === null ? "1" : s).trim();
    if (t === "") return "1";
    const n = Number(t);
    if (!isNaN(n) && /^[-+]?\d+(\.\d+)?$/.test(t)) return String(n);
    return escapeLuaStr(t);
}

function fmtColorOrHex(s) {
    const t = String(s === undefined || s === null ? "" : s).trim();
    if (/^0x[0-9a-fA-F]+$/.test(t)) return t;
    return escapeLuaStr(t);
}

// Parse flat `key = value` pairs inside a one-line `{ ... }` table literal.
function parseInlineFields(inner) {
    const out = {};
    const re = /([A-Za-z_][A-Za-z0-9_]*)\s*=\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^,}]+)/g;
    let m;
    while ((m = re.exec(inner)) !== null) {
        const k = m[1];
        const raw = m[2].trim();
        out[k] = unescapeLuaStr(raw);
    }
    return out;
}

function parseBool(v, def) {
    if (v === "true" || v === true) return true;
    if (v === "false" || v === false) return false;
    return def;
}

function parseNum(v, def) {
    const n = parseFloat(String(v));
    return isNaN(n) ? def : n;
}

// Parses ~/.config/hypr/hyprpanel.lua into a structured model.
// Returns null if the text is non-empty and cannot be recognized as a valid
// panel file (protects against overwriting a broken/corrupted file).
function parse(text) {
    const raw = String(text === undefined || text === null ? "" : text);
    if (raw.trim() === "") return defaultModel();

    if (!/\bhl\.(monitor|config|curve|animation|on)\b/.test(raw)) {
        return null;
    }

    // Strip full-line and trailing comments outside strings for block scanning.
    const model = defaultModel();
    const monitors = [];
    const curves = [];
    const animations = [];
    const autostart = [];

    // 1. Monitors: hl.monitor({ ... })
    const monRe = /hl\.monitor\s*\(\s*\{([^}]*)\}\s*\)/g;
    let m;
    while ((m = monRe.exec(raw)) !== null) {
        const f = parseInlineFields(m[1]);
        monitors.push({
            output: f.output !== undefined ? f.output : "",
            mode: f.mode !== undefined ? f.mode : "preferred",
            position: f.position !== undefined ? f.position : "auto",
            scale: f.scale !== undefined ? String(f.scale) : "1"
        });
    }
    if (monitors.length > 0 || !/hl\.monitor/.test(raw)) {
        model.monitors = monitors;
    }

    // 2. Curves: hl.curve("name", { ... })
    const curveRe = /hl\.curve\s*\(\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')\s*,\s*(\{[\s\S]*?\})\s*\)/g;
    while ((m = curveRe.exec(raw)) !== null) {
        curves.push({
            name: unescapeLuaStr(m[1]),
            spec: m[2].replace(/\s+/g, " ").trim()
        });
    }
    if (curves.length > 0) {
        model.curves = curves;
    }

    // 3. Animations: hl.animation({ ... })
    const animRe = /hl\.animation\s*\(\s*\{([^}]*)\}\s*\)/g;
    while ((m = animRe.exec(raw)) !== null) {
        const f = parseInlineFields(m[1]);
        if (!f.leaf) continue;
        animations.push({
            leaf: f.leaf,
            enabled: parseBool(f.enabled, true),
            speed: parseNum(f.speed, 1),
            bezier: f.bezier !== undefined ? f.bezier : (f.spring !== undefined ? f.spring : "default"),
            style: f.style !== undefined ? f.style : ""
        });
    }
    if (animations.length > 0) {
        model.animations = animations;
    }

    // 4. Autostart: hl.on("hyprland.start", function() ... end)
    const startBlockRe = /hl\.on\s*\(\s*["']hyprland\.start["']\s*,\s*function\s*\([^)]*\)([\s\S]*?)end\s*\)/m;
    const sb = startBlockRe.exec(raw);
    if (sb) {
        const execRe = /hl\.exec_cmd\s*\(\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')\s*\)/g;
        let em;
        while ((em = execRe.exec(sb[1])) !== null) {
            autostart.push(unescapeLuaStr(em[1]));
        }
        model.autostart = autostart;
    }

    // 5. hl.config({ ... }) — walk brace stack with path tracking
    const cfgStart = raw.search(/hl\.config\s*\(\s*\{/);
    if (cfgStart >= 0) {
        const braceIdx = raw.indexOf("{", cfgStart);
        let depth = 0;
        let endIdx = -1;
        for (let i = braceIdx; i < raw.length; i++) {
            const ch = raw[i];
            if (ch === '"' || ch === "'") {
                const q = ch;
                i++;
                while (i < raw.length && raw[i] !== q) {
                    if (raw[i] === "\\") i++;
                    i++;
                }
                continue;
            }
            if (ch === "{") depth++;
            else if (ch === "}") {
                depth--;
                if (depth === 0) { endIdx = i; break; }
            }
        }
        if (endIdx > braceIdx) {
            const body = raw.slice(braceIdx + 1, endIdx);
            const path = [];
            const lines = body.split("\n");
            for (let li = 0; li < lines.length; li++) {
                // strip comment outside quotes
                let line = lines[li];
                let clean = "";
                for (let ci = 0; ci < line.length; ci++) {
                    const c = line[ci];
                    if (c === '"' || c === "'") {
                        const q = c;
                        clean += c;
                        ci++;
                        while (ci < line.length && line[ci] !== q) {
                            if (line[ci] === "\\") { clean += line[ci++]; }
                            if (ci < line.length) clean += line[ci];
                            ci++;
                        }
                        if (ci < line.length) clean += line[ci];
                        continue;
                    }
                    if (c === "-" && line[ci + 1] === "-") break;
                    clean += c;
                }
                const t = clean.trim();
                if (t === "") continue;

                // One-line nested table e.g. `shadow = { enabled = true, ... },`
                const inlineSub = /^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{([^{}]*)\}\s*,?$/.exec(t);
                if (inlineSub) {
                    const subName = inlineSub[1];
                    const subFields = parseInlineFields(inlineSub[2]);
                    const fullPrefix = path.concat([subName]).join(".");
                    for (const k in subFields) {
                        applyConfigKV(model, fullPrefix + "." + k, subFields[k]);
                    }
                    continue;
                }

                // Multi-line table open: `general = {`
                const openSub = /^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{\s*$/.exec(t);
                if (openSub) {
                    path.push(openSub[1]);
                    continue;
                }

                // Table close: `},` or `}`
                if (/^\}\s*,?$/.test(t)) {
                    path.pop();
                    continue;
                }

                // Scalar key = val
                const kv = /^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*,?$/.exec(t);
                if (kv) {
                    const fullKey = path.concat([kv[1]]).join(".");
                    applyConfigKV(model, fullKey, unescapeLuaStr(kv[2].replace(/,\s*$/, "").trim()));
                }
            }
        }
    }

    return model;
}

function applyConfigKV(model, key, val) {
    switch (key) {
    case "general.gaps_in": model.general.gaps_in = parseNum(val, 2); break;
    case "general.gaps_out": model.general.gaps_out = parseNum(val, 2); break;
    case "general.border_size": model.general.border_size = parseNum(val, 2); break;
    case "general.col.active_border": model.general.active_border = val; break;
    case "general.col.inactive_border": model.general.inactive_border = val; break;
    case "general.resize_on_border": model.general.resize_on_border = parseBool(val, false); break;
    case "general.allow_tearing": model.general.allow_tearing = parseBool(val, false); break;
    case "general.layout": model.general.layout = val; break;

    case "decoration.rounding": model.decoration.rounding = parseNum(val, 8); break;
    case "decoration.rounding_power": model.decoration.rounding_power = parseNum(val, 2); break;
    case "decoration.active_opacity": model.decoration.active_opacity = parseNum(val, 1); break;
    case "decoration.inactive_opacity": model.decoration.inactive_opacity = parseNum(val, 1); break;
    case "decoration.shadow.enabled": model.decoration.shadow.enabled = parseBool(val, true); break;
    case "decoration.shadow.range": model.decoration.shadow.range = parseNum(val, 4); break;
    case "decoration.shadow.render_power": model.decoration.shadow.render_power = parseNum(val, 3); break;
    case "decoration.shadow.color": model.decoration.shadow.color = val; break;
    case "decoration.blur.enabled": model.decoration.blur.enabled = parseBool(val, true); break;
    case "decoration.blur.size": model.decoration.blur.size = parseNum(val, 3); break;
    case "decoration.blur.passes": model.decoration.blur.passes = parseNum(val, 1); break;
    case "decoration.blur.vibrancy": model.decoration.blur.vibrancy = parseNum(val, 0.1696); break;

    case "animations.enabled": model.animationsEnabled = parseBool(val, true); break;

    case "input.kb_layout": model.input.kb_layout = val; break;
    case "input.kb_variant": model.input.kb_variant = val; break;
    case "input.kb_model": model.input.kb_model = val; break;
    case "input.kb_options": model.input.kb_options = val; break;
    case "input.kb_rules": model.input.kb_rules = val; break;
    case "input.follow_mouse": model.input.follow_mouse = parseNum(val, 1); break;
    case "input.sensitivity": model.input.sensitivity = parseNum(val, 0); break;
    case "input.touchpad.natural_scroll": model.input.natural_scroll = parseBool(val, false); break;
    }
}

function render(model) {
    const m = model || defaultModel();
    const g = m.general || defaultModel().general;
    const d = m.decoration || defaultModel().decoration;
    const sh = d.shadow || defaultModel().decoration.shadow;
    const bl = d.blur || defaultModel().decoration.blur;
    const inp = m.input || defaultModel().input;
    const mons = m.monitors || [];
    const curves = m.curves || [];
    const anims = m.animations || [];
    const autoList = m.autostart || [];

    const out = [];
    out.push("-- Generated by the quickshell Hypr Config panel. Manual edits may be overwritten.");
    out.push("");
    out.push("--------------------");
    out.push("---- MONITORS ----");
    out.push("--------------------");
    out.push("");
    for (let i = 0; i < mons.length; i++) {
        const mon = mons[i];
        out.push(
            "hl.monitor({ output = " + escapeLuaStr(mon.output || "")
            + ", mode = " + escapeLuaStr(mon.mode || "preferred")
            + ", position = " + escapeLuaStr(mon.position || "auto")
            + ", scale = " + fmtScale(mon.scale) + " })"
        );
    }

    out.push("");
    out.push("-----------------------");
    out.push("---- LOOK AND FEEL ----");
    out.push("-----------------------");
    out.push("");
    out.push("hl.config({");
    out.push("  general = {");
    out.push("    gaps_in          = " + fmtNum(g.gaps_in, 2) + ",");
    out.push("    gaps_out         = " + fmtNum(g.gaps_out, 2) + ",");
    out.push("    border_size      = " + fmtNum(g.border_size, 2) + ",");
    out.push("    col              = {");
    out.push("      active_border   = " + escapeLuaStr(g.active_border) + ",");
    out.push("      inactive_border = " + escapeLuaStr(g.inactive_border) + ",");
    out.push("    },");
    out.push("    resize_on_border = " + fmtBool(g.resize_on_border) + ",");
    out.push("    allow_tearing    = " + fmtBool(g.allow_tearing) + ",");
    out.push("    layout           = " + escapeLuaStr(g.layout || "dwindle") + ",");
    out.push("  },");
    out.push("");
    out.push("  decoration = {");
    out.push("    rounding         = " + fmtNum(d.rounding, 8) + ",");
    out.push("    rounding_power   = " + fmtNum(d.rounding_power, 2) + ",");
    out.push("    active_opacity   = " + fmtNum(d.active_opacity, 1) + ",");
    out.push("    inactive_opacity = " + fmtNum(d.inactive_opacity, 1) + ",");
    out.push("    shadow           = {");
    out.push("      enabled      = " + fmtBool(sh.enabled) + ",");
    out.push("      range        = " + fmtNum(sh.range, 4) + ",");
    out.push("      render_power = " + fmtNum(sh.render_power, 3) + ",");
    out.push("      color        = " + fmtColorOrHex(sh.color) + ",");
    out.push("    },");
    out.push("    blur             = {");
    out.push("      enabled  = " + fmtBool(bl.enabled) + ",");
    out.push("      size     = " + fmtNum(bl.size, 3) + ",");
    out.push("      passes   = " + fmtNum(bl.passes, 1) + ",");
    out.push("      vibrancy = " + fmtNum(bl.vibrancy, 0.1696) + ",");
    out.push("    },");
    out.push("  },");
    out.push("");
    out.push("  animations = {");
    out.push("    enabled = " + fmtBool(m.animationsEnabled) + ",");
    out.push("  },");
    out.push("");
    out.push("  input = {");
    out.push("    kb_layout    = " + escapeLuaStr(inp.kb_layout) + ",");
    out.push("    kb_variant   = " + escapeLuaStr(inp.kb_variant) + ",");
    out.push("    kb_model     = " + escapeLuaStr(inp.kb_model) + ",");
    out.push("    kb_options   = " + escapeLuaStr(inp.kb_options) + ",");
    out.push("    kb_rules     = " + escapeLuaStr(inp.kb_rules) + ",");
    out.push("    follow_mouse = " + fmtNum(inp.follow_mouse, 1) + ",");
    out.push("    sensitivity  = " + fmtNum(inp.sensitivity, 0) + ",");
    out.push("    touchpad     = {");
    out.push("      natural_scroll = " + fmtBool(inp.natural_scroll) + ",");
    out.push("    },");
    out.push("  },");
    out.push("})");

    out.push("");
    out.push("--------------------");
    out.push("---- ANIMATIONS ----");
    out.push("--------------------");
    out.push("");
    for (let i = 0; i < curves.length; i++) {
        const c = curves[i];
        out.push("hl.curve(" + escapeLuaStr(c.name) + ", " + c.spec + ")");
    }
    if (curves.length > 0 && anims.length > 0) out.push("");
    for (let i = 0; i < anims.length; i++) {
        const a = anims[i];
        let line = "hl.animation({ leaf = " + escapeLuaStr(a.leaf)
            + ", enabled = " + fmtBool(a.enabled)
            + ", speed = " + fmtNum(a.speed, 1)
            + ", bezier = " + escapeLuaStr(a.bezier || "default");
        if (a.style && String(a.style).trim() !== "") {
            line += ", style = " + escapeLuaStr(a.style);
        }
        line += " })";
        out.push(line);
    }

    out.push("");
    out.push("-------------------");
    out.push("---- AUTOSTART ----");
    out.push("-------------------");
    out.push("");
    out.push("hl.on(\"hyprland.start\", function()");
    for (let i = 0; i < autoList.length; i++) {
        out.push("  hl.exec_cmd(" + escapeLuaStr(autoList[i]) + ")");
    }
    out.push("end)");
    out.push("");

    return out.join("\n");
}
