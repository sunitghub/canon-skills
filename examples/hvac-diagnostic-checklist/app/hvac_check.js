// hvac_check.js — the three diagnostic rules, on their own so the checker owns them exclusively.
//
// The exact rules are defined in ../specs/hvac-diagnostic.feature. This file must satisfy them;
// don't edit the spec to match the code.
//
// Each function takes the checklist's own paired bound/actual reading and returns
// { compliant, reason } — nothing here recites an HVAC fact the checklist didn't hand us.
// checkTolerance's tolerance is caller-supplied data, not a constant baked into the rule.

function checkBreaker(requiredAmps, installedAmps) {
  if (installedAmps < requiredAmps) {
    return { compliant: false, reason: "breaker undersized" };
  }
  return { compliant: true, reason: "breaker meets required rating" };
}

function checkRLA(maxRLA, actualRLA) {
  if (actualRLA > maxRLA) {
    return { compliant: false, reason: "actual RLA exceeds max rating" };
  }
  return { compliant: true, reason: "actual RLA within max rating" };
}

function checkTolerance(target, actual, tolerance) {
  const delta = Math.abs(actual - target);
  if (delta > tolerance) {
    return { compliant: false, reason: "actual outside tolerance of target" };
  }
  return { compliant: true, reason: "actual within tolerance of target" };
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { checkBreaker, checkRLA, checkTolerance };
}
