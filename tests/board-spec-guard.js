#!/usr/bin/env node
// board-spec-guard — t-4469. Reads Playwright JSON reports from tests/run-board-spec.sh (one file per browser and run,
// named board-spec-<browser>-run<N>.json), classifies each test per browser as passing, flaky (failed in some runs) or
// failing (failed in every run), and checks the result against tests/board-spec-baseline.json and the QUARANTINE markers
// in the spec. Exit 1 on any violation. Usage:
//   node tests/board-spec-guard.js [--baseline FILE] [--spec FILE] [--partial] REPORT.json...
// --partial: the reports come from a filtered run (--grep), so a baseline entry for a test that is not in them is not stale.
const fs = require('fs');
const path = require('path');

const TICKET = /^t-[a-z0-9]{4}$/;
const norm = (s) => String(s).replace(/\\(['"`])/g, '$1').replace(/\s+/g, ' ').trim();

// Walk a Playwright JSON report: { 'suite > test title': status } (the leading file suite is dropped).
function testsOf(report) {
  const out = {};
  const walk = (suite, trail) => {
    for (const s of suite.suites || []) walk(s, trail.concat(s.title));
    for (const sp of suite.specs || []) {
      for (const t of sp.tests || []) out[trail.concat(sp.title).join(' > ')] = t.status;
    }
  };
  for (const s of report.suites || []) walk(s, []);
  return out;
}
const browserOf = (file) => (/-(chromium|webkit|firefox)-run\d+\.json$/.exec(file) || [])[1] || null;
const isFailure = (status) => status === 'unexpected' || status === 'flaky' || status === 'timedOut' || status === 'interrupted';

// reports: [{ browser, run, tests: {title: status} }]; baseline: { failing: [...], flaky: [...] }; specText: the spec source.
function evaluate({ reports, baseline, specText, partial }) {
  const violations = [], warnings = [];
  const browsers = [...new Set(reports.map((r) => r.browser))];
  const classes = {}; // browser -> { failing: [], flaky: [], passing: n, skipped: [], total, runs }
  const known = new Set();
  for (const b of browsers) {
    const runs = reports.filter((r) => r.browser === b);
    const titles = new Set(); runs.forEach((r) => Object.keys(r.tests).forEach((t) => titles.add(t)));
    const c = { failing: [], flaky: [], skipped: [], passing: 0, total: titles.size, runs: runs.length };
    for (const t of titles) {
      known.add(t);
      const failed = runs.filter((r) => isFailure(r.tests[t])).length;
      if (runs.every((r) => r.tests[t] === 'skipped')) c.skipped.push(t);
      else if (failed === runs.length) c.failing.push(t);
      else if (failed > 0) c.flaky.push(t);
      else c.passing++;
    }
    classes[b] = c;
  }
  const listed = (kind, title, b) => (baseline[kind] || []).some((e) => e.title === title && (e.browsers || []).includes(b));
  for (const b of browsers) {
    for (const t of classes[b].failing) {
      if (listed('failing', t, b)) continue;
      // A listed flaky test may fail in every run of a small batch (3 runs: likely for one that fails more than half the time).
      if (listed('flaky', t, b)) warnings.push(`${b}: "${t}" failed in every run (${classes[b].runs}/${classes[b].runs}) but is listed as flaky — consider quarantining it`);
      else violations.push(`${b}: "${t}" failed in every run and is not listed in the baseline`);
    }
    for (const t of classes[b].flaky) if (!listed('flaky', t, b) && !listed('failing', t, b)) violations.push(`${b}: "${t}" failed in ${runsFailed(reports, b, t)} of ${classes[b].runs} runs and is not listed in the baseline`);
  }
  for (const kind of ['failing', 'flaky']) {
    for (const e of baseline[kind] || []) {
      const where = `baseline ${kind} entry "${e.title}"`;
      if (!e.title || !e.reason) violations.push(`${where} needs a title and a reason`);
      if (!Array.isArray(e.browsers) || !e.browsers.length) violations.push(`${where} needs a browsers list`);
      if (kind === 'failing' && !TICKET.test(e.ticket || '')) violations.push(`${where} needs a ticket id (t-xxxx)`);
      if (kind === 'flaky' && e.ticket && !TICKET.test(e.ticket)) violations.push(`${where} has a malformed ticket id`);
      if (!known.has(e.title) && reports.length && !partial) violations.push(`${where} matches no test in the reports (stale or renamed)`);
      if (kind === 'failing') for (const b of e.browsers || []) if (classes[b] && !classes[b].failing.includes(e.title) && known.has(e.title)) warnings.push(`${b}: quarantined "${e.title}" did not fail in every run (stale? ${classes[b].flaky.includes(e.title) ? 'flaky' : 'passing'})`);
    }
  }
  // QUARANTINE markers: every failing entry has one directly above its test(...) line, and every marker has an entry.
  const lines = String(specText || '').split('\n');
  const markers = [];
  lines.forEach((l, i) => {
    const m = /\/\/\s*QUARANTINE\s+(t-[a-z0-9]{4})\s*:\s*(.+)$/.exec(l);
    if (!m) return;
    let j = i + 1; while (j < lines.length && !lines[j].trim()) j++;
    markers.push({ ticket: m[1], next: norm(lines[j] || ''), line: i + 1 });
  });
  for (const e of baseline.failing || []) {
    const head = norm(e.title.split(' > ').pop()).slice(0, 40);
    if (!markers.some((m) => m.ticket === e.ticket && m.next.includes(head))) violations.push(`failing entry "${e.title}" has no "// QUARANTINE ${e.ticket}: reason" marker directly above its test in the spec`);
  }
  for (const m of markers) {
    const hit = (baseline.failing || []).some((e) => e.ticket === m.ticket && m.next.includes(norm(e.title.split(' > ').pop()).slice(0, 40)));
    if (!hit) violations.push(`spec line ${m.line}: QUARANTINE ${m.ticket} marker has no matching failing entry in the baseline`);
  }
  return { violations, warnings, classes };
}
function runsFailed(reports, b, t) { return reports.filter((r) => r.browser === b && isFailure(r.tests[t])).length; }

function main(argv) {
  let baselineFile = path.join(__dirname, 'board-spec-baseline.json'), specFile = path.join(__dirname, 'sprint-check-app.spec.js');
  const files = []; let partial = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--partial') partial = true;
    else if (argv[i] === '--baseline') baselineFile = argv[++i];
    else if (argv[i] === '--spec') specFile = argv[++i];
    else files.push(argv[i]);
  }
  if (!files.length) { console.error('board-spec-guard: no report files given'); return 2; }
  const reports = files.map((f) => {
    const browser = browserOf(f);
    if (!browser) { console.error(`board-spec-guard: cannot tell the browser from "${f}" (expected board-spec-<browser>-run<N>.json)`); process.exit(2); }
    return { browser, run: f, tests: testsOf(JSON.parse(fs.readFileSync(f, 'utf8'))) };
  });
  const baseline = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
  const r = evaluate({ reports, baseline, specText: fs.readFileSync(specFile, 'utf8'), partial });
  for (const [b, c] of Object.entries(r.classes)) {
    console.log(`== ${b}: ${c.total} tests, ${c.runs} run(s): ${c.passing} passing, ${c.flaky.length} flaky, ${c.failing.length} failing, ${c.skipped.length} skipped`);
    for (const t of c.failing) console.log(`   FAILING ${t}`);
    for (const t of c.flaky) console.log(`   flaky   ${t}`);
    for (const t of c.skipped) console.log(`   skipped ${t}`);
  }
  for (const w of r.warnings) console.log(`warning: ${w}`);
  for (const v of r.violations) console.log(`VIOLATION: ${v}`);
  console.log(r.violations.length ? `board-spec-guard: ${r.violations.length} violation(s)` : 'board-spec-guard: ok (every failure is listed in the baseline)');
  return r.violations.length ? 1 : 0;
}

module.exports = { evaluate, testsOf, browserOf };
if (require.main === module) process.exit(main(process.argv.slice(2)));
