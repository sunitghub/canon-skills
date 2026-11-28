#!/usr/bin/env node
// sprint-progress-card (t-5ef8) — protects the Cockpit rail's Sprint progress card: the fold (sprintProgress) and the live render
// (progressCardHtml with `live`) of tools/sprint-check-app/static/sprint-progress-card.js, the REAL module the board and the shell load.
// Every row of acceptance.md's state table goes through both: the current node, the tone, the status words and the done rows. The rail
// itself (what it fetches, when, and that a switched tab keeps its card) is the board spec's "Sprint progress card in the rail" group.
const path = require('path');
const { pathToFileURL } = require('url');

const CARD = path.join(__dirname, '..', 'tools', 'sprint-check-app', 'static', 'sprint-progress-card.js');
import(pathToFileURL(CARD).href).then(({ sprintProgress, progressCardHtml, ticketMode, stepStartTimes, firstClosing, rowStates, ROW_END, INLINE_GATES, reportFacts, wrapupRows, shortModel, when, fullWhen, groupRows, setupLine }) => {
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
    const own = rowStates(NODES, events(evs));
    const html = progressCardHtml(NODES, 'normal', { ...st, rows: own });
    const r = rows(html), curRows = r.filter(x => / cur\b/.test(x.cls)).map(x => x.id);
    const done = r.filter(x => / done\b/.test(x.cls)).map(x => x.id);
    const status = statusOf(html);
    // t-bcc1: done = the rows whose own end event exists (never the rows above the current one), the current row excepted
    const wantDone = tone === 'green' ? IDS : IDS.filter(id => own[id].state === 'done' && id !== cur);
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
    // t-e371: the card never prints an event's kind; a kind with no status of its own leaves the previous one
    ok('a kind the card does not know is never shown', unk.tone === 'idle' && unk.cur === '' && unk.status === 'Not started', unk);
    const after = sprintProgress(NODES, events([['plan.approved'], ['some.future_kind'], ['implement.started']]));
    ok('a kind with no status after approval keeps Implementing', after.status === 'Implementing' && after.cur === 'build', after);
    for (const k of ['wrapup.gate_started', 'wrapup.gate_finished']) {
      const w = sprintProgress(NODES, events([['plan.approved'], ['close.started'], [k, { gate: 'doc-audit', result: 'ran' }]]));
      const html = progressCardHtml(NODES, 'normal', { ...w, rows: rowStates(NODES, events([['plan.approved'], ['close.started'], [k, { gate: 'doc-audit', result: 'ran' }]])) });
      ok(`${k} newest: Closing, and no kind in the card`, w.status === 'Closing' && !html.includes(k), [w, html.slice(0, 120)]);
    }
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
    ok('Lite: a kept node before the current one with no end event of its own is NOT done (t-bcc1)', !r.find(x => x.id === 'security-review').cls.includes('done'));
    ok('Lite: the head names the option', lite.includes('<div class="spc-head">a Lite ticket</div><ol class="spc-rail">'));
    ok('Manual + Lite head', progressCardHtml(NODES, 'both', { ...sprintProgress(NODES, []), events: [] }).includes('a Manual + Lite ticket'));
    ok('Normal: no head', !progressCardHtml(NODES, 'normal', { ...sprintProgress(NODES, []), events: [] }).includes('spc-head'));
  }

  // t-985c: a status with no row (role=sprint refusal, the QA record) is the head line; the rows already passed stay done
  {
    const ref = sprintProgress(NODES, events([['plan.approved'], ['gate.started', { role: 'evaluator' }], ['gate.rejected', { role: 'sprint', reason: 'manual_qa' }]]));
    const h = progressCardHtml(NODES, 'normal', ref);
    ok('a role=sprint refusal is on no row, red, says what to do', ref.cur === '' && ref.tone === 'red' && statusOf(h) === 'Waiting on you: record your manual check', ref);
    const hr = progressCardHtml(NODES, 'normal', { ...ref, rows: rowStates(NODES, events([['plan.approved'], ['gate.started', { role: 'evaluator' }], ['gate.rejected', { role: 'sprint', reason: 'manual_qa' }]])) });
    ok('under it only the rows with their own end event are done (t-bcc1): plan, approve plan, build', rows(hr).filter(x => / done\b/.test(x.cls)).map(x => x.id).join() === 'plan,approve-plan,build', rows(hr));
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
    // t-e7f6: now is the same day, so each time is the clock alone; a row is its own <li> (a group's parent holds its children)
    const html = progressCardHtml(NODES, 'lite', { ...sprintProgress(NODES, evs, { mode: 'lite' }), times: stepStartTimes(NODES, evs, 'lite'), now: Date.parse(at('50')) });
    const chunks = html.split('<li').map(x => x.split('</li>')[0]);
    const li = id => chunks.find(x => x.includes(`data-spc-row="${id}"`)) || '';
    ok('a started row shows its start time, right-aligned', li('approve-plan').includes(`<span class="spc-t" title="${new Date(at('05')).toLocaleString('en-US', { dateStyle: 'medium', timeStyle: 'short' })}">${hm(at('05'))}</span>`), li('approve-plan'));
    ok('a skipped row keeps its note and no time', li('reviewer').includes('skipped · Lite') && !li('reviewer').includes('spc-t'), li('reviewer'));
    ok('a step not started shows no time', !li('close').includes('spc-t'));
    ok('the current row\'s tooltip adds its start time', /title="Evaluator: Running · attempt 2 · started [^"]+"/.test(html), li('eval'));
    ok('no finish times, no event strip', chunks.filter(x => x.includes('data-spc-row=') && x.includes('class="spc-t"')).length === Object.keys(stepStartTimes(NODES, evs, 'lite')).filter(k => !['spec-check', 'reviewer'].includes(k)).length /* Lite skips these two rows: their note, no time */ && !html.includes('spc-ev'), html.match(/spc-t">[^<]*/g));
  }

  // t-bcc1: each row's state from its own end event (the Windows run, t-pnu4: a skipped Spec check drawn done; a reviewer re-run after the
  // Evaluator passed took the Evaluator's done away; skipped wrapup rows drawn green)
  {
    const li = (html, id) => { const m = new RegExp(`<li class="spc-row([^"]*)" data-spc-row="${id}"[^]*?</li>`).exec(html); return m ? m[0] : ''; };
    // events() numbers seconds 0-9 only: this block's lists are longer, so it gives each its own minute
    const evts = list => list.map(([kind, data], i) => ({ kind, ts: `2026-11-19T10:${String(i).padStart(2, '0')}:00.000Z`, data: { ticket: 't-1', ...(data || {}) } }));
    const draw = list => { const ev = evts(list); return progressCardHtml(NODES, 'normal', { ...sprintProgress(NODES, ev), rows: rowStates(NODES, ev) }); };
    // the spec check never ran, the plan was approved: "not run", not done
    let h = draw([['sprint.started'], ['plan.approved']]);
    ok('spec check skipped: not done, "not run"', !/ done\b/.test(li(h, 'spec-check').slice(0, 60)) && li(h, 'spec-check').includes('<span class="spc-note skip">not run</span>'), li(h, 'spec-check'));
    ok('...while Start, Plan and Approve plan are done from their own events', ['start', 'plan', 'approve-plan'].every(id => / done\b/.test(li(h, id).slice(0, 60))), h);
    // a spec check that ran is done and never "not run"
    h = draw([['sprint.started'], ['gate.started', { role: 'speccheck' }], ['gate.finished', { role: 'speccheck', verdict: 'READY' }], ['plan.approved']]);
    ok('spec check ran: done', / done\b/.test(li(h, 'spec-check').slice(0, 60)) && !li(h, 'spec-check').includes('not run'), li(h, 'spec-check'));
    // the t-pnu4 close: evaluator passed, then a third reviewer run; wrapup rows ran or skipped
    const close = [['sprint.started'], ['plan.approved'], ['close.started'],
      ['wrapup.gate_finished', { gate: 'code-simplifier', result: 'ran' }], ['wrapup.gate_finished', { gate: 'doc-audit', result: 'skipped' }],
      ['gate.started', { role: 'reviewer' }], ['gate.finished', { role: 'reviewer', verdict: 'YES' }],
      ['wrapup.gate_finished', { gate: 'security-review', result: 'ran' }],
      ['gate.started', { role: 'evaluator' }], ['gate.finished', { role: 'evaluator', verdict: 'pass' }],
      ['gate.started', { role: 'reviewer' }], ['gate.finished', { role: 'reviewer', verdict: 'YES' }], ['gate.started', { role: 'reviewer' }]];
    h = draw(close);
    ok('a reviewer re-run after the pass leaves the Evaluator done', / done\b/.test(li(h, 'eval').slice(0, 60)), li(h, 'eval'));
    ok('the current row is never also done, though its own end event exists (the re-run reviewer)', !/ done\b/.test(li(h, 'reviewer').slice(0, 60)), li(h, 'reviewer'));
    ok('...the Reviewer is current and says run 3', / cur\b/.test(li(h, 'reviewer').slice(0, 60)) && /title="Reviewer: Running/.test(li(h, 'reviewer')), li(h, 'reviewer'));
    ok('a wrapup row that ran is done; one skipped is "skipped", not done; one with no event is neither', / done\b/.test(li(h, 'code-simplifier').slice(0, 60))
      && !/ done\b/.test(li(h, 'doc-audit').slice(0, 60)) && li(h, 'doc-audit').includes('<span class="spc-note skip">skipped</span>')
      && !/ done\b/.test(li(h, 'code-reviewer').slice(0, 60)) && !li(h, 'code-reviewer').includes('spc-note'), [li(h, 'doc-audit'), li(h, 'code-reviewer')]);
    ok('security-review done from its own event, after the reviewer', / done\b/.test(li(h, 'security-review').slice(0, 60)));
    const rs = rowStates(NODES, evts(close));
    // the whole table, written out (not derived from rowStates): each row's own state after the t-pnu4 close
    const want = { start: 'done', plan: 'done', 'spec-check': 'notrun', 'approve-plan': 'done', build: 'done', 'your-test': '', 'code-simplifier': 'done',
      'code-reviewer': '', 'doc-audit': 'skipped', 'skill-eval': '', 'break-it': '', reviewer: 'done', 'security-review': 'done', 'mutation-test': '', 'test-stamp': '', eval: 'done', close: '' };
    ok('each row\'s own state after the close, row by row', Object.entries(want).every(([id, st]) => rs[id] && rs[id].state === st), Object.fromEntries(Object.entries(rs).map(([k, v]) => [k, v.state])));
    const before = rowStates(NODES, evts([['sprint.started']]));
    ok('before any close event: nothing past Start is done, Spec check not yet "not run"', Object.entries(before).every(([id, v]) => v.state === (id === 'start' ? 'done' : '')), before);
    // t-a4e8: the full-suite stamp row ends on its own evidence.stamped (name test-sh): exit 0 done, else failed; another log never
    const ts = (data) => rowStates(NODES, evts([['evidence.stamped', data]]))['test-stamp'].state;
    ok('test-stamp: done on a test-sh stamp with exit 0, failed on exit 1, nothing on another log', ts({ name: 'test-sh', exit: '0' }) === 'done' && ts({ name: 'test-sh', exit: '1' }) === 'failed' && ts({ name: 'pre-gate', exit: '0' }) === '');
    ok('a sprint.completed closes the Close row', rowStates(NODES, evts([['sprint.completed']])).close.state === 'done');
    ok('a started spec check that has not finished is neither done nor "not run"', rowStates(NODES, evts([['gate.started', { role: 'speccheck' }], ['plan.approved']]))['spec-check'].state === '');
    ok('Build from each close signal alone: close.started, a reviewer gate, an evaluator2 gate; not a speccheck gate',
      ['close.started', 'gate.started:reviewer', 'gate.finished:evaluator2'].every(k => { const [kind, r] = k.split(':'); return rowStates(NODES, evts([[kind, r ? { role: r } : {}]])).build.state === 'done'; })
      && rowStates(NODES, evts([['gate.started', { role: 'speccheck' }]])).build.state === '');
    ok('one run shows no "run 1"', !li(draw([['gate.started', { role: 'reviewer' }], ['gate.finished', { role: 'reviewer', verdict: 'YES' }], ['close.confirmed']]), 'reviewer').includes('run '));
    ok('an event list with holes and no ts sorts and folds', rowStates(NODES, [null, { kind: 'plan.approved' }, { ts: 'x' }, { kind: 'gate.finished', ts: '2026-11-19T10:00:00.000Z', data: { role: 'reviewer' } }]).reviewer.state === 'done');
    ok('the newest wrapup result for a gate wins', rowStates(NODES, evts([['wrapup.gate_finished', { gate: 'doc-audit', result: 'skipped' }], ['wrapup.gate_finished', { gate: 'doc-audit', result: 'ran' }]]))['doc-audit'].state === 'done');
    ok('run counts per role: reviewer 3, evaluator 1, spec check 0', rs.reviewer.runs === 3 && rs.eval.runs === 1 && rs['spec-check'].runs === 0, rs);
    h = draw(close.slice(0, -1));   // the third run not started: the Reviewer row is not current, shows "run 2"
    ok('a gate row that ran twice shows "Run 2" on its second line', li(h, 'reviewer').includes('<span class="spc-sub">Run 2</span>'), li(h, 'reviewer'));
    ok('the Second eval never counts as an Evaluator run', rowStates(NODES, events([['gate.started', { role: 'evaluator' }], ['gate.started', { role: 'evaluator2' }]])).eval.runs === 1);
    ok('a failed evaluator: not done, "failed" once it is not current', (() => { const x = draw([['gate.finished', { role: 'evaluator', verdict: 'fail' }], ['gate.started', { role: 'reviewer' }]]); return !/ done\b/.test(li(x, 'eval').slice(0, 60)) && li(x, 'eval').includes('<span class="spc-note fail">failed</span>'); })());
    ok('Build is done once the close began, not before', rowStates(NODES, events([['plan.approved']])).build.state === '' && rowStates(NODES, events([['plan.approved'], ['wrapup.gate_finished', { gate: 'doc-audit', result: 'ran' }]])).build.state === 'done');
    { const ev = evts([['plan.approved'], ['manual_qa.recorded', { result: 'pass' }], ['close.started']]);
      const m = progressCardHtml(NODES, 'manual', { ...sprintProgress(NODES, ev, { mode: 'manual' }), rows: rowStates(NODES, ev) });
      ok('a Your test row done from its record drops "waiting for your test" (t-bcc1 reviewer)', / done\b/.test(li(m, 'your-test').slice(0, 60)) && !li(m, 'your-test').includes('waiting for your test'), li(m, 'your-test')); }
    ok('your test: a passing record is done, a failing one failed', rowStates(NODES, events([['manual_qa.recorded', { result: 'pass' }]]))['your-test'].state === 'done' && rowStates(NODES, events([['manual_qa.recorded', { result: 'fail' }]]))['your-test'].state === 'failed');
    // the snapshot and the events window both hold an event: counted once
    const dup = events([['gate.started', { role: 'reviewer' }]]).map(e => ({ ...e, id: 'x1' }));
    ok('an event in both the snapshot and the window counts once', rowStates(NODES, [...dup, ...dup]).reviewer.runs === 1);
    ok('every inline gate is a pipeline node with an end kind', INLINE_GATES.every(g => NODES.some(n => n.id === g) && ROW_END[g]));
  }

  // t-3df9 + t-3e06: the second line names the model a row ran on (never a guess); t-e371: a report or a Wrapup Gates row stands in for a
  // missing event. Protects the Cockpit rail's Sprint progress card.
  {
    const li2 = (html, id) => { const m = new RegExp(`<li[^>]*data-spc-row="${id}"[\\s\\S]*?</li>`).exec(html); return m ? m[0] : ''; };
    const draw2 = (list, art) => { const ev = events(list); return progressCardHtml(NODES, 'normal', { ...sprintProgress(NODES, ev), rows: rowStates(NODES, ev, art) }); };
    const ran = draw2([['plan.approved'], ['implement.started', { model: 'claude-sonnet-5-5' }], ['gate.started', { role: 'reviewer' }], ['gate.finished', { role: 'reviewer', verdict: 'YES', model: 'gpt-6-luna' }],
      ['gate.started', { role: 'evaluator' }], ['gate.finished', { role: 'evaluator', verdict: 'fail', model: 'sonnet' }], ['gate.started', { role: 'evaluator' }], ['gate.finished', { role: 'evaluator', verdict: 'pass', model: 'claude-opus-5-5' }],
      ['build.switch', { stage: 'close', outcome: 'started', model: 'claude-sonnet-5.5' }]]);
    ok('an agent row that ran shows its model, full id in the title', li2(ran, 'reviewer').includes('<span class="spc-sub" title="gpt-6-luna">GPT-6 Luna</span>'), li2(ran, 'reviewer'));
    ok('a second run on another model shows the latest and Run 2', li2(ran, 'eval').includes('>Opus 5.5 · Run 2</span>'), li2(ran, 'eval'));
    ok('Build shows implement.started\'s model', li2(ran, 'build').includes('>Sonnet 5.5</span>'), li2(ran, 'build'));
    ok('Close shows the Close switch\'s model, as the session\'s (t-e7f6)', li2(ran, 'close').includes('title="claude-sonnet-5.5">Session: Sonnet 5.5</span>'), li2(ran, 'close'));
    ok('the name stays on line 1 with its chip, before the second line', /<span class="spc-n">Reviewer<\/span><span class="spc-k agent">Agent<\/span><span class="spc-sub"/.test(li2(ran, 'reviewer')), li2(ran, 'reviewer'));
    const before = draw2([['plan.approved']]);
    ok('a row that has not run has no second line (no preview)', !li2(before, 'reviewer').includes('spc-sub') && !li2(before, 'eval').includes('spc-sub') && !li2(before, 'close').includes('spc-sub'), [li2(before, 'reviewer'), li2(before, 'close')]);
    ok('the Close switch never moves the card back to Build', sprintProgress(NODES, events([['plan.approved'], ['close.started'], ['build.switch', { stage: 'close', outcome: 'started' }]])).status === 'Closing'
      && sprintProgress(NODES, events([['plan.approved'], ['close.started'], ['build.switch', { stage: 'close', outcome: 'not_taken', attempts: '3' }]])).status.startsWith('Close switch:'));
    ok('a Close switch is not Build\'s start time', stepStartTimes(NODES, events([['plan.approved'], ['build.switch', { stage: 'close', outcome: 'started' }]])).build === stepStartTimes(NODES, events([['plan.approved']])).build);
    // reports stand in for a missing gate.finished
    const facts = reportFacts('# Spec check\n\nModel: sonnet (Admin Spec check default, claude)\n\n## Verdict\nGAPS — two.\n');
    ok('reportFacts reads the verdict word and the Model line', facts.verdict === 'gaps' && facts.model === 'sonnet', facts);
    ok('reportFacts: bold YES under the heading, pass: prefix, nothing', reportFacts('## Verdict\n\n**YES** fine').verdict === 'yes' && reportFacts('## Verdict\n\npass: all hold').verdict === 'pass' && reportFacts('no verdict here').verdict === '');
    const art = { reports: { speccheck: { verdict: 'ready', model: 'sonnet' }, reviewer: { verdict: 'yes', model: 'gpt-6-luna' }, evaluator: { verdict: 'pass', model: 'claude-sonnet-5-5' } } };
    const rs = rowStates(NODES, events([['plan.approved'], ['gate.started', { role: 'speccheck' }], ['gate.started', { role: 'reviewer' }], ['gate.started', { role: 'evaluator' }]]), art);
    ok('a report with a verdict marks Spec check, Reviewer and Evaluator done, with the report\'s model', rs['spec-check'].state === 'done' && rs.reviewer.state === 'done' && rs.eval.state === 'done' && rs.reviewer.model === 'gpt-6-luna', rs);
    ok('a spec check that never logged its start reads done from its report, not "not run"', rowStates(NODES, events([['plan.approved']]), art)['spec-check'].state === 'done');
    ok('an evaluator report other than pass is failed', rowStates(NODES, events([['plan.approved']]), { reports: { evaluator: { verdict: 'fail' } } }).eval.state === 'failed');
    ok('no report and no event: not run / empty, as before', rowStates(NODES, events([['plan.approved']]), {})['spec-check'].state === 'notrun' && rowStates(NODES, events([['plan.approved']]), {}).reviewer.state === '');
    const acc = '## Criteria\n| doc-audit | ran | not this table |\n\n## Wrapup Gates\n| Gate | Status | Notes |\n|---|---|---|\n| security-review | ran | ok |\n| mutation-test | skipped | no logic |\n| reviewer | ran | YES |\n';
    const wr = wrapupRows(acc);
    ok('wrapupRows reads only the Wrapup Gates table\'s inline gates', JSON.stringify(wr) === JSON.stringify({ 'security-review': 'ran', 'mutation-test': 'skipped' }), wr);
    const rw = rowStates(NODES, events([['plan.approved'], ['close.started']]), { wrapup: wr });
    ok('a hand-typed Wrapup Gates row turns its gate done or skipped', rw['security-review'].state === 'done' && rw['mutation-test'].state === 'skipped' && rw['doc-audit'].state === '', rw);
    ok('shortModel', shortModel('claude-sonnet-5-5') === 'Sonnet 5.5' && shortModel('claude-haiku-4-5-20251001') === 'Haiku 4.5' && shortModel('claude-opus-5.5') === 'Opus 5.5' && shortModel('gpt-6-luna') === 'GPT-6 Luna'
      && shortModel('sonnet') === 'Sonnet' && shortModel('Claude Sonnet 5.5') === 'Sonnet 5.5' && shortModel('') === '', ['claude-sonnet-5-5', 'gpt-6-luna', 'Claude Sonnet 5.5'].map(shortModel));
    ok('a model from the log is escaped', draw2([['gate.finished', { role: 'reviewer', verdict: 'YES', model: '<img src=x>' }]]).includes('&lt;img'));
    // mutation survivors (t-3e06 sweep): each pins one rule the fold or a reader holds
    ok('a Close switch is never the Build row', sprintProgress(NODES, events([['plan.approved'], ['close.started'], ['build.switch', { stage: 'close', outcome: 'started' }]])).cur !== 'build'
      && sprintProgress(NODES, events([['plan.approved'], ['build.switch', { outcome: 'started' }]])).cur === 'build');
    ok('wrapup.gate_started makes its gate the current row; an unknown gate none', sprintProgress(NODES, events([['plan.approved'], ['close.started'], ['wrapup.gate_started', { gate: 'doc-audit' }]])).cur === 'doc-audit'
      && sprintProgress(NODES, events([['plan.approved'], ['close.started'], ['wrapup.gate_started', { gate: 'nope' }]])).cur === '');
    ok('only a started Close switch names the Close model', rowStates(NODES, events([['build.switch', { outcome: 'started', model: 'haiku' }], ['build.switch', { stage: 'close', outcome: 'not_taken', model: 'opus' }]])).close.model === '');
    ok('a gate event with no model falls back to its report\'s', rowStates(NODES, events([['gate.finished', { role: 'reviewer', verdict: 'YES' }]]), { reports: { reviewer: { verdict: 'yes', model: 'sonnet' } } }).reviewer.model === 'sonnet');
    ok('a report without a verdict does not mark its row done', rowStates(NODES, events([['plan.approved'], ['close.started']]), { reports: { reviewer: { verdict: '', model: 'sonnet' } } }).reviewer.state === '');
    ok('wrapupRows stops at the next heading and needs ran/skipped first', JSON.stringify(wrapupRows('## Wrapup Gates\n| doc-audit | was ran | x |\n| security-review | ran | x |\n## Later\n| mutation-test | ran | x |\n')) === JSON.stringify({ 'security-review': 'ran' }));
    ok('reportFacts: a heading right under Verdict is no verdict; Model must start its line', reportFacts('## Verdict\n## Next\nYES').verdict === '' && reportFacts('Gate Model: opus\n').model === '');
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


  // t-e7f6 (1): a time from an earlier day carries its date; today's is the clock alone; the tooltip is the full date and time
  {
    const t = new Date(2026, 10, 25, 18, 48).getTime(), sameDay = new Date(2026, 10, 25, 23, 0).getTime(), nextDay = new Date(2026, 10, 26, 0, 5).getTime();
    ok('today: the clock alone', when(t, sameDay) === '6:48 PM', when(t, sameDay));
    ok('an earlier day: M/D then the clock', when(t, nextDay) === '11/25 6:48 PM', when(t, nextDay));
    ok('the full date and time', fullWhen(t) === 'Nov 25, 2026, 6:48 PM', fullWhen(t));
    const live = { ...sprintProgress(NODES, []), times: { start: t }, now: nextDay };
    ok('a row from an earlier day shows its date, the tooltip the full date', progressCardHtml(NODES, 'normal', live).includes('<span class="spc-t" title="Nov 25, 2026, 6:48 PM">11/25 6:48 PM</span>'));
  }

  // t-e7f6 (2a): two groups by position, in pipeline order; Your test stays its own row; a reordered wrapup moves the children
  {
    const shape = list => groupRows(list).map(x => x.kids ? `${x.group}[${x.kids.map(k => k.id).join(',')}]` : x.id).join(' ');
    ok('Wrapup gates before the Reviewer, Close gates from it to Close', shape(NODES) === 'start plan spec-check approve-plan build your-test wrapup[code-simplifier,code-reviewer,doc-audit,skill-eval,break-it] close[reviewer,security-review,mutation-test,test-stamp,eval] close', shape(NODES));
    const swapped = NODES.slice(); const i = swapped.findIndex(n => n.id === 'code-simplifier'), j = swapped.findIndex(n => n.id === 'doc-audit');
    [swapped[i], swapped[j]] = [swapped[j], swapped[i]];
    ok('a project\'s wrapup order moves the children', shape(swapped).includes('wrapup[doc-audit,code-reviewer,code-simplifier,skill-eval,break-it]'), shape(swapped));
    ok('no Build or Close: flat', shape(NODES.filter(n => n.id !== 'close')) === NODES.filter(n => n.id !== 'close').map(n => n.id).join(' '));
    const off = NODES.map(n => n.id === 'doc-audit' ? { ...n, on: false } : n);
    const pv = progressCardHtml(off, 'normal');
    ok('the preview draws both parents with their children nested, an off child struck through', /data-spc-grp="wrapup"[^]*?<ol class="spc-rail spc-kids">[^]*?data-spc-row="doc-audit"/.test(pv)
      && /<li class="spc-row gone" data-spc-row="doc-audit"/.test(pv) && /data-spc-grp="close"[^]*?data-spc-row="eval"/.test(pv) && !pv.includes('spc-count'));
  }

  // t-e7f6 (2b): a parent's n of m, worst child state, and start-end time
  {
    const T = m => Date.parse(`2026-11-19T10:${String(m).padStart(2, '0')}:00.000Z`);
    const ev = (kind, m, data) => ({ kind, ts: new Date(T(m)).toISOString(), data: { ticket: 't-1', ...data } });
    const grp = (html, g) => (new RegExp(`<li class="spc-grp([^"]*)" data-spc-grp="${g}">[^]*?(?=<ol)`).exec(html) || ['', ''])
    const draw = (evs, extra = {}) => { const rows = rowStates(NODES, evs, extra.art || {}); return progressCardHtml(NODES, 'normal', { ...sprintProgress(NODES, evs), rows, times: stepStartTimes(NODES, evs), now: T(59), ...extra }); };
    const wrap = ['code-simplifier', 'code-reviewer', 'doc-audit', 'skill-eval', 'break-it'];
    let evs = [ev('plan.approved', 1), ev('close.started', 10), ev('wrapup.gate_finished', 12, { gate: 'code-simplifier', result: 'ran' }), ev('wrapup.gate_finished', 14, { gate: 'code-reviewer', result: 'skipped' })];
    let [g, cls] = grp(draw(evs), 'wrapup');
    ok('n of m counts done and skipped children', g.includes('<span class="spc-note spc-count">2 of 5</span>'), g);
    ok('a part-done group starts at its first child\'s start, no end yet', g.includes(`>${when(T(10), T(59))}</span>`) && !g.includes('–'), g);
    ok('a part-done group is neither done nor failed', !/ grp-done| grp-fail/.test(cls), cls);
    evs = [...evs, ...wrap.slice(2).map((id, k) => ev('wrapup.gate_finished', 20 + k, { gate: id, result: 'ran' }))];
    [g, cls] = grp(draw(evs), 'wrapup');
    ok('every child through: done, 5 of 5, start-end to the latest end event', / grp-done/.test(cls) && g.includes('5 of 5') && g.includes(`>${when(T(10), T(59))}–${new Date(T(22)).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })}</span>`), g);
    ok('the parent tooltip names both full times', g.includes(`title="${fullWhen(T(10))} – ${fullWhen(T(22))}"`), g);
    const rev = [...evs, ev('gate.started', 30, { role: 'reviewer' })];
    [g, cls] = grp(draw(rev), 'close');
    ok('a running child makes its parent current', / grp-cur/.test(cls) && g.includes('0 of 5'), [cls, g]);
    const failed = [...rev, ev('gate.finished', 31, { role: 'reviewer', verdict: 'YES' }), ev('gate.started', 32, { role: 'evaluator' }), ev('gate.finished', 40, { role: 'evaluator', verdict: 'fail' })];
    [, cls] = grp(draw(failed), 'close');
    ok('a failed child makes its parent failed', / grp-fail/.test(cls), cls);
    const art = { wrapup: Object.fromEntries(wrap.map(id => [id, 'skipped'])) };
    [g, cls] = grp(draw([ev('plan.approved', 1)], { art }), 'wrapup');
    ok('skips read from acceptance.md: done, with no end time', / grp-done/.test(cls) && g.includes('5 of 5') && !g.includes('–'), g);
    const lite = progressCardHtml(NODES, 'lite', { ...sprintProgress(NODES, []), rows: {}, times: { 'code-simplifier': T(10) } });
    [g, cls] = grp(lite, 'wrapup');
    ok('a group whose children all skip on this ticket: struck through, no count, no time', / grp-gone/.test(cls) && !g.includes('spc-count') && !g.includes('spc-t'), [cls, g]);
  }

  // t-e7f6 (3b): a running gate shows the model on its gate.started; once it finishes, the finished event's
  {
    const ev = (kind, s, data) => ({ kind, ts: `2026-11-19T10:00:${String(s).padStart(2, '0')}.000Z`, data: { ticket: 't-1', ...data } });
    let r = rowStates(NODES, [ev('gate.started', 1, { role: 'evaluator', model: 'sonnet' })]);
    ok('a running gate: its started event\'s model', r.eval.model === 'sonnet', r.eval);
    r = rowStates(NODES, [ev('gate.started', 1, { role: 'evaluator', model: 'sonnet' }), ev('gate.finished', 2, { role: 'evaluator', verdict: 'fail', model: 'claude-sonnet-5-5' })]);
    ok('a finished gate: the finished event\'s model', r.eval.model === 'claude-sonnet-5-5', r.eval);
    r = rowStates(NODES, [ev('gate.finished', 2, { role: 'evaluator', verdict: 'fail', model: 'claude-sonnet-5-5' }), ev('gate.started', 3, { role: 'evaluator', model: 'opus' })]);
    ok('a re-run after a finish: the new start\'s model', r.eval.model === 'opus', r.eval);
    r = rowStates(NODES, [ev('gate.started', 1, { role: 'reviewer', model: 'haiku' })]);
    ok('a running gate\'s model is on the card while it runs', progressCardHtml(NODES, 'normal', { ...sprintProgress(NODES, []), rows: r }).includes('title="haiku">Haiku</span>'));
  }

  // t-e7f6 (4): the setup line under the rail's label: preset and template names, never a guess
  {
    const st = data => ({ kind: 'sprint.started', data });
    const presets = [{ id: 'economy', name: 'Economy' }, { id: 'balanced', name: 'Balanced' }];
    const pipe = { digest: 'abcdef012345', template: 'trimmed-close', templates: [{ id: 'canon-default', name: "canon's default" }, { id: 'trimmed-close', name: 'Trimmed close' }] };
    ok('preset and canon\'s default', setupLine(st({ run_preset: 'economy', run_pipeline: 'canon-default' }), presets, pipe) === "Economy · canon's default");
    ok('a digest equal to the project\'s names its template', setupLine(st({ run_preset: 'balanced', run_pipeline: 'abcdef012345' }), presets, pipe) === 'Balanced · Trimmed close');
    ok('a matching digest with no template: Custom pipeline', setupLine(st({ run_pipeline: 'abcdef012345' }), presets, { ...pipe, template: '' }) === 'Custom pipeline');
    ok('a digest that differs (changed since start): Custom pipeline', setupLine(st({ run_pipeline: '999999999999' }), presets, pipe) === 'Custom pipeline');
    ok('custom preset; an unknown preset id shown as its id', setupLine(st({ run_preset: 'custom' }), null, null) === 'Custom' && setupLine(st({ run_preset: 'mine-1' }), presets, null) === 'mine-1');
    ok('failed reads leave that half out', setupLine(st({ run_preset: 'economy', run_pipeline: 'abcdef012345' }), null, null) === '' && setupLine(st({ run_preset: 'economy', run_pipeline: 'canon-default' }), null, null) === "canon's default");
    ok('no sprint.started: no line', setupLine(undefined, presets, pipe) === '' && !progressCardHtml(NODES, 'normal', { ...sprintProgress(NODES, []), setup: '' }).includes('spc-setup'));
    const h = progressCardHtml(NODES, 'normal', { ...sprintProgress(NODES, []), setup: "Economy · canon's <b>" });
    ok('the line is first, escaped, with where each is set', /^<div class="spc-live"[^>]*><div class="spc-setup" title="Model tiers preset \(Admin › Model tiers\) · pipeline template \(Factory › Pipeline\)">Economy · canon&#39;s &lt;b&gt;<\/div><div class="spc-status">/.test(h), h.slice(0, 260));
  }

  if (fails) { console.log(`sprint-progress-card: ${fails} failure(s)`); process.exit(1); }
  console.log('sprint-progress-card: ok');
}).catch(e => { console.error('sprint-progress-card: could not load the module:', e.message); process.exit(1); });
