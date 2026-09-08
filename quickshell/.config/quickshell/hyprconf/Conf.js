.pragma library

// Lossless Hyprland config parsing/editing — QML/JS port of ~/hyprconfig/confparse.go
//
// A config is a plain JS object: { items: [Item...], vars: {key: val} }.
// Editing mutates the item list in place, so comments / raw lines / untouched
// sections survive a save round-trip.

const BLANK = 0, COMMENT = 1, VAR = 2, KV = 3, SECTION_START = 4, SECTION_END = 5, RAW = 6;

function item(kind, text, key, val) {
    return { kind: kind, text: text || "", key: key || "", val: val || "" };
}

function splitKV(t) {
    const i = t.indexOf("=");
    if (i < 0) return null;
    return { key: t.slice(0, i).trim(), val: t.slice(i + 1).trim() };
}

function parse(text) {
    const cfg = { items: [], vars: {} };
    const lines = String(text).split("\n");
    // a trailing newline terminates the file — it is not a blank line,
    // otherwise every save round-trip would append a blank line
    if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const t = line.trim();
        if (t === "") { cfg.items.push(item(BLANK, line)); continue; }
        if (t.startsWith("#")) { cfg.items.push(item(COMMENT, line)); continue; }
        if (t.startsWith("$")) {
            const c = splitKV(t);
            if (c) { cfg.items.push(item(VAR, "", c.key, c.val)); cfg.vars[c.key] = c.val; }
            else cfg.items.push(item(RAW, line));
            continue;
        }
        if (t.endsWith("{")) { cfg.items.push(item(SECTION_START, t.slice(0, -1).trim())); continue; }
        if (t === "}") { cfg.items.push(item(SECTION_END, "}")); continue; }
        const c = splitKV(t);
        if (c) cfg.items.push(item(KV, "", c.key, c.val));
        else cfg.items.push(item(RAW, line));
    }
    return cfg;
}

const varRe = /\$[A-Za-z_][A-Za-z0-9_]*/g;

function resolve(cfg, v, depth) {
    if (depth > 8) return String(v);
    return String(v).replace(varRe, m => (m in cfg.vars) ? resolve(cfg, cfg.vars[m], depth + 1) : m);
}

function trimQuotes(s) {
    s = String(s);
    while (s.startsWith('"')) s = s.slice(1);
    while (s.endsWith('"')) s = s.slice(0, -1);
    return s;
}

// Get a KV, resolving $vars (like the Go Get).
function get(cfg, section, key, def) {
    let cur = "";
    for (const it of cfg.items) {
        if (it.kind === SECTION_START) cur = it.text;
        else if (it.kind === SECTION_END) cur = "";
        else if (it.kind === KV && cur === section && it.key === key)
            return trimQuotes(resolve(cfg, it.val, 0));
    }
    return def;
}

// Same as get() but without variable resolution (for commands you don't want
// to flatten into literals).
function getRaw(cfg, section, key, def) {
    let cur = "";
    for (const it of cfg.items) {
        if (it.kind === SECTION_START) cur = it.text;
        else if (it.kind === SECTION_END) cur = "";
        else if (it.kind === KV && cur === section && it.key === key) return trimQuotes(it.val);
    }
    return def;
}

// Set a KV inside a section; creates the entry at the end of the section (or
// appends top-level) if it does not exist yet.
function set(cfg, section, key, val) {
    let cur = "";
    let insertAt = -1;
    const items = cfg.items;
    for (let i = 0; i < items.length; i++) {
        const it = items[i];
        if (it.kind === SECTION_START) cur = it.text;
        else if (it.kind === SECTION_END) {
            if (cur === section && insertAt < 0) insertAt = i;
            cur = "";
        } else if (it.kind === KV && cur === section && it.key === key) {
            it.val = val;
            return;
        }
    }
    // Section not present: create it at the end of the file.
    if (section !== "") {
        items.push(item(SECTION_START, section));
        items.push(item(KV, "", key, val));
        items.push(item(SECTION_END, "}"));
        return;
    }
    items.push(item(KV, "", key, val));
}

function getVar(cfg, key, def) {
    if (key in cfg.vars) return trimQuotes(resolve(cfg, cfg.vars[key], 0));
    return def;
}

function setVar(cfg, key, val) {
    for (const it of cfg.items) {
        if (it.kind === VAR && it.key === key) { it.val = val; cfg.vars[key] = val; return; }
    }
    cfg.vars[key] = val;
    cfg.items.unshift(item(VAR, "", key, val));
}

// All blocks of a named section, e.g. every "wallpaper { ... }" — each block
// is an array of {key, val} with vars already resolved.
function sectionBlocks(cfg, name) {
    const out = [];
    let cur = "";
    let m = null;
    for (const it of cfg.items) {
        if (it.kind === SECTION_START) {
            cur = it.text;
            m = cur === name ? [] : null;
        } else if (it.kind === SECTION_END) {
            if (cur === name && m) { out.push(m); m = null; }
            cur = "";
        } else if (it.kind === KV && m && cur === name) {
            m.push({ key: it.key, val: resolve(cfg, it.val, 0) });
        }
    }
    return out;
}

function serialize(cfg) {
    let out = "";
    let depth = 0;
    let prevBlank = true;
    const gap = () => { if (!prevBlank) { out += "\n"; prevBlank = true; } };
    for (const it of cfg.items) {
        switch (it.kind) {
        case VAR:
            out += it.key + " = " + it.val + "\n";
            prevBlank = false;
            break;
        case KV:
            for (let d = 0; d < depth; d++) out += "    ";
            out += it.key + " = " + it.val + "\n";
            prevBlank = false;
            break;
        case SECTION_START:
            gap();
            out += it.text + " {\n";
            depth++;
            prevBlank = false;
            break;
        case SECTION_END:
            out += "}\n";
            depth--;
            prevBlank = false;
            break;
        case BLANK:
            gap();
            break;
        default:
            out += it.text + "\n";
            prevBlank = false;
            break;
        }
    }
    if (out !== "" && !out.endsWith("\n")) out += "\n";
    return out;
}

function toInt(s, def) {
    const v = parseInt(String(s).trim(), 10);
    return isNaN(v) ? def : v;
}

function toFloat(s, def) {
    const v = parseFloat(String(s).trim());
    return isNaN(v) ? def : v;
}

function parsePair(s) {
    const parts = String(s).split(",");
    if (parts.length !== 2) return { ok: false, x: 0, y: 0 };
    const x = parseFloat(parts[0].trim());
    const y = parseFloat(parts[1].trim());
    if (isNaN(x) || isNaN(y)) return { ok: false, x: 0, y: 0 };
    return { ok: true, x: x, y: y };
}

function fmtInt(v) { return String(Math.round(v)); }
function fmtFloat(v) { return String(v); }

// --- path helpers ---

function expandPath(p, home) {
    p = String(p).trim();
    if (p === "") return "";
    if (p === "~") return home;
    if (p.startsWith("~/")) return home + p.slice(1);
    return p;
}

function homeRel(p, home) {
    if (p.startsWith(home + "/")) return "~/" + p.slice(home.length + 1);
    return p;
}

function urlToPath(u) {
    let s = String(u);
    if (s.startsWith("file://")) s = decodeURIComponent(s.slice(7));
    return s;
}

function fileUrl(p, home) {
    const fp = expandPath(p, home);
    if (fp === "") return "";
    return encodeURI("file://" + fp).replace(/#/g, "%23");
}
