#!/usr/bin/env node
// sprint-progress-card (t-5ef8) — protects the Cockpit rail's Sprint progress card: the fold (sprintProgress) and the live render
// (progressCardHtml with `live`) of tools/sprint-check-app/static/sprint-progress-card.js, the REAL module the board and the shell load.
// Every row of acceptance.md's state table goes through both: the current node, the tone, the status words and the done rows. The rail
// itself (what it fetches, when, and that a switched tab keeps its card) is the board spec's "Sprint progress card in the rail" group.
const path = require('path');
const { pathToFileURL } = require('url');

const CARD = path.join(__dirname, '..', 'tools', 'sprint-check-app', 'static', 'sprint-progress-card.js');
import(pathToFileURL(CARD).href).then(({ sprintProgress, progressCardHtml, ticketMode, stepStartTimes, firstClosing }) => {
  let fails = 0;
  function ok(name, cond, detail) {
    if (cond) console.log('  ok   ' + name);
    else { fails++; console.log('  FAIL ' + name + (detail != null ? '  => ' + JSON.stringify(detail) : '')); }
  }
  // pipeline nodes as GET /api/v1/pipeline serves them (shared with the board spec's rail stubs)
  const NODES = require('./fixtures/sprint-progress-nodes.json');
  const IDS = NODES.filter(n => n.only !== 'manual').map(n => n.id);   // a Normal ticket's rows: a Manual-only node (your-test) is not drawn
  const events = list => list.map(([kind, data], i) => ({ kind, ts: `2026-11-19T10:00:0${i}.000Z`, data: { ticket: 't-1', ...(data || {}) } }));
  const rows = html => [...html.matchAll(/<li class="spc-row([^"]*)" data-spc-row="([^"]+)"/g)].map(m => ({ cls: m[1], id: m[2] }));
  // t-985c: the status is the current row's title ("<Step>: <status>…") or, with no current row, the head line
  const statusOf = html => { const t = /class="spc-row[^"]* cur"[^>]*title="([^"]*)"/.exec(html); if (t) return t[1]; return (/<div class="spc-status">([^<]*)</.exec(html) || [])[1] || ''; };

  // [name, events (oldest first), options, current node, tone, words the status line holds]
  const STATES = [
    ['no sprint events', [], {}, '', 'idle', ['Not started']],
    ['started, plan empty', [['sprint.started']], {}, 'plan', 'blue', ['Writing the plan']],
    ['started, plan written', [['sprint.started']], { planWritten: true }, 'approve-plan', 'red', ['Waiting on you']],
    ['spec check running', [['sprint.started'], ['gate.started', { role: 'speccheck' }]], {}, 'spec-check', 'amber', ['Spec check: Running']],
    ['spec check finished', [['gate.finished', { role: 'speccheck', verdict: 'READY' }]], {}, 'approve-plan', 'red', ['Waiting on you']],
    ['plan approved', [['sprint.started'], ['plan.approved']], {}, 'build', 'blue', ['Implementing']],
    ['reviewer running', [['plan.approved'], ['gate.started', { role: 'reviewer', attempt: '2' }]], {}, 'reviewer', 'amber', ['Reviewer: Running · attempt 2']],
    ['reviewer finished', [['gate.finished', { role: 'reviewer', verdict: 'YES' }]], {}, 'security-review', 'blue', ['In your session']],
    ['evaluator running', [['gate.started', { role: 'evaluator', attempt: '1' }]], {}, 'eval', 'amber', ['Evaluator: Running · attempt 1']],
    ['second eval running', [['gate.started', { role: 'evaluator2' }]], {}, 'eval', 'amber', ['Evaluator: Running']],
    ['evaluator failed', [['gate.finished', { role: 'evaluator', verdict: 'fail' }]], {}, 'eval', 'red', ['Evaluator: fail']],
    ['evaluator other verdict', [['gate.finished', { role: 'evaluator', verdict: 'error' }]], {}, 'eval', 'red', ['Evaluator: error']],
    ['reviewer refused', [['gate.rejected', { role: 'reviewer', reason: 'stale' }]], {}, 'reviewer', 'red', ['Close refused', 'stale']],
    ['evaluator refused', [['gate.rejected', { role: 'evaluator', reason: 'stale' }]], {}, 'eval', 'red', ['Close refused', 'stale']],
    ['evaluator passed', [['gate.finished', { role: 'evaluator', verdict: 'pass' }]], {}, 'close', 'blue', ['Ready to close']],
    ['close confirmed', [['close.confirmed']], {}, 'close', 'blue', ['Closing']],
    ['closed', [['plan.approved'], ['sprint.completed']], {}, '', 'green', ['Closed']],
    ['needs you while building', [['plan.approved']], { needsYou: true }, 'build', 'red', ['Needs you', 'Implementing']],
    ['needs you does not wake an idle card', [], { needsYou: true }, '', 'idle', ['Not started']],
    ['needs you does not reopen a closed sprint', [['sprint.completed']], { needsYou: true }, '', 'green', ['Closed']],
    // t-985c: the close began; the switch's own outcomes
    ['close started', [['plan.approved'], ['close.started']], {}, 'code-simplifier', 'blue', ['Closing']],
    ['switch not taken', [['plan.approved'], ['build.switch', { outcome: 'not_taken', attempts: '3' }]], {}, 'build', 'red', ['Build switch: the continue line was not taken (3 tries); type continue']],
    ['switch not at rest', [['plan.approved'], ['build.switch', { outcome: 'not_at_rest', reason: 'not_quiet' }]], {}, 'build', 'red', ['Build switch: the session was not ready (not_quiet)']],
    ['switch write error', [['plan.approved'], ['build.switch', { outcome: 'write_error' }]], {}, 'build', 'red', ['Build switch: could not type into the session']],
    ['switch started', [['plan.approved'], ['build.switch', { outcome: 'started' }]], {}, 'build', 'blue', ['Implementing']],
  ];
  for (const [name, evs, opts, cur, tone, words] of STATES) {
    const st = sprintProgress(NODES, events(evs), opts);
    const html = progressCardHtml(NODES, 'normal', { ...st, events: [] });
    const r = rows(html), curRows = r.filter(x => / cur\b/.test(x.cls)).map(x => x.id);
    const done = r.filter(x => / done\b/.test(x.cls)).map(x => x.id);
    const status = statusOf(html);
    const wantDone = tone === 'green' ? IDS : cur ? IDS.slice(0, IDS.indexOf(cur)) : [];
    ok(`${name}: current ${cur || '(none)'}`, (cur ? curRows.length === 1 && curRows[0] === cur : curRows.length === 0) && st.cur === cur, { st, curRows });
    ok(`${name}: tone ${tone}`, st.tone === tone && html.includes(`data-tone="${tone}"`), st.tone);
    ok(`${name}: status says ${words.join(' + ')}`, words.every(w => status.includes(w)), status);
    ok(`${name}: done rows`, JSON.stringify(done) === JSON.stringify(wantDone), done);
    ok(`${name}: no status line under a row, no box, no event strip`, !/<span class="spc-status">/.test(html) && !html.includes('spc-evs'), null);
    ok(`${name}: the current row's title is also its aria-label`, !cur || /class="spc-row[^"]* cur"[^>]*title="([^"]*)" aria-label="\1"/.test(html), null);
  }

  // the newest event decides, whatever order the snapshot lists them in; an event with no usable ts counts as oldest
  {
    const st = sprintProgress(NODES, [{ kind: 'gate.started', ts: '2026-11-19T10:05:00.000Z', data: { role: 'reviewer' } }, { kind: 'plan.approved', ts: '2026-11-19T10:01:00.000Z', data: {} }, { kind: 'sprint.completed', ts: 'not a time', data: {} }]);
    ok('the newest event by ts decides, not the list order', st.cur === 'reviewer' && st.tone === 'amber', st);
    ok('a missing or non-array event list is "Not started"', sprintProgress(NODES, null).status === 'Not started' && sprintProgress(NODES, [null, {}]).tone === 'idle');
  }

  // edges of the fold the state table does not reach (the mutation sweep found them unpinned)
  {
    ok('a gate with no role: "Running", no row', sprintProgress(NODES, events([['gate.started', {}]])).status === 'Running' && sprintProgress(NODES, events([['gate.started', {}]])).cur === '');
    ok('a running gate never repeats its name (user, t-985c)', sprintProgress(NODES, events([['gate.started', { role: 'evaluator', attempt: '2' }]])).status === 'Running · attempt 2');
    const unk = sprintProgress(NODES, events([['some.future_kind']]));
    ok('a kind the card does not know: idle, named', unk.tone === 'idle' && unk.cur === '' && unk.status === 'some.future_kind', unk);
    const nokind = sprintProgress(NODES, [{ ts: '2026-11-19T10:00:00.000Z', data: {} }]);
    ok('an event with no kind is ignored', nokind.status === 'Not started', nokind);
    const tie = sprintProgress(NODES, [{ kind: 'plan.approved', ts: '2026-11-19T10:00:00.000Z', data: {} }, { kind: 'gate.started', ts: '2026-11-19T10:00:00.000Z', data: { role: 'reviewer' } }]);
    ok('two events at the same ts: the later one in the list decides', tie.cur === 'reviewer', tie);
    const nonodes = sprintProgress(null, events([['gate.finished', { role: 'reviewer' }]]));
    ok('no node list: the fold still answers (no node after Reviewer)', nonodes.tone === 'blue' && nonodes.cur === '', nonodes);
    ok('no node list: the card draws no rows', !progressCardHtml(null, 'normal', { ...sprintProgress(null, []), events: [] }).includes('spc-row'));
    const first = progressCardHtml(NODES, 'normal', { cur: 'start', tone: 'blue', status: 'S', closed: false });
    ok('the first node current: its status in its own title', /data-spc-row="start" title="Start: S"/.test(first) && !first.includes('spc-status'), first);
  }

  // a skipped node keeps .gone and is never .done; Lite and Manual heads; Normal has no head (the rail's label says Sprint progress)
  {
    ok('Manual: the Manual-only node is drawn', rows(progressCardHtml(NODES, 'manual', { ...sprintProgress(NODES, []), events: [] })).some(x => x.id === 'your-test'));
    ok('Normal: the Manual-only node is not drawn', !rows(progressCardHtml(NODES, 'normal', { ...sprintProgress(NODES, []), events: [] })).some(x => x.id === 'your-test'));
    const lite = progressCardHtml(NODES, 'lite', { ...sprintProgress(NODES, events([['gate.started', { role: 'evaluator' }]])), events: [] });
    const r = rows(lite);
    ok('Lite: a skipped node before the current one stays gone, not done', r.find(x => x.id === 'reviewer').cls.includes('gone') && !r.find(x => x.id === 'reviewer').cls.includes('done'));
    ok('Lite: a kept node before the current one is done', r.find(x => x.id === 'security-review').cls.includes('done'));
    ok('Lite: the head names the option', lite.includes('<div class="spc-head">a Lite ticket</div><ol class="spc-rail">'));
    ok('Manual + Lite head', progressCardHtml(NODES, 'both', { ...sprintProgress(NODES, []), events: [] }).includes('a Manual + Lite ticket'));
    ok('Normal: no head', !progressCardHtml(NODES, 'normal', { ...sprintProgress(NODES, []), events: [] }).includes('spc-head'));
  }

  // t-985c: a status with no row (role=sprint refusal, the QA record) is the head line; the rows already passed stay done
  {
    const ref = sprintProgress(NODES, events([['plan.approved'], ['gate.started', { role: 'evaluator' }], ['gate.rejected', { role: 'sprint', reason: 'manual_qa' }]]));
    const h = progressCardHtml(NODES, 'normal', ref);
    ok('a role=sprint refusal is on no row, red, says what to do', ref.cur === '' && ref.tone === 'red' && statusOf(h) === 'Waiting on you: record your manual check', ref);
    ok('under it the rows passed stay done, through the evaluator', rows(h).filter(x => / done\b/.test(x.cls)).map(x => x.id).join() === IDS.slice(0, IDS.indexOf('eval') + 1).join(), rows(h));
    const ev = sprintProgress(NODES, events([['gate.started', { role: 'evaluator' }], ['gate.rejected', { role: 'evaluator', reason: 'manual_qa' }]]));
    ok('check-evidence\'s manual_qa (role evaluator, the VM case): on the Evaluator row, the person\'s step', ev.cur === 'eval' && ev.status === 'Waiting on you: record your manual check', ev);
    const cleared = sprintProgress(NODES, events([['gate.rejected', { role: 'evaluator', reason: 'manual_qa' }], ['manual_qa.recorded', { result: 'pass' }]]));
    ok('...and the QA record clears it', cleared.tone === 'blue' && cleared.status === 'Manual check recorded', cleared);
    const other = sprintProgress(NODES, events([['plan.approved'], ['gate.rejected', { role: 'sprint', reason: 'integrity' }]]));
    ok('another role=sprint refusal: Close refused + reason', other.cur === '' && other.status === 'Close refused: integrity', other);
    const rec = sprintProgress(NODES, events([['gate.started', { role: 'evaluator' }], ['gate.rejected', { role: 'sprint', reason: 'manual_qa' }], ['manual_qa.recorded', { result: 'pass' }]]));
    ok('the QA record clears the refusal: blue, recorded', rec.cur === '' && rec.tone === 'blue' && rec.status === 'Manual check recorded', rec);
    const bad = sprintProgress(NODES, events([['manual_qa.recorded', { result: 'fail' }]]));
    ok('a failed QA record: red, failed', bad.tone === 'red' && bad.status === 'Manual check failed', bad);
    ok('Lite: the close starts at the first row that runs', firstClosing(NODES, 'lite') === 'security-review' && sprintProgress(NODES, events([['close.started']]), { mode: 'lite' }).cur === 'security-review');
    ok('Manual: Your test is not the close\'s first row', firstClosing(NODES, 'manual') === 'code-simplifier');
  }

  // t-985c: each started step's start time (only starts, user), right-aligned; a skipped row keeps its note; the preview has none
  {
    const at = mm => `2026-11-19T10:${mm}:00.000Z`, hm = t => new Date(t).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
    const evs = [
      { kind: 'sprint.started', ts: at('00'), data: {} }, { kind: 'gate.started', ts: at('02'), data: { role: 'speccheck' } },
      { kind: 'plan.approved', ts: at('05'), data: {} }, { kind: 'implement.started', ts: at('06'), data: {} },
      { kind: 'close.started', ts: at('20'), data: {} }, { kind: 'gate.started', ts: at('25'), data: { role: 'reviewer' } },
      { kind: 'gate.started', ts: at('30'), data: { role: 'evaluator' } }, { kind: 'gate.started', ts: at('40'), data: { role: 'evaluator', attempt: '2' } },
    ];
    const t = stepStartTimes(NODES, evs);
    ok('start times by step', t.start === Date.parse(at('00')) && t.plan === Date.parse(at('00')) && t['spec-check'] === Date.parse(at('02')) && t['approve-plan'] === Date.parse(at('05'))
      && t.build === Date.parse(at('06')) && t['code-simplifier'] === Date.parse(at('20')) && t.reviewer === Date.parse(at('25')), t);
    ok('the evaluator\'s newest start counts', t.eval === Date.parse(at('40')), t.eval);
    ok('no Cockpit switch: Build starts at the approval', stepStartTimes(NODES, evs.filter(e => e.kind !== 'implement.started')).build === Date.parse(at('05')));
    ok('a started switch is Build\'s start; a failed one is not', stepStartTimes(NODES, [{ kind: 'build.switch', ts: at('07'), data: { outcome: 'started' } }]).build === Date.parse(at('07'))
      && stepStartTimes(NODES, [{ kind: 'build.switch', ts: at('07'), data: { outcome: 'not_taken' } }]).build === undefined);
    ok('a wrapup row with its own start event', stepStartTimes(NODES, [{ kind: 'wrapup.gate_started', ts: at('21'), data: { gate: 'doc-audit' } }])['doc-audit'] === Date.parse(at('21')));
    const html = progressCardHtml(NODES, 'lite', { ...sprintProgress(NODES, evs, { mode: 'lite' }), times: stepStartTimes(NODES, evs, 'lite') });
    const li = id => html.split('</li>').find(x => x.includes(`data-spc-row="${id}"`)) || '';
    ok('a started row shows its start time, right-aligned', li('approve-plan').includes(`<span class="spc-t">${hm(at('05'))}</span>`), li('approve-plan'));
    ok('a skipped row keeps its note and no time', li('reviewer').includes('skipped · Lite') && !li('reviewer').includes('spc-t'), li('reviewer'));
    ok('a step not started shows no time', !li('close').includes('spc-t'));
    ok('the current row\'s tooltip adds its start time', /title="Evaluator: Running · attempt 2 · started [^"]+"/.test(html), li('eval'));
    ok('no finish times, no event strip', (html.match(/spc-t"/g) || []).length === Object.keys(stepStartTimes(NODES, evs, 'lite')).filter(k => !['spec-check', 'reviewer'].includes(k)).length /* Lite skips these two rows: their note, no time */ && !html.includes('spc-ev'), html.match(/spc-t">[^<]*/g));
  }

  // a status or reason from the log is escaped too
  ok('a refusal reason is escaped', progressCardHtml(NODES, 'normal', { ...sprintProgress(NODES, events([['gate.rejected', { role: 'evaluator', reason: '<img src=x>' }]])), events: [] }).includes('Close refused: &lt;img src=x&gt;'));

  // the preview (no live) is unchanged: no done/cur marks, no live wrapper
  {
    const prev = progressCardHtml(NODES, 'normal');
    ok('the Pipeline preview keeps its head and draws no live state', prev.startsWith('<div class="spc-head">Sprint progress &middot; a Normal ticket</div>') && !/ (done|cur)\b|spc-live|spc-status|spc-t"|title=/.test(prev));
  }

  // a ticket's mode from its demo / manual fields (strings or booleans)
  ok('ticketMode', ticketMode({ demo: 'true' }) === 'lite' && ticketMode({ manual: true }) === 'manual' && ticketMode({ demo: true, manual: 'true' }) === 'both' && ticketMode({ demo: 'false' }) === 'normal' && ticketMode(null) === 'normal');

  // the fixture is canon's real pipeline as the one reader resolves it (the shape /api/v1/pipeline serves): a pipeline.yaml change shows here
  {
    const { execFileSync } = require('child_process');
    let out = null;
    try { out = execFileSync('bash', [path.join(__dirname, '..', 'tools', 'pipeline.sh'), 'resolve', '--full'], { encoding: 'utf8' }); } catch (e) { out = null; }
    if (out === null) console.log('  skip the fixture matches tools/pipeline.sh (bash or the reader unavailable)');
    else {
      const dash = v => (v === '-' ? '' : v);
      const real = out.trim().split('\n').map(l => l.split('\t')).map(f => ({ id: f[1], kind: f[2], order: Number(f[0]), on: f[3] === 'on', skip_on: dash(f[9]), only: dash(f[10]), group: dash(f[5]) }));
      ok('the node fixture equals canon\'s pipeline as tools/pipeline.sh resolves it', JSON.stringify(real) === JSON.stringify(NODES), real.map(n => n.id));
    }
  }

  if (fails) { console.log(`sprint-progress-card: ${fails} failure(s)`); process.exit(1); }
  console.log('sprint-progress-card: ok');
}).catch(e => { console.error('sprint-progress-card: could not load the module:', e.message); process.exit(1); });
