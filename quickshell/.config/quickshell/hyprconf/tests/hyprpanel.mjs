// Round-trip & value survival tests for HyprPanel.js — run with:
//   node hyprconf/tests/hyprpanel.mjs   (from quickshell/.config/quickshell/)

import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const src = readFileSync(new URL("../HyprPanel.js", import.meta.url), "utf8")
  .replace(/^\.pragma library\s*\n/, "");

const HyprPanel = new Function(
  src + "\nreturn { defaultModel, parse, render };"
)();

const realLua = readFileSync(
  new URL("../../../../../hypr/.config/hypr/hyprpanel.lua", import.meta.url),
  "utf8"
);

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

test("idempotent on real hyprpanel.lua", () => {
  const m1 = HyprPanel.parse(realLua);
  assert.ok(m1 !== null, "parse returned null");
  const r1 = HyprPanel.render(m1);
  const m2 = HyprPanel.parse(r1);
  const r2 = HyprPanel.render(m2);
  assert.equal(r2, r1);
  assert.equal(r1, realLua);
});

test("values survive round-trip", () => {
  const m = HyprPanel.parse(realLua);
  assert.equal(m.monitors.length, 2);
  assert.equal(m.monitors[0].output, "DP-2");
  assert.equal(m.monitors[0].mode, "1920x1080@144");
  assert.equal(m.monitors[1].position, "-1920x0");
  assert.equal(m.general.gaps_in, 2);
  assert.equal(m.general.active_border, "rgba(60,60,60,1)");
  assert.equal(m.decoration.rounding, 8);
  assert.equal(m.decoration.shadow.color, "0xee1a1a1a");
  assert.equal(m.decoration.blur.vibrancy, 0.1696);
  assert.equal(m.animationsEnabled, true);
  assert.equal(m.input.kb_layout, "us");
  assert.equal(m.input.follow_mouse, 1);
  assert.equal(m.input.natural_scroll, false);
  assert.equal(m.curves.length, 5);
  assert.equal(m.animations.length, 18);
  assert.equal(m.animations[16].leaf, "specialWorkspace");
  assert.equal(m.animations[16].style, "slidevert");
  assert.equal(m.autostart.length, 13);
  assert.equal(m.autostart[2], "quickshell");
});

test("edits survive render -> parse", () => {
  const m = HyprPanel.parse(realLua);
  m.general.gaps_in = 6;
  m.general.gaps_out = 12;
  m.general.layout = "master";
  m.decoration.blur.enabled = false;
  m.input.kb_layout = "br";
  m.input.natural_scroll = true;
  m.animations[0].speed = 7.5;
  m.monitors.push({ output: "eDP-1", mode: "preferred", position: "auto", scale: "1.25" });
  m.autostart.push('notify-send "hello world"');

  const out = HyprPanel.render(m);
  const back = HyprPanel.parse(out);
  assert.equal(back.general.gaps_in, 6);
  assert.equal(back.general.gaps_out, 12);
  assert.equal(back.general.layout, "master");
  assert.equal(back.decoration.blur.enabled, false);
  assert.equal(back.input.kb_layout, "br");
  assert.equal(back.input.natural_scroll, true);
  assert.equal(back.animations[0].speed, 7.5);
  assert.equal(back.monitors.length, 3);
  assert.equal(back.monitors[2].scale, "1.25");
  assert.equal(back.autostart[back.autostart.length - 1], 'notify-send "hello world"');
});

test("empty input returns defaultModel; malformed non-empty returns null", () => {
  const d = HyprPanel.parse("");
  assert.ok(d !== null);
  assert.equal(d.general.gaps_in, 2);

  const bad = HyprPanel.parse("this is not a hyprpanel lua file = 123");
  assert.equal(bad, null);
});

process.exit(failures ? 1 : 0);
