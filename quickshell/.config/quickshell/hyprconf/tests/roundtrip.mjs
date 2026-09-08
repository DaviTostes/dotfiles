// Round-trip tests for Conf.js — run with:
//   node hyprconf/tests/roundtrip.mjs   (from quickshell/.config/quickshell/)
//
// Conf.js is a QML .pragma library; the .pragma line is stripped and the
// body evaluated to get the same functions the panel uses.

import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const src = readFileSync(new URL("../Conf.js", import.meta.url), "utf8")
  .replace(/^\.pragma library\s*\n/, "");

const Conf = new Function(
  src
  + "\nreturn { parse, serialize, get, getRaw, set, getVar, setVar,"
  + " sectionBlocks, item, KV, SECTION_START, SECTION_END };"
)();

const samples = [
  { name: "simple", text: "splash = false\nipc = true\n" },
  {
    name: "hyprpaper-like",
    text: [
      "# managed by the quickshell hyprconf panel",
      "splash = false",
      "ipc = on",
      "",
      "wallpaper {",
      "    monitor = eDP-1",
      "    path = ~/Pictures/wall.png",
      "    fit_mode = cover",
      "}",
      "",
      "wallpaper {",
      "    monitor = DP-1",
      "    path = /mnt/share/bg.jpg",
      "}",
      "",
    ].join("\n"),
  },
  {
    name: "hypridle-like with vars",
    text: [
      "$lock = loginctl lock-session",
      "$dpms_on = hyprctl dispatch dpms on",
      "",
      "general {",
      "    lock_cmd = pidof hyprlock || hyprlock",  // raw line with spaces
      "    before_sleep_cmd = $lock",
      "}",
      "",
      "listener {",
      "    timeout = $lock_timeout",
      "    on-timeout = $lock",
      "}",
      "# trailing comment",
    ].join("\n"),
  },
  {
    name: "quotes and blanks",
    text: "\n\nlabel {\n    color = \"rgba(ffffffff)\"\n    font_family = \"Agave Nerd Font\"\n\n\n}\n",
  },
];

let failures = 0;

function test(name, fn) {
  try {
    fn();
    console.log("ok   " + name);
  } catch (e) {
    failures++;
    console.log("FAIL " + name + "\n     " + e.message);
  }
}

// 1. parse→serialize is idempotent: serialize(parse(serialize(parse(x)))) === serialize(parse(x))
for (const s of samples) {
  test("idempotent: " + s.name, () => {
    const once = Conf.serialize(Conf.parse(s.text));
    const twice = Conf.serialize(Conf.parse(once));
    assert.equal(twice, once);
  });
}

// 2. values survive a full round-trip untouched
for (const s of samples) {
  test("values survive: " + s.name, () => {
    const before = Conf.parse(s.text);
    const after = Conf.parse(Conf.serialize(before));
    assert.equal(Conf.serialize(after), Conf.serialize(before));
    assert.equal(Conf.get(after, "wallpaper", "monitor"), Conf.get(before, "wallpaper", "monitor"));
    assert.equal(Conf.get(after, "label", "color"), Conf.get(before, "label", "color"));
    assert.equal(Conf.getRaw(after, "general", "lock_cmd"), Conf.getRaw(before, "general", "lock_cmd"));
    assert.equal(Conf.getVar(after, "$lock"), Conf.getVar(before, "$lock"));
  });
}

// 3. set() edits round-trip and keep surrounding content
test("set/get round-trip", () => {
  const cfg = Conf.parse(samples[1].text);
  Conf.set(cfg, "wallpaper", "path", "~/Imagens/new.png");
  assert.equal(Conf.get(Conf.parse(Conf.serialize(cfg)), "wallpaper", "path"), "~/Imagens/new.png");
  // other blocks untouched
  assert.equal(Conf.get(Conf.parse(Conf.serialize(cfg)), "", "splash"), "false");
  // a fresh key lands in the right section
  Conf.set(cfg, "wallpaper", "fit_mode", "contain");
  const blocks = Conf.sectionBlocks(Conf.parse(Conf.serialize(cfg)), "wallpaper");
  assert.equal(blocks[0].find(kv => kv.key === "fit_mode").val, "contain");
  assert.equal(blocks.length, 2);
});

// 4. setVar() edits round-trip and listeners keep referencing the var
test("setVar round-trip", () => {
  const cfg = Conf.parse(samples[2].text);
  Conf.setVar(cfg, "$lock_timeout", "600");
  const out = Conf.serialize(cfg);
  assert.equal(Conf.getVar(Conf.parse(out), "$lock_timeout"), "600");
  assert.ok(out.includes("timeout = $lock_timeout"), "listener must keep the $var reference");
});

// 5. sectionBlocks resolves vars and counts blocks
test("sectionBlocks", () => {
  const blocks = Conf.sectionBlocks(Conf.parse(samples[1].text), "wallpaper");
  assert.equal(blocks.length, 2);
  assert.equal(blocks[0][0].key, "monitor");
});

process.exit(failures ? 1 : 0);
