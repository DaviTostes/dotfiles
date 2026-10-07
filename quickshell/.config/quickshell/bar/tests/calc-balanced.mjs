// Regression tests for Calc.qml's `balanced()` guard — run with:
//   node bar/tests/calc-balanced.mjs   (from quickshell/.config/quickshell/)
//
// `balanced()` protects the persistent `calc` process from a line that would
// make it wait for more input forever (unterminated string / block comment /
// unmatched bracket). The function is pure JS embedded in QML, so it is
// extracted from the real source (not copied) and exercised here.

import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const src = readFileSync(new URL("../Calc.qml", import.meta.url), "utf8");

// Extract `function name(...) { ... }` from QML by brace matching, skipping
// strings, block comments and line comments so braces inside them do not
// confuse the count.
function extractFn(source, name) {
  const start = source.indexOf("function " + name + "(");
  if (start < 0) throw new Error("function " + name + " not found");
  let i = source.indexOf("{", start);
  let depth = 0, quote = "", inBlock = false;
  for (; i < source.length; i++) {
    const c = source[i], n = source[i + 1];
    if (inBlock) { if (c === "*" && n === "/") { inBlock = false; i++; } continue; }
    if (quote) { if (c === "\\") { i++; continue; } if (c === quote) quote = ""; continue; }
    if (c === '"' || c === "'") { quote = c; continue; }
    if (c === "/" && n === "*") { inBlock = true; i++; continue; }
    if (c === "/" && n === "/") { while (i < source.length && source[i] !== "\n") i++; continue; }
    if (c === "{") depth++;
    else if (c === "}") { depth--; if (depth === 0) { i++; break; } }
  }
  return source.slice(start, i);
}

const balanced = new Function("return (" + extractFn(src, "balanced") + ")")();

const cases = [
  // accepted (would run cleanly in calc)
  ["2 + 2", true],
  ["sqrt(2)", true],
  ["(1 + [2 * {3}])", true],
  ['print "(x)"', true],              // brackets inside a string are literal
  ['print "a */ b"', true],           // */ inside a string is literal
  ["2 /* ok */ + 3", true],           // a closed block comment is fine
  ["7 // 2", true],                   // // is integer division, not a comment
  ["x = 5", true],
  // rejected (would wedge the persistent process or misparse)
  ["2 /* oops", false],               // unterminated block comment
  ["print \"hi", false],              // unterminated string
  ["(1 + 2", false],                  // unmatched opener
  ["1 + 2)", false],                  // unmatched closer
  ["x = 1 \\", false],                // trailing line continuation
  ['print "a\\"', false],             // escaped quote, string still open
];

let pass = 0;
for (const [expr, want] of cases) {
  const got = balanced(expr);
  assert.equal(got, want, `balanced(${JSON.stringify(expr)}) → ${got}, want ${want}`);
  console.log(`ok   balanced(${JSON.stringify(expr)}) === ${want}`);
  pass++;
}
console.log(`\n${pass}/${cases.length} passed`);
