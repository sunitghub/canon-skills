#!/usr/bin/env node
// board-spec-classify-unit — t-b860. Drives the real classifier (tests/board-spec-classify.js) with fake reports shaped
// like the real ones (error messages as Playwright writes them, ANSI colour included) and its CLI with fake solo reports.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const classify = require('./board-spec-classify.js');
// A classifier function that throws or returns nothing gives a value the next assertion rejects by name, so a broken
// guard fails its own check instead of crashing the whole run.
const guarded = (f, fallback) => (...args) => { try { const v = f(...args); return v === undefined ? fallback : v; } catch (e) { return fallback; } };
const kindOf = guarded(classify.kindOf, {}), grepPattern = guarded(classify.grepPattern, '^$never'), unlisted = guarded(classify.unlisted, []);
const verdict = guarded(classify.verdict, {}), tally = guarded(classify.tally, {}), soloCount = guarded(classify.soloCount, {});
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
  ok('no failed attempt at all is an error, not a timeout', kindOf([{ status: 'passed', errors: [] }]).kind === 'error');
  ok('an attempt with only a single error (no errors list) is read', kindOf([{ status: 'failed', error: { message: 'Error: expect(a).toBe(b)' } }]).kind === 'assertion');
  ok('an attempt with an empty errors list falls back to its error', kindOf([{ status: 'failed', errors: [], error: { message: 'Error: expect(a).toBe(b)' } }]).kind === 'assertion');
  const late = kindOf([{ status: 'timedOut', errors: [{ message: 'Error: locator.click: Target closed' }, { message: 'Test timeout of 45000ms exceeded.' }] }]);
  ok('the timeout seconds come from whichever error names them', late.kind === 'timeout' && late.seconds === 45, late);
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
  const order = unlisted([full('webkit', { 'g > z': rec('unexpected', [GOTO]), 'g > a': rec('unexpected', [GOTO]) }), full('chromium', { 'g > m': rec('unexpected', [GOTO]) }),
    full('webkit', { 'g > z': rec('unexpected', [GOTO]), 'g > a': rec('expected', []) }), full('chromium', { 'g > m': rec('unexpected', [GOTO]) })], { failing: [], flaky: [] });
  ok('unlisted is ordered by browser, then title, across failing and flaky', order.map((t) => `${t.browser}:${t.title}`).join('|') === 'chromium:g > m|webkit:g > a|webkit:g > z', order.map((t) => `${t.browser}:${t.title}`));
  const quarantined = unlisted(reports, { failing: [{ title: 'g > listed', browsers: ['webkit'], ticket: 't-5989', reason: 'x' }], flaky: [] });
  ok('a test listed under failing is not reclassified', !quarantined.some((t) => t.title === 'g > listed') && quarantined.length === 2, quarantined.map((t) => t.title));
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
  const twoTests = { suites: [{ title: 'tests/sprint-check-app.spec.js', suites: [{ title: 'g', specs: [{ title: 'load', tests: [{ status: 'expected', results: [] }] }, { title: 'load more', tests: [{ status: 'expected', results: [] }] }] }] }] };
  const wideRun = soloCount(twoTests, 'g > load');
  ok('a solo report that ran two tests counts both', wideRun.ran === 2 && wideRun.passed === true, wideRun);
  const otherOnly = soloCount(soloReport('expected'), 'g > something else');
  ok('a solo report that ran one OTHER test is not a pass for the target', otherOnly.ran === 1 && otherOnly.passed === false, otherOnly);
}

// ── the real CLI: list and report, and the entry passes the guard's own validation ──
{
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'board-spec-classify-'));
  const w = (f, o) => { const p = path.join(dir, f); fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, JSON.stringify(o)); return p; };
  const report = (tests) => ({ suites: [{ title: 'tests/sprint-check-app.spec.js', suites: [{ title: 'g', specs: Object.entries(tests).map(([title, t]) => ({ title, tests: [t] })) }] }] });
  const baselineFile = w('baseline.json', { min_tests: {}, failing: [], flaky: [], skipped: [] });
  // two full runs: the load test failed one of them, the assertion both
  const fullRun = [
    w('board-spec-webkit-run1.json', report({ 'load @webkit': rec('timedOut', [GOTO]), assert: rec('unexpected', [EXPECT]), fine: rec('expected', [{ status: 'passed' }]) })),
    w('board-spec-webkit-run2.json', report({ 'load @webkit': rec('expected', [{ status: 'passed' }]), assert: rec('unexpected', [EXPECT]), fine: rec('expected', [{ status: 'passed' }]) })),
  ];
  const cli = (...args) => spawnSync(process.execPath, [path.join(__dirname, 'board-spec-classify.js'), ...args], { encoding: 'utf8' });
  const list = cli('list', '--baseline', baselineFile, ...fullRun);
  ok('list prints one browser<TAB>pattern line per unlisted failure', list.status === 0 && list.stdout === 'webkit\t g assert$\nwebkit\t g load @webkit$\n', list.stdout);
  // test 1 = g > assert, test 2 = g > load @webkit (t-23f6: WebKit runs only tagged tests, so a WebKit failure's title carries the tag); every solo run passes and ran one test
  for (const side of ['branch', 'base']) for (const i of [1, 2]) for (const k of [1, 2, 3]) {
    w(`solo/${side}-${i}-run${k}.json`, report({ [i === 1 ? 'assert' : 'load @webkit']: rec('expected', [{ status: 'passed' }]) }));
  }
  const out = cli('report', '--baseline', baselineFile, '--solo', path.join(dir, 'solo'), '--solo-runs', '3', '--head', 'abc1234', '--base-ref', 'main', '--base-sha', 'def5678', ...fullRun);
  ok('report exits 0', out.status === 0, out.stderr);
  ok('report prints its header with the counts and both refs', out.stdout.startsWith('== classify: 2 unlisted failure(s); 3 solo run(s) each on the branch (abc1234) and on main (def5678)\n'), out.stdout.split('\n')[0]);
  ok('report announces one entry in the singular', /\n== 1 baseline entry to paste into "flaky" in tests\/board-spec-baseline\.json/.test(out.stdout), out.stdout);
  ok('report prints the kind and counts for the timeout', /-- webkit: g > load @webkit\n   kind: timeout \(page\.goto, 30 s\); full run: failed 1\/2\n   alone on the branch: passed 3\/3; alone on the base: passed 3\/3\n   verdict: baseline candidate/.test(out.stdout), out.stdout);
  ok('report calls the passing assertion a likely regression', /-- webkit: g > assert\n[^]*?verdict: likely regression: an assertion failed/.test(out.stdout), out.stdout);
  const json = out.stdout.slice(out.stdout.indexOf('{'));
  let entry = null; try { entry = JSON.parse(json); } catch (e) { /* reported below */ }
  ok('exactly one entry is printed and it parses as JSON', entry && entry.title === 'g > load @webkit' && entry.ticket === 't-5989' && entry.failed_runs && entry.failed_runs.webkit === '1/2', json);
  ok('the reason names both refs and the counts', entry && /30 s webkit page\.goto timeout in a full run \(1\/2 runs at abc1234, \d{4}-\d\d-\d\d\); passed alone 3\/3 on the branch and 3\/3 on main def5678/.test(entry.reason), entry && entry.reason);
  const g = entry && evaluate({ reports: [{ browser: 'webkit', tests: { 'g > load @webkit': 'unexpected' } }], baseline: { failing: [], flaky: [entry] }, specText: '' });
  ok('the guard accepts the pasted entry with no violation', g && g.violations.length === 0, g && g.violations);
  const noBase = cli('report', '--baseline', baselineFile, '--solo', path.join(dir, 'solo'), '--solo-runs', '3', '--head', 'abc1234', ...fullRun);
  ok('without --base the report prints no entry and says the base was not run', noBase.status === 0 && /alone on the base: not run/.test(noBase.stdout) && /no entry: pass --base/.test(noBase.stdout) && /== no baseline candidates/.test(noBase.stdout) && !/"ticket"/.test(noBase.stdout), noBase.stdout);
  // Per-run, per-side wiring: each case fails exactly one solo run on one side, so reading only run 1, only run N,
  // or the branch files for the base gives a different verdict.
  const pass = (t) => report({ [t]: rec('expected', [{ status: 'passed' }]) });
  const flop = (t) => report({ [t]: rec('unexpected', [GOTO]) });
  const caseDir = (name, failSide, failRun) => {
    for (const side of ['branch', 'base']) for (const k of [1, 2, 3]) {
      w(`${name}/${side}-1-run${k}.json`, pass('assert'));
      w(`${name}/${side}-2-run${k}.json`, side === failSide && k === failRun ? flop('load @webkit') : pass('load @webkit'));
    }
    return cli('report', '--baseline', baselineFile, '--solo', path.join(dir, name), '--solo-runs', '3', '--head', 'abc1234', '--base-ref', 'main', '--base-sha', 'def5678', ...fullRun);
  };
  for (const k of [1, 2, 3]) {
    const b = caseDir(`branch-fails-run${k}`, 'branch', k);
    ok(`a branch failure in solo run ${k} of 3 is a likely regression with no entry`, /-- webkit: g > load @webkit\n[^]*?alone on the branch: passed 2\/3; alone on the base: passed 3\/3\n   verdict: likely regression: failed alone on the branch \(passed 2\/3\)/.test(b.stdout) && !/"ticket"/.test(b.stdout), b.stdout);
    const a = caseDir(`base-fails-run${k}`, 'base', k);
    ok(`a base failure in solo run ${k} of 3 is a likely regression with no entry`, /-- webkit: g > load @webkit\n[^]*?alone on the branch: passed 3\/3; alone on the base: passed 2\/3\n   verdict: likely regression: failed alone on main too \(passed 2\/3\)/.test(a.stdout) && !/"ticket"/.test(a.stdout), a.stdout);
  }
  // the branch solo runs for test 2 (g > load) matched a second test too: not isolated, no entry
  for (const k of [1, 2, 3]) w(`wide/branch-1-run${k}.json`, report({ assert: rec('expected', [{ status: 'passed' }]) }));
  for (const k of [1, 2, 3]) w(`wide/branch-2-run${k}.json`, report({ 'load @webkit': rec('expected', [{ status: 'passed' }]), 'load more': rec('expected', [{ status: 'passed' }]) }));
  for (const i of [1, 2]) for (const k of [1, 2, 3]) w(`wide/base-${i}-run${k}.json`, report({ [i === 1 ? 'assert' : 'load @webkit']: rec('expected', [{ status: 'passed' }]) }));
  const wide = cli('report', '--baseline', baselineFile, '--solo', path.join(dir, 'wide'), '--solo-runs', '3', '--head', 'abc1234', '--base-ref', 'main', '--base-sha', 'def5678', ...fullRun);
  ok('a branch solo run that matched two tests prints not isolated and no entry', wide.status === 0 && /-- webkit: g > load @webkit\n[^]*?verdict: not isolated: the solo runs on the branch matched 2,2,2 tests/.test(wide.stdout) && /== no baseline candidates/.test(wide.stdout) && !/"ticket"/.test(wide.stdout), wide.stdout);
  const noSha = cli('report', '--baseline', baselineFile, '--solo', path.join(dir, 'solo'), '--solo-runs', '3', '--head', 'abc1234', '--base-ref', 'main', ...fullRun);
  ok('report with --base-ref but no --base-sha exits 2', noSha.status === 2, [noSha.status, noSha.stdout]);
  const full = ['--baseline', baselineFile, '--solo', path.join(dir, 'solo'), '--solo-runs', '3', '--head', 'abc1234'];
  ok('the complete report argument list exits 0', cli('report', ...full, ...fullRun).status === 0);
  for (const [flag, bad] of [['--solo', null], ['--solo-runs', null], ['--solo-runs', '0'], ['--solo-runs', 'x'], ['--head', null]]) {
    const i = full.indexOf(flag), args = full.slice(0, i).concat(bad === null ? [] : [flag, bad], full.slice(i + 2));
    const r = cli('report', ...args, ...fullRun);
    ok(`report with ${bad === null ? 'no ' + flag : flag + ' ' + bad} exits 2`, r.status === 2, [r.status, r.stdout]);
  }
  ok('report without --solo exits 2', cli('report', ...fullRun).status === 2);
  const nope = cli('nope', ...full, ...fullRun);
  ok('an unknown mode exits 2 with the usage line, even with a full argument list', nope.status === 2 && /usage: list\|report/.test(nope.stderr), [nope.status, nope.stderr]);
  ok('list with no report files exits 2', cli('list', '--baseline', baselineFile).status === 2);
  for (const [name, body] of [['invalid JSON', 'not json'], ['a JSON string', '"not json"'], ['an object with no suites', '{}'], ['null', 'null']]) {
    const f = path.join(dir, 'board-spec-webkit-run9.json'); fs.writeFileSync(f, body);
    const r = cli('list', '--baseline', baselineFile, f);
    ok(`a report that is ${name} exits 2 and names the file`, r.status === 2 && r.stderr.includes('board-spec-webkit-run9.json'), [r.status, r.stderr]);
  }
  const misnamed = cli('list', '--baseline', baselineFile, w('report.json', report({ a: rec('expected', []) })));
  ok('a report whose name has no browser exits 2', misnamed.status === 2, [misnamed.status, misnamed.stderr]);
  const before = fs.readFileSync(path.join(__dirname, 'board-spec-baseline.json'), 'utf8');
  cli('report', '--solo', path.join(dir, 'solo'), '--solo-runs', '3', '--head', 'abc1234', '--base-ref', 'main', '--base-sha', 'def5678', ...fullRun);
  ok('the real baseline is not written by a report run', fs.readFileSync(path.join(__dirname, 'board-spec-baseline.json'), 'utf8') === before);
  fs.rmSync(dir, { recursive: true, force: true });
}

if (fails) { console.log(`\nboard-spec-classify-unit: ${fails} FAILED`); process.exit(1); }
console.log('board-spec-classify-unit: ok');
