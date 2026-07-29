// dsl_runner.js — minimal Given/When/Then runner for app.js's apply_discount().
//
// The JavaScript twin of dsl_runner.py: same fixed-pattern step-matcher, same output,
// same exit-code contract — it just runs the browser app's function instead of a Python
// one. Not a general Gherkin engine: it recognizes only the exact step shapes used in
// specs/discount.feature. A step-matcher this size can be read end to end and trusted;
// pointing a free-text natural-language parser at live-edited spec text can't.
//
// Run:  node dsl_runner.js ../specs/discount.feature

const fs = require("fs");
const { apply_discount } = require("./app.js");

const GIVEN_TOTAL = /Given cart_total ([\d.]+)/;
const GIVEN_CODE = /And code "(\w+)"/;
const THEN_APPLIED = /Then applied is (true|false)/;
const THEN_TOTAL = /And final_total is ([\d.]+)/;
const THEN_REASON = /And reason is "([^"]+)"/;

function parseScenarios(text) {
  const scenarios = [];
  let current = null;
  for (const line of text.split(/\r?\n/)) {
    const s = line.trim();
    let m;
    if (s.startsWith("Scenario:")) {
      current = { name: s.slice("Scenario:".length).trim() };
      scenarios.push(current);
    } else if (current === null) {
      continue;
    } else if ((m = GIVEN_TOTAL.exec(s))) {
      current.total = parseFloat(m[1]);
    } else if ((m = GIVEN_CODE.exec(s))) {
      current.code = m[1];
    } else if ((m = THEN_APPLIED.exec(s))) {
      current.expect_applied = m[1] === "true";
    } else if ((m = THEN_TOTAL.exec(s))) {
      current.expect_total = parseFloat(m[1]);
    } else if ((m = THEN_REASON.exec(s))) {
      current.expect_reason = m[1];
    }
  }
  return scenarios;
}

function run(path) {
  let ok = true;
  const text = fs.readFileSync(path, "utf8");
  for (const sc of parseScenarios(text)) {
    const result = apply_discount(sc.total, sc.code);
    const problems = [];
    if (result.applied !== sc.expect_applied) {
      problems.push(`applied ${result.applied} != expected ${sc.expect_applied}`);
    }
    if ("expect_total" in sc && Math.abs((result.final_total ?? 0) - sc.expect_total) > 0.01) {
      problems.push(`final_total ${result.final_total} != expected ${sc.expect_total}`);
    }
    if ("expect_reason" in sc && result.reason !== sc.expect_reason) {
      problems.push(`reason ${JSON.stringify(result.reason)} != expected ${JSON.stringify(sc.expect_reason)}`);
    }
    const mark = problems.length === 0 ? "PASS" : "FAIL";
    console.log(`  [${mark}] ${sc.name}` + (problems.length ? ` -- ${problems.join("; ")}` : ""));
    ok = ok && problems.length === 0;
  }
  return ok;
}

const path = process.argv[2];
if (!path) {
  console.error("usage: node dsl_runner.js <path-to-.feature>");
  process.exit(2);
}
process.exit(run(path) ? 0 : 1);
