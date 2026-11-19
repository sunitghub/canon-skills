#!/usr/bin/env node
// sprint-progress-card (t-5ef8) — protects the Cockpit rail's Sprint progress card: the fold (sprintProgress) and the live render
// (progressCardHtml with `live`) of tools/sprint-check-app/static/sprint-progress-card.js, the REAL module the board and the shell load.
// Every row of acceptance.md's state table goes through both: the current node, the tone, the status words and the done rows. The rail
// itself (what it fetches, when, and that a switched tab keeps its card) is the board spec's "Sprint progress card in the rail" group.
const path = require('path');
const { pathToFileURL } = require('url');

const CARD = path.join(__dirname, '..', 'tools', 'sprint-check-app', 'static', 'sprint-progress-card.js');
import(pathToFileURL(CARD).href).then(({ sprintProgress, progressCardHtml, ticketMode }) => {
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

  // [name, events (oldest first), options, current node, tone, words the status line holds]
  const STATES = [
    ['no sprint events', [], {}, '', 'idle', ['Not started']],
    ['started, plan empty', [['sprint.started']], {}, 'plan', 'blue', ['Writing the plan']],
    ['started, plan written', [['sprint.started']], { planWritten: true }, 'approve-plan', 'red', ['Waiting on you']],
    ['spec check running', [['sprint.started'], ['gate.started', { role: 'speccheck' }]], {}, 'spec-check', 'amber', ['Spec check running']],
    ['spec check finished', [['gate.finished', { role: 'speccheck', verdict: 'READY' }]], {}, 'approve-plan', 'red', ['Waiting on you']],
    ['plan approved', [['sprint.started'], ['plan.approved']], {}, 'build', 'blue', ['Implementing']],
    ['reviewer running', [['plan.approved'], ['gate.started', { role: 'reviewer', attempt: '2' }]], {}, 'reviewer', 'amber', ['Reviewer running', 'attempt 2']],
    ['reviewer finished', [['gate.finished', { role: 'reviewer', verdict: 'YES' }]], {}, 'security-review', 'blue', ['In your session']],
    ['evaluator running', [['gate.started', { role: 'evaluator', attempt: '1' }]], {}, 'eval', 'amber', ['Evaluator running', 'attempt 1']],
    ['second eval running', [['gate.started', { role: 'evaluator2' }]], {}, 'eval', 'amber', ['Second eval running']],
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
  ];
  for (const [name, evs, opts, cur, tone, words] of STATES) {
    const st = sprintProgress(NODES, events(evs), opts);
    const html = progressCardHtml(NODES, 'normal', { ...st, events: [] });
    const r = rows(html), curRows = r.filter(x => / cur\b/.test(x.cls)).map(x => x.id);
    const done = r.filter(x => / done\b/.test(x.cls)).map(x => x.id);
    const status = (/<(?:span|div) class="spc-status">([^<]*)</.exec(html) || [])[1] || '';
    const wantDone = tone === 'green' ? IDS : cur ? IDS.slice(0, IDS.indexOf(cur)) : [];
    ok(`${name}: current ${cur || '(none)'}`, (cur ? curRows.length === 1 && curRows[0] === cur : curRows.length === 0) && st.cur === cur, { st, curRows });
    ok(`${name}: tone ${tone}`, st.tone === tone && html.includes(`data-tone="${tone}"`), st.tone);
    ok(`${name}: status says ${words.join(' + ')}`, words.every(w => status.includes(w)), status);
    ok(`${name}: done rows`, JSON.stringify(done) === JSON.stringify(wantDone), done);
    ok(`${name}: the status line sits in the current row`, !cur || new RegExp(`data-spc-row="${cur}"[^]*?spc-status`).test(html.split('</li>').find(li => li.includes(`data-spc-row="${cur}"`)) || ''), null);
  }

  // the newest event decides, whatever order the snapshot lists them in; an event with no usable ts counts as oldest
  {
    const st = sprintProgress(NODES, [{ kind: 'gate.started', ts: '2026-11-19T10:05:00.000Z', data: { role: 'reviewer' } }, { kind: 'plan.approved', ts: '2026-11-19T10:01:00.000Z', data: {} }, { kind: 'sprint.completed', ts: 'not a time', data: {} }]);
    ok('the newest event by ts decides, not the list order', st.cur === 'reviewer' && st.tone === 'amber', st);
    ok('a missing or non-array event list is "Not started"', sprintProgress(NODES, null).status === 'Not started' && sprintProgress(NODES, [null, {}]).tone === 'idle');
  }

  // edges of the fold the state table does not reach (the mutation sweep found them unpinned)
  {
    ok('a gate with no role is named "Gate"', sprintProgress(NODES, events([['gate.started', {}]])).status === 'Gate running');
    ok('an unknown role keeps its own name', sprintProgress(NODES, events([['gate.started', { role: 'custom' }]])).status === 'custom running');
    const unk = sprintProgress(NODES, events([['some.future_kind']]));
    ok('a kind the card does not know: idle, named', unk.tone === 'idle' && unk.cur === '' && unk.status === 'some.future_kind', unk);
    const nokind = sprintProgress(NODES, [{ ts: '2026-11-19T10:00:00.000Z', data: {} }]);
    ok('an event with no kind is ignored', nokind.status === 'Not started', nokind);
    const tie = sprintProgress(NODES, [{ kind: 'plan.approved', ts: '2026-11-19T10:00:00.000Z', data: {} }, { kind: 'gate.started', ts: '2026-11-19T10:00:00.000Z', data: { role: 'reviewer' } }]);
    ok('two events at the same ts: the later one in the list decides', tie.cur === 'reviewer', tie);
    const nonodes = sprintProgress(null, events([['gate.finished', { role: 'reviewer' }]]));
    ok('no node list: the fold still answers (no node after Reviewer)', nonodes.tone === 'blue' && nonodes.cur === '', nonodes);
    ok('no node list: the card draws no rows', !progressCardHtml(null, 'normal', { ...sprintProgress(null, []), events: [] }).includes('spc-row'));
    const nodata = progressCardHtml(NODES, 'normal', { ...sprintProgress(NODES, []), events: [{ kind: 'sprint.started', ts: '2026-11-19T10:00:00.000Z' }] });
    ok('an event with no data still draws its line', /<\/span> sprint\.started<\/li>/.test(nodata), nodata);
    const first = progressCardHtml(NODES, 'normal', { cur: 'start', tone: 'blue', status: 'S', closed: false, events: [] });
    ok('the first node current: one status line, in its row', (first.match(/spc-status/g) || []).length === 1 && /data-spc-row="start"[^]*?spc-status/.test(first.split('</li>')[0]));
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

  // the event strip: oldest first as given, local HH:MM:SS, role and attempt, escaped; the empty notes
  {
    const ts = '2026-11-19T10:04:05.000Z', d = new Date(ts), hh = [d.getHours(), d.getMinutes(), d.getSeconds()].map(n => String(n).padStart(2, '0')).join(':');
    const html = progressCardHtml(NODES, 'normal', { ...sprintProgress(NODES, []), events: [{ kind: 'gate.started', ts, data: { role: '<b>x</b>', attempt: '2' } }, { kind: 'sprint.started', ts: 'bad', data: {} }] });
    ok('an event line: local time, kind, role, attempt', html.includes(`<span class="spc-ev-t">${hh}</span> gate.started &lt;b&gt;x&lt;/b&gt; · attempt 2</li>`), html);
    ok('event text is escaped, never markup', !html.includes('<b>x</b>'));
    ok('an event with no usable time shows --:--:--', html.includes('<span class="spc-ev-t">--:--:--</span> sprint.started</li>'));
    ok('no events: the note given', progressCardHtml(NODES, 'normal', { ...sprintProgress(NODES, []), events: [], eventsNote: 'No recent events.' }).includes('<div class="spc-ev-empty">No recent events.</div>'));
    ok('no events and no note: No events yet.', progressCardHtml(NODES, 'normal', { ...sprintProgress(NODES, []), events: [] }).includes('No events yet.'));
  }

  // a status or reason from the log is escaped too
  ok('a refusal reason is escaped', progressCardHtml(NODES, 'normal', { ...sprintProgress(NODES, events([['gate.rejected', { role: 'evaluator', reason: '<img src=x>' }]])), events: [] }).includes('Close refused: &lt;img src=x&gt;'));

  // the preview (no live) is unchanged: no done/cur marks, no live wrapper
  {
    const prev = progressCardHtml(NODES, 'normal');
    ok('the Pipeline preview keeps its head and draws no live state', prev.startsWith('<div class="spc-head">Sprint progress &middot; a Normal ticket</div>') && !/ (done|cur)\b|spc-live|spc-status/.test(prev));
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
