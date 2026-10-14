#!/usr/bin/env node
// board-spec-classify — t-b860. Helps tests/run-board-spec.sh --classify sort the failures the guard did not find in the
// baseline: which ones are load timeouts that pass alone (a baseline candidate) and which look like regressions.
//   node tests/board-spec-classify.js list   [--baseline FILE] REPORT.json...
//     prints one "<browser>\t<grep pattern>" line per unlisted failing or flaky test, in a fixed order.
//   node tests/board-spec-classify.js report [--baseline FILE] --solo DIR --solo-runs N --head SHA [--base-ref REF --base-sha SHA] REPORT.json...
//     reads the solo reports DIR/branch-<i>-run<k>.json (and base-<i>-run<k>.json) for the i-th listed test and prints,
//     per test, the error kind, the counts, a verdict and, for a candidate only, a baseline entry to paste by hand.
// Never writes the baseline: the entry is printed so the change stays reviewed.
const fs = require('fs');
const path = require('path');
const { evaluate, recordsOf, browserOf, isListed, isFailure } = require('./board-spec-guard.js');

const TICKET = 't-5989'; // owns the WebKit load flakes
const plain = (s) => String(s || '').replace(/\x1b\[[0-9;]*m/g, '');

// The kind of failure from the failed attempts of one test: an expect() anywhere is an assertion (a hung expectation
// can be a real regression); a test timeout with no expect() is a timeout, naming the call that stalled; else an error.
function kindOf(results) {
  const failed = results.filter((r) => r && r.status !== 'passed' && r.status !== 'skipped'); // attempt statuses: failed, timedOut, interrupted
  const messages = failed.flatMap((r) => (r.errors && r.errors.length ? r.errors : [r.error || {}]).map((e) => plain(e.message)));
  if (messages.some((m) => /^(Error: )?expect\(/.test(m))) return { kind: 'assertion' };
  if (!failed.length || failed.some((r) => r.status !== 'timedOut')) return { kind: 'error' };
  const call = messages.map((m) => /^Error: ([\w.]+): Test timeout/.exec(m)).find(Boolean);
  const ms = messages.map((m) => /Test timeout of (\d+)ms/.exec(m)).find(Boolean);
  return { kind: 'timeout', where: call ? call[1] : 'test body', seconds: ms ? Number(ms[1]) / 1000 : null };
}

// Playwright greps "<project> <file> <describe...> <title> <tags>" joined by spaces; the spec uses no tags, so anchoring
// at the end keeps a title from also matching a longer title that starts with it. A wrong match shows up as ran !== 1.
const grepPattern = (title) => ' ' + title.split(' > ').join(' ').replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$';

// reports: [{ browser, records }] from full runs. Returns the unlisted failing/flaky tests in a fixed order.
function unlisted(reports, baseline) {
  const r = evaluate({ reports: reports.map((x) => ({ browser: x.browser, tests: Object.fromEntries(Object.entries(x.records).map(([t, rec]) => [t, rec.status])) })), baseline, specText: '', partial: true });
  const out = [];
  for (const b of Object.keys(r.classes).sort()) {
    for (const title of [...r.classes[b].failing, ...r.classes[b].flaky].sort()) {
      if (isListed(baseline, 'failing', title, b) || isListed(baseline, 'flaky', title, b)) continue;
      const runs = reports.filter((x) => x.browser === b);
      const results = runs.flatMap((x) => (x.records[title] && x.records[title].results) || []);
      out.push({ title, browser: b, failedRuns: runs.filter((x) => x.records[title] && isFailure(x.records[title].status)).length, runs: runs.length, ...kindOf(results) });
    }
  }
  return out;
}

// One solo report: how many tests it ran and whether `title` passed. A missing or unreadable report ran nothing.
function soloCount(report, title) {
  if (!report) return { ran: 0, passed: false };
  const records = recordsOf(report);
  const rec = records[title];
  return { ran: Object.keys(records).length, passed: !!rec && rec.status === 'expected' };
}
const tally = (counts) => ({ runs: counts.length, passed: counts.filter((c) => c.passed && c.ran === 1).length, isolated: counts.every((c) => c.ran === 1), ran: counts.map((c) => c.ran) });

// t: an unlisted() item; branch/base: tally() results (base null when no --base). Returns { candidate, text }.
function verdict(t, branch, base, baseRef) {
  if (!branch.isolated) return { candidate: false, text: `not isolated: the solo runs on the branch matched ${branch.ran.join(',')} tests (expected 1 each)` };
  if (t.kind !== 'timeout') return { candidate: false, text: `likely regression: ${t.kind === 'assertion' ? 'an assertion failed' : 'it failed with an error, not a timeout'}` };
  if (branch.passed < branch.runs) return { candidate: false, text: `likely regression: failed alone on the branch (passed ${branch.passed}/${branch.runs})` };
  if (!base) return { candidate: false, text: 'no entry: pass --base <ref> to check the base too' };
  if (!base.isolated) return { candidate: false, text: `not isolated: the solo runs on ${baseRef} matched ${base.ran.join(',')} tests (expected 1 each; missing on the base?)` };
  if (base.passed < base.runs) return { candidate: false, text: `likely regression: failed alone on ${baseRef} too (passed ${base.passed}/${base.runs})` };
  return { candidate: true, text: 'baseline candidate: a load timeout that passes alone on both' };
}

function entryFor(t, branch, base, { head, baseRef, baseSha, date }) {
  const secs = t.seconds ? `${t.seconds} s ` : '';
  return {
    title: t.title,
    browsers: [t.browser],
    ticket: TICKET,
    reason: `${secs}${t.browser} ${t.where} timeout in a full run (${t.failedRuns}/${t.runs} runs at ${head}, ${date}); passed alone ${branch.passed}/${branch.runs} on the branch and ${base.passed}/${base.runs} on ${baseRef} ${baseSha} (run-board-spec --classify)`,
    failed_runs: { [t.browser]: `${t.failedRuns}/${t.runs}` },
  };
}

const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) { return null; } };

function main(argv) {
  const mode = argv[0];
  const opt = { baseline: path.join(__dirname, 'board-spec-baseline.json') }; const files = [];
  for (let i = 1; i < argv.length; i++) {
    const m = /^--(baseline|solo|solo-runs|head|base-ref|base-sha)$/.exec(argv[i]);
    if (m) opt[m[1]] = argv[++i]; else files.push(argv[i]);
  }
  if ((mode !== 'list' && mode !== 'report') || !files.length) { console.error('board-spec-classify: usage: list|report [options] REPORT.json...'); return 2; }
  const reports = files.map((f) => {
    const browser = browserOf(f), report = readJson(f);
    if (!browser || !report) { console.error(`board-spec-classify: cannot read "${f}" as board-spec-<browser>-run<N>.json`); process.exit(2); }
    return { browser, records: recordsOf(report) };
  });
  const tests = unlisted(reports, JSON.parse(fs.readFileSync(opt.baseline, 'utf8')));
  if (mode === 'list') { for (const t of tests) console.log(`${t.browser}\t${grepPattern(t.title)}`); return 0; }

  const n = Number(opt['solo-runs']);
  if (!opt.solo || !(n > 0) || !opt.head || (opt['base-ref'] && !opt['base-sha'])) { console.error('board-spec-classify: report needs --solo DIR, --solo-runs N and --head SHA (and --base-sha with --base-ref)'); return 2; }
  const ctx = { head: opt.head, baseRef: opt['base-ref'], baseSha: opt['base-sha'], date: new Date().toISOString().slice(0, 10) };
  const solo = (side, i) => tally(Array.from({ length: n }, (_, k) => soloCount(readJson(path.join(opt.solo, `${side}-${i}-run${k + 1}.json`)), tests[i - 1].title)));
  console.log(`== classify: ${tests.length} unlisted failure(s); ${n} solo run(s) each on the branch (${ctx.head})${ctx.baseRef ? ` and on ${ctx.baseRef} (${ctx.baseSha})` : ''}`);
  const entries = [];
  tests.forEach((t, idx) => {
    const branch = solo('branch', idx + 1), base = ctx.baseRef ? solo('base', idx + 1) : null;
    const v = verdict(t, branch, base, ctx.baseRef);
    console.log(`-- ${t.browser}: ${t.title}`);
    console.log(`   kind: ${t.kind}${t.kind === 'timeout' ? ` (${t.where}${t.seconds ? `, ${t.seconds} s` : ''})` : ''}; full run: failed ${t.failedRuns}/${t.runs}`);
    console.log(`   alone on the branch: passed ${branch.passed}/${branch.runs}${branch.isolated ? '' : ` (matched ${branch.ran.join(',')})`}; alone on the base: ${base ? `passed ${base.passed}/${base.runs}${base.isolated ? '' : ` (matched ${base.ran.join(',')})`}` : 'not run'}`);
    console.log(`   verdict: ${v.text}`);
    if (v.candidate) entries.push(entryFor(t, branch, base, ctx));
  });
  if (entries.length) {
    console.log(`== ${entries.length} baseline entr${entries.length === 1 ? 'y' : 'ies'} to paste into "flaky" in tests/board-spec-baseline.json (review first; nothing was written):`);
    console.log(entries.map((e) => JSON.stringify(e, null, 2)).join(',\n'));
  } else console.log('== no baseline candidates');
  return 0;
}

module.exports = { kindOf, grepPattern, unlisted, soloCount, tally, verdict, entryFor };
if (require.main === module) process.exit(main(process.argv.slice(2)));
