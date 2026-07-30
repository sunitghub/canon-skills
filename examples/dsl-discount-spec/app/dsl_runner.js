// dsl_runner.js — minimal Given/When/Then runner for discount.js's apply_discount().
//
// The JavaScript twin of dsl_runner.py: same fixed-pattern step-matcher, same per-scenario
// verdict output, same exit-code contract. Not a general Gherkin engine — it recognizes only the
// exact step shapes used in specs/discount.feature. A matcher this size can be read end to end and
// trusted; a free-text natural-language parser can't.
//
// Two modes:
//   Check the scenarios (this is the BDD gate — fixed inputs, expected outputs, PASS/FAIL):
//     node dsl_runner.js ../specs/discount.feature
//       → one line per scenario: `Amount: <n>, Code: <code>, Verdict: PASS|FAIL, Reason: <reason>`
//         (exits 0, or 1 on any FAIL with the exact mismatch appended)
//   Try the rule on ad-hoc input (compute only — NOT a pass/fail check):
//     node dsl_runner.js 120 SAVE20                      → prints applied / final_total / reason

const fs = require("fs");
const { apply_discount } = require("./discount.js");

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
    if (s.startsWith("#")) {
      continue; // comment line — never starts a scenario or sets a field (t-b878)
    }
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

// Whole numbers without a trailing .0 (120, not 120.0); decimals otherwise. Mirrors
// dsl_runner.py's _fmt_amount so both runners print identical Amount values.
function fmtAmount(n) {
  return String(n); // JS Number already prints whole numbers without a trailing .0
}

// Mode 1 — run the scenarios, print one projected line per scenario, return overall ok.
// Line format: `Amount: <n>, Code: <code>, Verdict: PASS|FAIL, Reason: <result.reason>`
// (on FAIL the exact mismatch is appended). Fallback for scenarios whose fields don't
// project cleanly onto these columns: print the scenario name + PASS/FAIL.
function runScenarios(path) {
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
    const verdict = problems.length === 0 ? "PASS" : "FAIL";
    const line =
      `Amount: ${fmtAmount(sc.total)}, Code: ${sc.code}, ` +
      `Verdict: ${verdict}, Reason: ${result.reason ?? ""}`;
    console.log(line + (problems.length ? ` -- ${problems.join("; ")}` : ""));
    ok = ok && problems.length === 0;
  }
  return ok;
}

// Mode 2 — compute the rule for one ad-hoc amount + code (no pass/fail; there's no expectation).
function tryOne(amount, code) {
  const r = apply_discount(amount, code);
  console.log(`  amount:           ${amount}`);
  console.log(`  code:             ${code}`);
  console.log(`  applied:          ${r.applied}`);
  console.log(`  final_total:      ${r.final_total}`);
  console.log(`  reason:           ${r.reason}`);
}

const USAGE = "usage: node dsl_runner.js <path-to.feature>   # check scenarios (PASS/FAIL)\n" +
  "       node dsl_runner.js <amount> <code>       # try the rule on one input";

const arg = process.argv[2];
if (!arg) {
  console.error(USAGE);
  process.exit(2);
}

if (arg.endsWith(".feature")) {
  process.exit(runScenarios(arg) ? 0 : 1);
} else {
  const amount = parseFloat(arg);
  const code = process.argv[3];
  if (Number.isNaN(amount) || !code) {
    console.error(USAGE);
    process.exit(2);
  }
  tryOne(amount, code);
  process.exit(0);
}
