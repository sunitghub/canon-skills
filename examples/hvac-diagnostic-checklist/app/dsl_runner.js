// dsl_runner.js — minimal Given/When/Then runner for hvac_check.js's three rules.
//
// Not a general Gherkin engine — it recognizes only the exact step shapes used in
// specs/hvac-diagnostic.feature (breaker / RLA / tolerance). A matcher this size can be read
// end to end and trusted; a free-text natural-language parser can't.
//
// Two modes:
//   Check the scenarios (this is the BDD gate — fixed inputs, expected outputs, PASS/FAIL):
//     node dsl_runner.js ../specs/hvac-diagnostic.feature
//       → one line per scenario: `Scenario: <name>, Verdict: PASS|FAIL, Reason: <reason>`
//         (exits 0, or 1 on any FAIL with the exact mismatch appended)
//   Try one rule on ad-hoc input (compute only — NOT a pass/fail check):
//     node dsl_runner.js breaker <required_amps> <installed_amps>
//     node dsl_runner.js rla <max_rla> <actual_rla>
//     node dsl_runner.js tolerance <target> <actual> <tolerance>

const fs = require("fs");
const { checkBreaker, checkRLA, checkTolerance } = require("./hvac_check.js");

const GIVEN_REQUIRED = /Given required_amps ([\d.]+)/;
const GIVEN_INSTALLED = /And installed_amps ([\d.]+)/;
const GIVEN_MAX_RLA = /Given max_rla ([\d.]+)/;
const GIVEN_ACTUAL_RLA = /And actual_rla ([\d.]+)/;
const GIVEN_TARGET = /Given target ([\d.]+)/;
const GIVEN_ACTUAL = /And actual ([\d.]+)/;
const GIVEN_TOLERANCE = /And tolerance ([\d.]+)/;
const THEN_COMPLIANT = /Then compliant is (true|false)/;
const THEN_REASON = /And reason is "([^"]+)"/;

function parseScenarios(text) {
  const scenarios = [];
  let current = null;
  for (const line of text.split(/\r?\n/)) {
    const s = line.trim();
    let m;
    if (s.startsWith("#")) {
      continue; // comment line — never starts a scenario or sets a field
    }
    if (s.startsWith("Scenario:")) {
      current = { name: s.slice("Scenario:".length).trim() };
      scenarios.push(current);
    } else if (current === null) {
      continue;
    } else if ((m = GIVEN_REQUIRED.exec(s))) {
      current.required_amps = parseFloat(m[1]);
    } else if ((m = GIVEN_INSTALLED.exec(s))) {
      current.installed_amps = parseFloat(m[1]);
    } else if ((m = GIVEN_MAX_RLA.exec(s))) {
      current.max_rla = parseFloat(m[1]);
    } else if ((m = GIVEN_ACTUAL_RLA.exec(s))) {
      current.actual_rla = parseFloat(m[1]);
    } else if ((m = GIVEN_TARGET.exec(s))) {
      current.target = parseFloat(m[1]);
    } else if ((m = GIVEN_ACTUAL.exec(s))) {
      current.actual = parseFloat(m[1]);
    } else if ((m = GIVEN_TOLERANCE.exec(s))) {
      current.tolerance = parseFloat(m[1]);
    } else if ((m = THEN_COMPLIANT.exec(s))) {
      current.expect_compliant = m[1] === "true";
    } else if ((m = THEN_REASON.exec(s))) {
      current.expect_reason = m[1];
    }
  }
  return scenarios;
}

// Which rule a scenario exercises is determined by which Given fields it set — the three
// shapes never overlap in the source spec.
function runRule(sc) {
  if ("required_amps" in sc) {
    return checkBreaker(sc.required_amps, sc.installed_amps);
  }
  if ("max_rla" in sc) {
    return checkRLA(sc.max_rla, sc.actual_rla);
  }
  if ("target" in sc) {
    return checkTolerance(sc.target, sc.actual, sc.tolerance);
  }
  throw new Error(`scenario "${sc.name}" matches no known step shape`);
}

// Mode 1 — run the scenarios, print one verdict line per scenario, return overall ok.
function runScenarios(path) {
  let ok = true;
  const text = fs.readFileSync(path, "utf8");
  for (const sc of parseScenarios(text)) {
    const result = runRule(sc);
    const problems = [];
    if (result.compliant !== sc.expect_compliant) {
      problems.push(`compliant ${result.compliant} != expected ${sc.expect_compliant}`);
    }
    if ("expect_reason" in sc && result.reason !== sc.expect_reason) {
      problems.push(`reason ${JSON.stringify(result.reason)} != expected ${JSON.stringify(sc.expect_reason)}`);
    }
    const verdict = problems.length === 0 ? "PASS" : "FAIL";
    const line = `Scenario: ${sc.name}, Verdict: ${verdict}, Reason: ${result.reason ?? ""}`;
    console.log(line + (problems.length ? ` -- ${problems.join("; ")}` : ""));
    ok = ok && problems.length === 0;
  }
  return ok;
}

// Mode 2 — compute one rule for ad-hoc input (no pass/fail; there's no expectation).
function tryOne(kind, args) {
  let r, inputs;
  if (kind === "breaker") {
    const [required, installed] = args.map(Number);
    r = checkBreaker(required, installed);
    inputs = { required_amps: required, installed_amps: installed };
  } else if (kind === "rla") {
    const [max, actual] = args.map(Number);
    r = checkRLA(max, actual);
    inputs = { max_rla: max, actual_rla: actual };
  } else if (kind === "tolerance") {
    const [target, actual, tolerance] = args.map(Number);
    r = checkTolerance(target, actual, tolerance);
    inputs = { target, actual, tolerance };
  } else {
    throw new Error(`unknown rule "${kind}"`);
  }
  for (const [k, v] of Object.entries(inputs)) {
    console.log(`  ${k}:`.padEnd(20) + v);
  }
  console.log(`  compliant:`.padEnd(20) + r.compliant);
  console.log(`  reason:`.padEnd(20) + r.reason);
}

const USAGE =
  "usage: node dsl_runner.js <path-to.feature>                     # check scenarios (PASS/FAIL)\n" +
  "       node dsl_runner.js breaker <required_amps> <installed_amps>\n" +
  "       node dsl_runner.js rla <max_rla> <actual_rla>\n" +
  "       node dsl_runner.js tolerance <target> <actual> <tolerance>";

const arg = process.argv[2];
if (!arg) {
  console.error(USAGE);
  process.exit(2);
}

if (arg.endsWith(".feature")) {
  process.exit(runScenarios(arg) ? 0 : 1);
} else if (["breaker", "rla", "tolerance"].includes(arg)) {
  tryOne(arg, process.argv.slice(3));
  process.exit(0);
} else {
  console.error(USAGE);
  process.exit(2);
}
