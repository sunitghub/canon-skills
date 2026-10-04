#!/usr/bin/env node
// board-spec-guard-unit — t-4469. Drives the real guard (tests/board-spec-guard.js) with fake reports, baselines and spec text.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { evaluate } = require('./board-spec-guard.js');

let fails = 0;
const ok = (name, cond, detail) => { if (cond) console.log('  ok   ' + name); else { fails++; console.log('  FAIL ' + name + (detail !== undefined ? '  => ' + JSON.stringify(detail) : '')); } };

const rep = (browser, run, tests) => ({ browser, run: `board-spec-${browser}-run${run}.json`, tests });
const TITLE = 'cockpit leave-session confirm > a fresh modal open resets buttons';
const TITLE2 = "cockpit leave-session confirm > a refused Save & End keeps the session, explains why, and re-enables the controls";
const spec = (marker, line) => `describe(...)\n${marker}\n  ${line}\n`;
const marked = spec('  // QUARANTINE t-aaaa: stale expectation', `test('a fresh modal open resets buttons', async () => {`);
const allPass = (b, n) => Array.from({ length: n }, (_, i) => rep(b, i + 1, { [TITLE]: 'expected', [TITLE2]: 'expected', other: 'expected' }));
const v = (r) => r.violations;
const failing = { failing: [{ title: TITLE, browsers: ['chromium'], ticket: 't-aaaa', reason: 'stale expectation' }], flaky: [] };

// ── clean run, empty baseline ──
{
  const r = evaluate({ reports: allPass('chromium', 3), baseline: { failing: [], flaky: [] }, specText: '' });
  ok('a run with no failures has no violations', v(r).length === 0 && r.classes.chromium.passing === 3, r);
}
// ── unlisted failures ──
{
  const reports = [1, 2, 3].map((i) => rep('chromium', i, { [TITLE]: 'unexpected', [TITLE2]: 'expected', other: 'expected' }));
  const r = evaluate({ reports, baseline: { failing: [], flaky: [] }, specText: '' });
  ok('a test failing in every run and not listed is a violation', v(r).length === 1 && /failed in every run and is not listed/.test(v(r)[0]), v(r));
  const asFlaky = evaluate({ reports, baseline: { failing: [], flaky: [{ title: TITLE, browsers: ['chromium'], ticket: 't-dddd', reason: 'timing' }] }, specText: '' });
  ok('a listed flaky test that failed in EVERY run is allowed, with a warning', v(asFlaky).length === 0 && asFlaky.warnings.length === 1 && /listed as flaky/.test(asFlaky.warnings[0]), [v(asFlaky), asFlaky.warnings]);
  const wrongBrowser = evaluate({ reports, baseline: { failing: [], flaky: [{ title: TITLE, browsers: ['webkit'], ticket: 't-dddd', reason: 'timing' }] }, specText: '' });
  ok('a flaky entry for another browser does not cover this one', v(wrongBrowser).length === 1, v(wrongBrowser));
}
{
  const reports = [rep('chromium', 1, { [TITLE]: 'unexpected', other: 'expected' }), rep('chromium', 2, { [TITLE]: 'expected', other: 'expected' }), rep('chromium', 3, { [TITLE]: 'expected', other: 'expected' })];
  const r = evaluate({ reports, baseline: { failing: [], flaky: [] }, specText: '' });
  ok('a test failing in one of three runs and not listed is a violation', v(r).length === 1 && /failed in 1 of 3 runs/.test(v(r)[0]), v(r));
  const listed = evaluate({ reports, baseline: { failing: [], flaky: [{ title: TITLE, browsers: ['chromium'], ticket: 't-dddd', reason: 'timing' }] }, specText: '' });
  ok('the same flaky test listed is allowed', v(listed).length === 0 && listed.classes.chromium.flaky.length === 1, v(listed));
  const passes = evaluate({ reports: allPass('chromium', 3), baseline: { failing: [], flaky: [{ title: TITLE, browsers: ['chromium'], ticket: 't-dddd', reason: 'timing' }] }, specText: '' });
  ok('a listed flaky test that passes in every run is allowed, with no warning', v(passes).length === 0 && passes.warnings.length === 0, [v(passes), passes.warnings]);
}
// ── browser scoping ──
{
  const reports = [...allPass('chromium', 2), ...[1, 2].map((i) => rep('webkit', i, { [TITLE]: 'unexpected', [TITLE2]: 'expected', other: 'expected' }))];
  const r = evaluate({ reports, baseline: failing, specText: marked });
  ok('a failure listed for chromium only is still a violation on webkit', v(r).some((x) => x.startsWith('webkit:')), v(r));
}
// ── quarantine entries and markers ──
{
  const reports = [1, 2].map((i) => rep('chromium', i, { [TITLE]: 'unexpected', [TITLE2]: 'expected', other: 'expected' }));
  const good = evaluate({ reports, baseline: failing, specText: marked });
  ok('a listed failing test with its marker is clean', v(good).length === 0, v(good));
  const noMarker = evaluate({ reports, baseline: failing, specText: 'test(\'a fresh modal open resets buttons\', () => {})' });
  ok('a failing entry with no marker is a violation', v(noMarker).some((x) => /no "\/\/ QUARANTINE t-aaaa: reason" marker/.test(x)), v(noMarker));
  const orphan = evaluate({ reports: allPass('chromium', 2), baseline: { failing: [], flaky: [] }, specText: marked });
  ok('a marker with no baseline entry is a violation', v(orphan).some((x) => /marker has no matching failing entry/.test(x)), v(orphan));
  const noTicket = evaluate({ reports, baseline: { failing: [{ title: TITLE, browsers: ['chromium'], ticket: '', reason: 'x' }], flaky: [] }, specText: marked });
  ok('a failing entry without a ticket id is a violation', v(noTicket).some((x) => /needs a ticket id/.test(x)), v(noTicket));
  const noReason = evaluate({ reports, baseline: { failing: [{ title: TITLE, browsers: ['chromium'], ticket: 't-aaaa', reason: '' }], flaky: [] }, specText: marked });
  ok('an entry without a reason is a violation', v(noReason).some((x) => /needs a title and a reason/.test(x)), v(noReason));
  const wrongTicket = evaluate({ reports, baseline: failing, specText: spec('  // QUARANTINE t-bbbb: other', `test('a fresh modal open resets buttons', () => {})`) });
  ok('a marker carrying a different ticket id does not satisfy the entry', v(wrongTicket).length >= 2, v(wrongTicket));
  const apos = evaluate({ reports: [1, 2].map((i) => rep('chromium', i, { "x > session's mid-save": 'unexpected', other: 'expected' })),
    baseline: { failing: [{ title: "x > session's mid-save", browsers: ['chromium'], ticket: 't-cccc', reason: 'r' }], flaky: [] },
    specText: spec('  // QUARANTINE t-cccc: r', "test('session\\'s mid-save', async () => {") });
  ok("an escaped apostrophe in the spec still matches the title's apostrophe", v(apos).length === 0, v(apos));
}
// ── stale entries ──
{
  const stale = evaluate({ reports: allPass('chromium', 2), baseline: { failing: [], flaky: [{ title: 'no such test', browsers: ['chromium'], ticket: 't-dddd', reason: 'r' }] }, specText: '' });
  ok('an entry whose title matches no test in the reports is a violation', v(stale).some((x) => /matches no test/.test(x)), v(stale));
  const heals = evaluate({ reports: allPass('chromium', 2), baseline: failing, specText: marked });
  ok('a quarantined test that now passes is a warning, not a violation', v(heals).length === 0 && heals.warnings.length === 1 && /did not fail in every run/.test(heals.warnings[0]), [v(heals), heals.warnings]);
}
// ── a filtered (--grep) run cannot call entries stale ──
{
  const reports = allPass('chromium', 2);
  const base = { failing: [], flaky: [{ title: 'not in this filtered run', browsers: ['chromium'], ticket: 't-dddd', reason: 'r' }] };
  ok('without --partial an entry missing from the reports is stale', evaluate({ reports, baseline: base, specText: '' }).violations.length === 1);
  ok('with --partial the same entry is not a violation', evaluate({ reports, baseline: base, specText: '', partial: true }).violations.length === 0);
  const bad = [1, 2].map((i) => rep('chromium', i, { canary: 'unexpected', other: 'expected' }));
  ok('--partial still fails an unlisted failure', evaluate({ reports: bad, baseline: { failing: [], flaky: [] }, specText: '', partial: true }).violations.length === 1);
}
// ── skipped tests, tests that did not report, the minimum test count ──
{
  const reports = [1, 2].map((i) => rep('chromium', i, { [TITLE]: 'skipped', other: 'expected' }));
  const unlisted = evaluate({ reports, baseline: { failing: [], flaky: [] }, specText: '' });
  ok('a test skipped in every run and not listed is a violation (a cascade skip is the "did not run" gap)', unlisted.violations.length === 1 && /was skipped in some or all runs/.test(unlisted.violations[0]) && unlisted.classes.chromium.skipped.length === 1, unlisted.violations);
  const listed = evaluate({ reports, baseline: { failing: [], flaky: [], skipped: [{ title: TITLE, browsers: ['chromium'], ticket: 't-dddd', reason: 'needs go' }] }, specText: '' });
  ok('the same skip listed under skipped is allowed', listed.violations.length === 0, listed.violations);
  const some = evaluate({ reports: [rep('chromium', 1, { [TITLE]: 'skipped', other: 'expected' }), rep('chromium', 2, { [TITLE]: 'expected', other: 'expected' })], baseline: { failing: [], flaky: [] }, specText: '' });
  ok('a test skipped in only some runs is a violation too', some.violations.length === 1, some.violations);
  const missing = evaluate({ reports: [rep('chromium', 1, { [TITLE]: 'expected', other: 'expected' }), rep('chromium', 2, { other: 'expected' })], baseline: { failing: [], flaky: [] }, specText: '' });
  ok('a test missing from one run is a violation', missing.violations.length === 1 && /missing from some runs/.test(missing.violations[0]), missing.violations);
  const floor = { failing: [], flaky: [], min_tests: { chromium: 3 } };
  const short = evaluate({ reports: allPass('chromium', 2), baseline: floor, specText: '' });
  ok('fewer tests than the baseline floor is a violation (3 expected, 3 reported passes; floor 4 fails)', short.violations.length === 0 && evaluate({ reports: allPass('chromium', 2), baseline: { ...floor, min_tests: { chromium: 4 } }, specText: '' }).violations.length === 1);
  ok('--partial does not check the floor', evaluate({ reports: allPass('chromium', 2), baseline: { ...floor, min_tests: { chromium: 99 } }, specText: '', partial: true }).violations.length === 0);
  const noTicket = evaluate({ reports: allPass('chromium', 2), baseline: { failing: [], flaky: [{ title: TITLE, browsers: ['chromium'], reason: 'timing' }] }, specText: '' });
  ok('a flaky entry without a ticket id is a violation', noTicket.violations.some((x) => /needs a ticket id/.test(x)), noTicket.violations);
}
// ── timedOut and interrupted count as failures ──
{
  for (const status of ['timedOut', 'interrupted']) {
    const r = evaluate({ reports: [1, 2].map((i) => rep('chromium', i, { [TITLE]: status, other: 'expected' })), baseline: { failing: [], flaky: [] }, specText: '' });
    ok(`status ${status} in every run is a failure that must be listed`, r.violations.length === 1 && r.classes.chromium.failing.length === 1, r.violations);
  }
}

// ── the real CLI: exit codes ──
{
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'board-spec-guard-'));
  const report = (statuses) => ({ suites: [{ title: 'file.spec.js', suites: [{ title: 'group', specs: Object.entries(statuses).map(([title, status]) => ({ title, tests: [{ status }] })) }] }] });
  const w = (f, o) => { fs.writeFileSync(path.join(dir, f), typeof o === 'string' ? o : JSON.stringify(o)); return path.join(dir, f); };
  const baselineFile = w('baseline.json', { failing: [], flaky: [] }), specFile = w('spec.js', '');
  const run = (...args) => spawnSync(process.execPath, [path.join(__dirname, 'board-spec-guard.js'), '--baseline', baselineFile, '--spec', specFile, ...args], { encoding: 'utf8' });
  const clean = [w('board-spec-chromium-run1.json', report({ a: 'expected' })), w('board-spec-chromium-run2.json', report({ a: 'expected' }))];
  ok('CLI exits 0 on a clean run', run(...clean).status === 0);
  const bad = [w('board-spec-webkit-run1.json', report({ a: 'unexpected' })), w('board-spec-webkit-run2.json', report({ a: 'unexpected' }))];
  const out = run(...bad);
  ok('CLI exits 1 and names an unlisted failure', out.status === 1 && /VIOLATION: webkit: "group > a"/.test(out.stdout), out.stdout);
  ok('CLI exits 2 with no reports', run().status === 2);
  // a listed flaky test failing in every run: exit 0 with a visible warning line, exit 1 with --strict
  const flakyBaseline = w('flaky-baseline.json', { failing: [], flaky: [{ title: 'group > a', browsers: ['webkit'], ticket: 't-dddd', reason: 'timing' }] });
  const runB = (...args) => spawnSync(process.execPath, [path.join(__dirname, 'board-spec-guard.js'), '--baseline', flakyBaseline, '--spec', specFile, ...args], { encoding: 'utf8' });
  const lenient = runB(...bad);
  ok('CLI exits 0 for a listed flaky test failing every run and says "ok with 1 warning(s)", not a plain ok', lenient.status === 0 && /ok with 1 warning\(s\)/.test(lenient.stdout) && !/ok \(every failure/.test(lenient.stdout), lenient.stdout);
  const strict = runB('--strict', ...bad);
  ok('CLI --strict turns that warning into exit 1', strict.status === 1 && /VIOLATION: \(--strict\)/.test(strict.stdout), strict.stdout);
  ok('CLI exits 2 when the browser cannot be read from the file name', run(w('whatever.json', report({ a: 'expected' }))).status === 2);
}

if (fails) { console.log(`\nboard-spec-guard-unit: ${fails} FAILED`); process.exit(1); }
console.log('board-spec-guard-unit: ok');
