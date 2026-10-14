#!/usr/bin/env node
// board-spec-classify-unit — t-b860. Drives the real classifier (tests/board-spec-classify.js) with fake reports shaped
// like the real ones (error messages as Playwright writes them, ANSI colour included) and its CLI with fake solo reports.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { kindOf, grepPattern, unlisted, verdict, tally, soloCount } = require('./board-spec-classify.js');
const { evaluate } = require('./board-spec-guard.js');

let fails = 0;
const ok = (name, cond, detail) => { if (cond) console.log('  ok   ' + name); else { fails++; console.log('  FAIL ' + name + (detail !== undefined ? '  => ' + JSON.stringify(detail) : '')); } };

const C = (s) => `\x1b[31m${s}\x1b[39m`;
const GOTO = { status: 'timedOut', errors: [{ message: C('Test timeout of 30000ms exceeded.') }, { message: C('Error: page.goto: Test timeout of 30000ms exceeded.\nCall log:') }] };
const HUNG_EXPECT = { status: 'timedOut', errors: [{ message: 'Test timeout of 30000ms exceeded.' }, { message: C('Error: expect(locator).toBeVisible() failed') }] };
const EXPECT = { status: 'failed', errors: [{ message: C('Error: expect(received).toBe(expected) // Object.is equality') }] };
const TYPEERR = { status: 'failed', errors: [{ message: "TypeError: Cannot read properties of null (reading 'y')" }] };
const BARE = { status: 'timedOut', errors: [{ message: 'Test timeout of 30000ms exceeded.' }] };

// ── kinds, from the real error shapes ──
{
  const k = kindOf([GOTO]);
  ok('a page.goto test timeout is a timeout naming page.goto and 30 s', k.kind === 'timeout' && k.where === 'page.goto' && k.seconds === 30, k);
  ok('a test timeout with a hung expect() is an assertion', kindOf([HUNG_EXPECT]).kind === 'assertion');
  ok('an expect() failure is an assertion', kindOf([EXPECT]).kind === 'assertion');
  ok('a TypeError is an error', kindOf([TYPEERR]).kind === 'error');
  ok('a timeout in one run and an expect() in another is an assertion', kindOf([GOTO, EXPECT]).kind === 'assertion');
  ok('a timeout plus a TypeError in another run is an error, not a timeout', kindOf([GOTO, TYPEERR]).kind === 'error');
  ok('a bare test timeout is a timeout in the test body', kindOf([BARE]).where === 'test body');
  ok('passing attempts are ignored', kindOf([{ status: 'passed', errors: [] }, GOTO]).kind === 'timeout');
}

// ── grep pattern ──
{
  const p = new RegExp(grepPattern('group > a (t-1234) {x:1} + y?'));
  ok('the pattern matches Playwright\'s grep title for the test', p.test('webkit tests/sprint-check-app.spec.js group a (t-1234) {x:1} + y?'));
  ok('the pattern does not match a longer title that starts with it', !p.test('webkit tests/sprint-check-app.spec.js group a (t-1234) {x:1} + y? and more'));
  ok('the pattern does not match a title that only ends with it', !p.test('webkit tests/sprint-check-app.spec.js othergroup a (t-1234) {x:1} + y?'));
}

// ── unlisted ──
const rec = (status, results) => ({ status, results });
const full = (b, tests) => ({ browser: b, records: tests });
{
  const reports = [
    full('webkit', { 'g > load': rec('unexpected', [GOTO]), 'g > listed': rec('unexpected', [GOTO]), 'g > fine': rec('expected', []), 'g > assert': rec('unexpected', [EXPECT]) }),
    full('webkit', { 'g > load': rec('expected', []), 'g > listed': rec('expected', []), 'g > fine': rec('expected', []), 'g > assert': rec('unexpected', [EXPECT]) }),
  ];
  const u = unlisted(reports, { failing: [], flaky: [{ title: 'g > listed', browsers: ['webkit'], ticket: 't-5989', reason: 'x' }] });
  ok('unlisted returns the unlisted failing and flaky tests only', u.map((t) => t.title).join('|') === 'g > assert|g > load', u);
  const load = u.find((t) => t.title === 'g > load');
  ok('unlisted counts the full-run failures', load.failedRuns === 1 && load.runs === 2 && load.kind === 'timeout', load);
  const other = unlisted(reports, { failing: [], flaky: [{ title: 'g > listed', browsers: ['chromium'], ticket: 't-5989', reason: 'x' }] });
  ok('an entry for another browser does not hide a failure', other.some((t) => t.title === 'g > listed'), other);
}

// ── verdicts ──
const T = { title: 'g > load', browser: 'webkit', kind: 'timeout', where: 'page.goto', seconds: 30, failedRuns: 1, runs: 1 };
const pass3 = tally([{ ran: 1, passed: true }, { ran: 1, passed: true }, { ran: 1, passed: true }]);
const fail1 = tally([{ ran: 1, passed: true }, { ran: 1, passed: false }, { ran: 1, passed: true }]);
const wide = tally([{ ran: 1, passed: true }, { ran: 2, passed: true }, { ran: 1, passed: true }]);
const none = tally([{ ran: 0, passed: false }, { ran: 0, passed: false }, { ran: 0, passed: false }]);
{
  ok('a timeout passing every solo run on both is a candidate', verdict(T, pass3, pass3, 'main').candidate === true);
  const a = verdict({ ...T, kind: 'assertion' }, pass3, pass3, 'main');
  ok('an assertion is a likely regression even when it passes alone', !a.candidate && /^likely regression/.test(a.text), a);
  const e = verdict({ ...T, kind: 'error' }, pass3, pass3, 'main');
  ok('an error is a likely regression', !e.candidate && /^likely regression/.test(e.text), e);
  const fb = verdict(T, fail1, pass3, 'main');
  ok('a solo failure on the branch is a likely regression', !fb.candidate && /^likely regression: failed alone on the branch \(passed 2\/3\)/.test(fb.text), fb);
  const fbase = verdict(T, pass3, fail1, 'main');
  ok('a solo failure on the base is a likely regression', !fbase.candidate && /^likely regression: failed alone on main too/.test(fbase.text), fbase);
  const nb = verdict(T, pass3, null, undefined);
  ok('no --base gives no entry and says to pass --base', !nb.candidate && /^no entry: pass --base/.test(nb.text), nb);
  const ni = verdict(T, wide, pass3, 'main');
  ok('a branch solo run that matched 2 tests is not isolated', !ni.candidate && /^not isolated/.test(ni.text) && /1,2,1/.test(ni.text), ni);
  const nib = verdict(T, pass3, none, 'main');
  ok('a base where the test is missing is not isolated', !nib.candidate && /^not isolated/.test(nib.text), nib);
  ok('a solo report that ran two tests does not count as a pass', tally([{ ran: 2, passed: true }]).passed === 0);
  ok('a missing solo report ran nothing', soloCount(null, 'x').ran === 0);
  const soloReport = (status) => ({ suites: [{ title: 'tests/sprint-check-app.spec.js', suites: [{ title: 'g', specs: [{ title: 'load', tests: [{ status, results: [] }] }] }] }] });
  const failedAlone = soloCount(soloReport('unexpected'), 'g > load');
  ok('a solo run that ran the test and failed it is not a pass', failedAlone.ran === 1 && failedAlone.passed === false, failedAlone);
  ok('a solo run that ran the test and passed it is a pass', soloCount(soloReport('expected'), 'g > load').passed === true);
}

// ── the real CLI: list and report, and the entry passes the guard's own validation ──
{
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'board-spec-classify-'));
  const w = (f, o) => { const p = path.join(dir, f); fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, JSON.stringify(o)); return p; };
  const report = (tests) => ({ suites: [{ title: 'tests/sprint-check-app.spec.js', suites: [{ title: 'g', specs: Object.entries(tests).map(([title, t]) => ({ title, tests: [t] })) }] }] });
  const baselineFile = w('baseline.json', { min_tests: {}, failing: [], flaky: [], skipped: [] });
  const fullRun = w('board-spec-webkit-run1.json', report({ load: rec('timedOut', [GOTO]), assert: rec('unexpected', [EXPECT]), fine: rec('expected', [{ status: 'passed' }]) }));
  const cli = (...args) => spawnSync(process.execPath, [path.join(__dirname, 'board-spec-classify.js'), ...args], { encoding: 'utf8' });
  const list = cli('list', '--baseline', baselineFile, fullRun);
  ok('list prints one browser<TAB>pattern line per unlisted failure', list.status === 0 && list.stdout === 'webkit\t g assert$\nwebkit\t g load$\n', list.stdout);
  // test 1 = g > assert, test 2 = g > load; every solo run passes and ran one test
  for (const side of ['branch', 'base']) for (const i of [1, 2]) for (const k of [1, 2, 3]) {
    w(`solo/${side}-${i}-run${k}.json`, report({ [i === 1 ? 'assert' : 'load']: rec('expected', [{ status: 'passed' }]) }));
  }
  const out = cli('report', '--baseline', baselineFile, '--solo', path.join(dir, 'solo'), '--solo-runs', '3', '--head', 'abc1234', '--base-ref', 'main', '--base-sha', 'def5678', fullRun);
  ok('report exits 0', out.status === 0, out.stderr);
  ok('report prints the kind and counts for the timeout', /-- webkit: g > load\n   kind: timeout \(page\.goto, 30 s\); full run: failed 1\/1\n   alone on the branch: passed 3\/3; alone on the base: passed 3\/3\n   verdict: baseline candidate/.test(out.stdout), out.stdout);
  ok('report calls the passing assertion a likely regression', /-- webkit: g > assert\n[^]*?verdict: likely regression: an assertion failed/.test(out.stdout), out.stdout);
  const json = out.stdout.slice(out.stdout.indexOf('{'));
  let entry = null; try { entry = JSON.parse(json); } catch (e) { /* reported below */ }
  ok('exactly one entry is printed and it parses as JSON', entry && entry.title === 'g > load' && entry.ticket === 't-5989' && entry.failed_runs.webkit === '1/1', json);
  ok('the reason names both refs and the counts', entry && /30 s webkit page\.goto timeout in a full run \(1\/1 runs at abc1234, \d{4}-\d\d-\d\d\); passed alone 3\/3 on the branch and 3\/3 on main def5678/.test(entry.reason), entry && entry.reason);
  const g = entry && evaluate({ reports: [{ browser: 'webkit', tests: { 'g > load': 'unexpected' } }], baseline: { failing: [], flaky: [entry] }, specText: '' });
  ok('the guard accepts the pasted entry with no violation', g && g.violations.length === 0, g && g.violations);
  const noBase = cli('report', '--baseline', baselineFile, '--solo', path.join(dir, 'solo'), '--solo-runs', '3', '--head', 'abc1234', fullRun);
  ok('without --base the report prints no entry', noBase.status === 0 && /no entry: pass --base/.test(noBase.stdout) && /== no baseline candidates/.test(noBase.stdout) && !/"ticket"/.test(noBase.stdout), noBase.stdout);
  ok('report without --solo exits 2', cli('report', fullRun).status === 2);
  ok('an unknown mode exits 2', cli('nope', fullRun).status === 2);
  const before = fs.readFileSync(path.join(__dirname, 'board-spec-baseline.json'), 'utf8');
  cli('report', '--solo', path.join(dir, 'solo'), '--solo-runs', '3', '--head', 'abc1234', '--base-ref', 'main', '--base-sha', 'def5678', fullRun);
  ok('the real baseline is not written by a report run', fs.readFileSync(path.join(__dirname, 'board-spec-baseline.json'), 'utf8') === before);
  fs.rmSync(dir, { recursive: true, force: true });
}

if (fails) { console.log(`\nboard-spec-classify-unit: ${fails} FAILED`); process.exit(1); }
console.log('board-spec-classify-unit: ok');
