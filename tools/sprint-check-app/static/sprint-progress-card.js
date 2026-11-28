// t-2755: the Sprint progress card, drawn from the resolved pipeline's nodes for one kind of ticket. One pure function, so the Pipeline tab's
// "Preview a ticket" and a ticket's live card in the Cockpit rail (t-5ef8) draw the same list and cannot drift. Display only: it builds a
// string from the nodes it is given, escapes every value, and sends nothing.
import { esc } from './html-escape.js';

const LABEL = { start: 'Start', plan: 'Plan', 'spec-check': 'Spec check', 'approve-plan': 'Approve plan', build: 'Build', 'your-test': 'Your test', reviewer: 'Reviewer', eval: 'Evaluator', close: 'Close' };
export const TAG = { step: 'Step', gate: 'Gate', agent: 'Agent', you: 'You' };
export const MODES = [['normal', 'Normal'], ['lite', 'Lite'], ['manual', 'Manual'], ['both', 'Manual + Lite']];
export const label = id => LABEL[id] || id;
const isLite = m => m === 'lite' || m === 'both';
const isManual = m => m === 'manual' || m === 'both';

// the options of a ticket of this kind that skip the node: '', 'Lite', 'Manual' or 'Lite + Manual' (the node's skip_on, from pipeline.yaml)
export function skippedBy(n, mode) {
  const on = (n.skip_on || '').split(',');
  return [isLite(mode) && on.includes('lite') ? 'Lite' : '', isManual(mode) && on.includes('manual') ? 'Manual' : ''].filter(Boolean).join(' + ');
}

// each row: what the ticket of this kind does at the node. A node only Manual tickets have is left out of the others.
function note(n, mode) {
  if (n.on === false) return ['off', 'off in this project'];
  const sb = skippedBy(n, mode);
  if (sb) return ['skip', 'skipped · ' + sb];
  if (n.id === 'your-test') return ['wait', 'waiting for your test'];
  if (n.id === 'eval' && isManual(mode)) return ['ro', 'read-only audit'];
  if (n.id === 'eval' && isLite(mode)) return ['ro', 'Haiku'];
  return ['', ''];
}

// t-5ef8: a ticket's mode from its demo (Lite) and manual flags, the same values the preview tabs use.
export function ticketMode(t) {
  const lite = String(t && t.demo) === 'true', manual = String(t && t.manual) === 'true';
  return lite && manual ? 'both' : lite ? 'lite' : manual ? 'manual' : 'normal';
}

const ROLE_NODE = { speccheck: 'spec-check', reviewer: 'reviewer', evaluator: 'eval', evaluator2: 'eval' };
const tsOf = e => { const n = Date.parse(e && e.ts); return Number.isFinite(n) ? n : -Infinity; };
const attemptOf = d => (d && d.attempt ? ` · attempt ${d.attempt}` : '');
const SWITCH_FAIL = { // t-985c: a Build switch that did not start the build (t-d2ab's build.switch outcomes)
  not_taken: d => `Build switch: the continue line was not taken (${d.attempts || '?'} tries); type continue`,
  not_at_rest: d => `Build switch: the session was not ready (${d.reason || 'unknown'})`,
  write_error: () => 'Build switch: could not type into the session',
};

// t-985c: the first step of the close that runs for a ticket of this kind: the first node after Build that is not Your test and not
// skipped or off (Lite skips the inline wrapup gates, so its first is security-review).
export function firstClosing(nodes, mode) {
  const ns = nodes || [], b = ns.findIndex(n => n.id === 'build');
  const n = ns.slice(b + 1).find(x => x.id !== 'your-test' && x.on !== false && !skippedBy(x, mode));
  return n ? n.id : '';
}

// the row an event puts the card on ('' for none); fold() reads it for the newest event and for the last row reached
function rowOf(e, ids, mode, nodes, planWritten) {
  const d = (e && e.data) || {}, role = String(d.role || '');
  switch (e && e.kind) {
    case 'sprint.started': return planWritten ? 'approve-plan' : 'plan';
    case 'plan.approved': return 'build';
    case 'build.switch': return d.stage === 'close' ? '' : 'build';   // t-3e06: the Close switch keeps the close's own rows
    case 'close.started': return firstClosing(nodes, mode);
    case 'gate.started': case 'gate.rejected': return ROLE_NODE[role] || '';
    case 'gate.finished':
      if (role === 'speccheck') return 'approve-plan';
      if (role === 'reviewer') return ids[ids.indexOf('reviewer') + 1] || '';
      return d.verdict === 'pass' ? 'close' : ROLE_NODE[role] || '';
    case 'close.confirmed': return 'close';
    case 'wrapup.gate_started': return ids.includes(String(d.gate || '')) ? String(d.gate) : '';
    default: return '';
  }
}

// t-e371: the kinds that carry a status of their own; the card never shows an event's kind (a stray `wrapup.gate_finished` line above Start)
const STATUS_KINDS = new Set(['sprint.started', 'plan.approved', 'build.switch', 'close.started', 'gate.started', 'gate.rejected', 'manual_qa.recorded',
  'gate.finished', 'close.confirmed', 'sprint.completed', 'wrapup.gate_started', 'wrapup.gate_finished']);

// t-5ef8: the live card's state, folded from GET /api/v1/sprint/<ticket>'s events (the latest of each lifecycle kind). The newest event
// decides the current node; planWritten (plan.md's Approach has content: nothing emits plan.written yet) and needsYou (the session waits
// on the person) refine it. Returns { cur: node id or '', reached: the last row reached when cur is '', tone: idle|blue|amber|red|green,
// status, closed }. Pure: no fetch, no DOM.
export function sprintProgress(nodes, events, { planWritten = false, needsYou = false, mode = 'normal' } = {}) {
  const ids = (nodes || []).map(n => n.id);
  const evs = (Array.isArray(events) ? events : []).filter(e => e && STATUS_KINDS.has(e.kind)).sort((a, b) => tsOf(a) - tsOf(b));
  const latest = evs.length ? evs[evs.length - 1] : null;
  const d = (latest && latest.data) || {};
  // t-985c: a status with no row of its own (a manual_qa refusal, the QA record) keeps the rows already passed done
  const reachedEv = [...evs].reverse().find(e => rowOf(e, ids, mode, nodes, planWritten));
  const reached = reachedEv ? rowOf(reachedEv, ids, mode, nodes, planWritten) : '';
  const cur = latest ? rowOf(latest, ids, mode, nodes, planWritten) : '';
  let r;
  switch (latest ? latest.kind : '') {
    case '': r = { cur: '', tone: 'idle', status: 'Not started' }; break;
    case 'sprint.started':
      r = planWritten ? { cur, tone: 'red', status: 'Waiting on you: approve the plan' } : { cur, tone: 'blue', status: 'Writing the plan' };
      break;
    case 'plan.approved': r = { cur, tone: 'blue', status: 'Implementing' }; break;
    case 'build.switch': {
      const close = d.stage === 'close';
      r = SWITCH_FAIL[d.outcome] ? { cur, tone: 'red', status: SWITCH_FAIL[d.outcome](d).replace(/^Build/, close ? 'Close' : 'Build') } : { cur, tone: 'blue', status: close ? 'Closing' : 'Implementing' };
      break;
    }
    case 'wrapup.gate_started': case 'wrapup.gate_finished': r = { cur, tone: 'blue', status: 'Closing' }; break;   // t-e371: never the kind
    case 'close.started': r = { cur, tone: 'blue', status: 'Closing' }; break;
    case 'gate.started': r = { cur, tone: 'amber', status: `Running${attemptOf(d)}` }; break;   // the row names the step (user, t-985c)
    case 'gate.rejected':
      // manual_qa comes from check-evidence (role evaluator) and sprint complete (role sprint): either way the next step is the person's
      r = { cur, tone: 'red', status: d.reason === 'manual_qa' ? 'Waiting on you: record your manual check' : `Close refused: ${d.reason || 'no reason given'}` };
      break;
    case 'manual_qa.recorded': r = d.result === 'fail' ? { cur: '', tone: 'red', status: 'Manual check failed' } : { cur: '', tone: 'blue', status: 'Manual check recorded' }; break;
    case 'gate.finished':
      if (d.role === 'speccheck') r = { cur, tone: 'red', status: 'Waiting on you: approve the plan' };
      else if (d.role === 'reviewer') r = { cur, tone: 'blue', status: 'In your session' };
      else if (d.verdict === 'pass') r = { cur, tone: 'blue', status: 'Ready to close' };
      else r = { cur, tone: 'red', status: `${d.verdict || 'no verdict'}` };
      break;
    case 'close.confirmed': r = { cur, tone: 'blue', status: 'Closing' }; break;
    case 'sprint.completed': return { cur: '', reached: '', tone: 'green', status: 'Closed', closed: true };
    default: r = { cur: '', tone: 'idle', status: '' };   // unreachable: STATUS_KINDS lists every case above
  }
  if (needsYou && r.tone !== 'idle') r = { ...r, tone: 'red', status: `Needs you · ${r.status}` };
  return { ...r, reached: r.cur ? '' : reached, closed: false };
}

// t-bcc1: inline close gates, ended by `sprint wrapup-row`'s wrapup.gate_finished
export const INLINE_GATES = ['code-simplifier', 'code-reviewer', 'doc-audit', 'skill-eval', 'break-it', 'security-review', 'mutation-test'];
// t-bcc1: the kinds that end each row; tests/pipeline-events.sh checks every node has one and that it is emitted
export const ROW_END = {
  start: ['sprint.started'], plan: ['plan.approved'], 'spec-check': ['gate.finished'], 'approve-plan': ['plan.approved'],
  build: ['close.started', 'wrapup.gate_finished', 'gate.started', 'gate.finished'], 'your-test': ['manual_qa.recorded'],
  reviewer: ['gate.finished'], eval: ['gate.finished'], close: ['sprint.completed'], 'test-stamp': ['evidence.stamped'],
  ...Object.fromEntries(INLINE_GATES.map(g => [g, ['wrapup.gate_finished']])),
};
const GATE_ROLE = { 'spec-check': 'speccheck', reviewer: 'reviewer', eval: 'evaluator' };   // evaluator2 never counts

// t-bcc1: each row's state from its own end event, never its position (t-pnu4): id -> { state: done|skipped|notrun|failed|'', runs:
// its role's gate.started count }. Events may repeat (snapshot + window): deduplicated by id. Pure.
export function rowStates(nodes, events, artifacts = {}) {
  const seen = new Set(), evs = [];
  for (const e of (Array.isArray(events) ? events : [])) {
    if (!e || typeof e.kind !== 'string') continue;
    const k = e.id || `${e.kind}|${e.ts}|${JSON.stringify(e.data || {})}`;
    if (!seen.has(k)) { seen.add(k); evs.push(e); }
  }
  evs.sort((a, b) => tsOf(a) - tsOf(b));
  const d = e => (e && e.data) || {};
  const last = (kind, ok = () => true) => { for (let i = evs.length - 1; i >= 0; i--) if (evs[i].kind === kind && ok(d(evs[i]))) return evs[i]; return null; };
  const count = (kind, ok) => evs.filter(e => e.kind === kind && ok(d(e))).length;
  const role = r => x => String(x.role || '') === r;
  const closeBegan = !!(last('close.started') || evs.some(e => e.kind.startsWith('wrapup.') || (e.kind.startsWith('gate.') && ['reviewer', 'evaluator', 'evaluator2'].includes(String(d(e).role || '')))));
  const out = {};
  const rep = (artifacts && artifacts.reports) || {}, wrap = (artifacts && artifacts.wrapup) || {};
  // t-e371: a gate whose report holds a verdict ran, even when the session never logged it (Copilot relays write no event)
  const byReport = role => { const f = rep[role]; return f && f.verdict ? f : null; };
  // t-3df9: the model a row ran on: the gate event's, else its report's Model line; Build from implement.started, Close from the Close switch
  const modelOf = id => {
    const role = GATE_ROLE[id];
    if (role) {
      const e = last('gate.finished', x => String(x.role || '') === role), s = last('gate.started', x => String(x.role || '') === role);
      if (s && d(s).model && (!e || tsOf(s) > tsOf(e))) return String(d(s).model);   // t-e7f6: the running gate's model, from its gate.started
      return (e && d(e).model) || (byReport(role) || {}).model || '';
    }
    if (id === 'build') { const e = last('implement.started'); return (e && d(e).model) || ''; }
    if (id === 'close') { const e = last('build.switch', x => x.stage === 'close' && x.outcome === 'started'); return (e && d(e).model) || ''; }
    return '';
  };
  // t-e7f6: when a row ended, from the event that ended it (a group's end time); undefined when no event did
  const endOf = id => {
    const role = GATE_ROLE[id];
    const e = role ? last('gate.finished', x => String(x.role || '') === role)
      : id === 'test-stamp' ? last('evidence.stamped', x => String(x.name || '') === 'test-sh')
      : INLINE_GATES.includes(id) ? last('wrapup.gate_finished', x => String(x.gate || '') === id) : null;
    return e && Number.isFinite(tsOf(e)) ? tsOf(e) : undefined;
  };
  for (const n of (nodes || [])) {
    const id = n.id;
    let state = '';
    if (id === 'start') state = last('sprint.started') ? 'done' : '';
    else if (id === 'plan' || id === 'approve-plan') state = last('plan.approved') ? 'done' : '';
    else if (id === 'spec-check') state = last('gate.finished', role('speccheck')) || byReport('speccheck') ? 'done' : (last('plan.approved') && !last('gate.started', role('speccheck')) ? 'notrun' : '');
    else if (id === 'build') state = closeBegan ? 'done' : '';
    else if (id === 'your-test') { const e = last('manual_qa.recorded'); state = !e ? '' : d(e).result === 'fail' ? 'failed' : 'done'; }
    else if (id === 'reviewer') state = last('gate.finished', role('reviewer')) || byReport('reviewer') ? 'done' : '';
    else if (id === 'eval') {
      const e = last('gate.finished', role('evaluator')), v = e ? String(d(e).verdict || '') : (byReport('evaluator') || {}).verdict;
      state = !v && !e ? '' : v === 'pass' ? 'done' : 'failed';
    }
    else if (id === 'close') state = last('sprint.completed') ? 'done' : '';
    else if (id === 'test-stamp') { const e = last('evidence.stamped', x => String(x.name || '') === 'test-sh'); state = !e ? '' : String(d(e).exit) === '0' ? 'done' : 'failed'; }   // t-a4e8
    else if (INLINE_GATES.includes(id)) {
      const e = last('wrapup.gate_finished', x => String(x.gate || '') === id);
      const r = e ? String(d(e).result || '') : String(wrap[id] || '');   // t-e371: else the Wrapup Gates row in acceptance.md
      state = r === 'ran' ? 'done' : r === 'skipped' ? 'skipped' : '';
    }
    out[id] = { state, runs: GATE_ROLE[id] ? count('gate.started', role(GATE_ROLE[id])) : 0, model: modelOf(id), end: endOf(id) };
  }
  return out;
}

// t-e371: what the card reads from a gate's report (spec-review.md, review-notes.md, eval-report.md): the first word of the line under
// `## Verdict` (READY/GAPS, YES/NO, pass/fail/partial/not-run), lowercased, and the `Model:` line's value. Text only; '' when absent.
export function reportFacts(text) {
  const lines = String(text || '').split(/\r?\n/);
  let verdict = '', model = '';
  const h = lines.findIndex(l => /^##\s+Verdict\s*$/i.test(l));
  if (h >= 0) { const v = lines.slice(h + 1).find(l => l.trim()); if (v && !/^#/.test(v)) verdict = (v.trim().match(/^[*_`]*([A-Za-z-]+)/) || [])[1] || ''; }
  const m = lines.find(l => /^Model:\s*\S/.test(l));
  if (m) model = m.replace(/^Model:\s*/, '').replace(/\s*\(.*$/, '').trim();
  return { verdict: verdict.toLowerCase(), model };
}

// t-e371: the `## Wrapup Gates` table of acceptance.md: gate -> ran | skipped (the first word of its Status cell). Only that section.
export function wrapupRows(text) {
  const out = {};
  let inSec = false;
  for (const l of String(text || '').split(/\r?\n/)) {
    if (/^##\s/.test(l)) { inSec = /^##\s+Wrapup Gates\s*$/i.test(l); continue; }
    const c = inSec && l.trim().startsWith('|') ? l.split('|').map(x => x.trim()) : null;
    if (!c || c.length < 4) continue;
    const st = (c[2].match(/^(ran|skipped)\b/i) || [])[1];
    if (st && INLINE_GATES.includes(c[1])) out[c[1]] = st.toLowerCase();
  }
  return out;
}

// t-3df9: a model's short name for the card's second line: family + version (Sonnet 5.5, Haiku 4.5), GPT models as GPT-6 Luna; an alias
// (sonnet) is its family alone. The full value stays in the line's title.
export function shortModel(m) {
  const v = String(m || '').trim();
  if (!v) return '';
  const p = v.toLowerCase().replace(/^claude[-\s]/, '').split(/[-\s]+/).filter(Boolean);
  if (p[0] === 'gpt') return ['GPT-' + (p[1] || ''), ...p.slice(2).map(w => w[0].toUpperCase() + w.slice(1))].join(' ').replace(/^GPT- /, 'GPT ');
  const ver = [];
  for (const x of p.slice(1)) { if (!/^\d+(\.\d+)?$/.test(x) || x.length >= 8) break; ver.push(x); }
  return (p[0][0].toUpperCase() + p[0].slice(1)) + (ver.length ? ' ' + ver.join('.') : '');
}

// t-985c (user: "only event_start"): each step's start time, epoch ms by node id, from the ticket's events (the newest of each source).
export function stepStartTimes(nodes, events, mode = 'normal') {
  const out = {}, put = (id, e) => { const t = tsOf(e); if (id && Number.isFinite(t) && !(out[id] >= t)) out[id] = t; };
  const evs = (Array.isArray(events) ? events : []).filter(e => e && typeof e.kind === 'string');
  for (const e of evs) {
    const d = e.data || {};
    switch (e.kind) {
      case 'sprint.started': put('start', e); put('plan', e); break;
      case 'plan.approved': put('approve-plan', e); break;
      case 'implement.started': put('build', e); break;
      case 'build.switch': if (d.outcome === 'started' && d.stage !== 'close') put('build', e); break;
      case 'close.started': put(firstClosing(nodes, mode), e); break;
      case 'wrapup.gate_started': put(String(d.gate || ''), e); break;
      case 'gate.started': put(ROLE_NODE[String(d.role || '')], e); break;
      case 'close.confirmed': put('close', e); break;
      default: break;
    }
  }
  // a ticket with no Cockpit Build switch: Build began when the plan was approved
  if (out.build === undefined && out['approve-plan'] !== undefined) out.build = out['approve-plan'];
  return out;
}

// t-e7f6: a row's time: the clock alone for today, the date first for an earlier day (a ticket resumed on another day read as today);
// the full date and time is the time's tooltip. Local time zone and calendar date.
const clock = d => d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
const sameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
export function when(t, now = Date.now()) {
  const d = new Date(t);
  return sameDay(d, new Date(now)) ? clock(d) : `${d.getMonth() + 1}/${d.getDate()} ${clock(d)}`;
}
export const fullWhen = t => new Date(t).toLocaleString('en-US', { dateStyle: 'medium', timeStyle: 'short' });

// t-e7f6: the card's two groups, by position so they keep the pipeline's order (a project's wrapup order moves the children): Wrapup
// gates = after Build (Your test stays its own row) and before the Reviewer; Close gates = the Reviewer to the row before Close. Returns
// the shown list with each group's run of nodes replaced by { group, label, kids } (kids marks it: a node has a group field too); flat when Build or Close is missing.
export const GROUPS = { wrapup: 'Wrapup gates', close: 'Close gates' };
export function groupRows(shown) {
  const ids = shown.map(n => n.id), b = ids.indexOf('build'), c = ids.indexOf('close');
  if (b < 0 || c < b) return shown;
  const r = ids.indexOf('reviewer'), split = r > b && r < c ? r : c;
  const head = shown.slice(0, b + 1), mid = shown.slice(b + 1, c), lone = mid.filter(n => n.id === 'your-test');
  const kids = mid.filter(n => n.id !== 'your-test');
  const w = kids.filter(n => ids.indexOf(n.id) < split), cl = kids.filter(n => ids.indexOf(n.id) >= split);
  return [...head, ...lone, ...(w.length ? [{ group: 'wrapup', label: GROUPS.wrapup, kids: w }] : []),
    ...(cl.length ? [{ group: 'close', label: GROUPS.close, kids: cl }] : []), ...shown.slice(c)];
}

// t-e7f6: the line under the rail's "Sprint progress" label: the run's Model tiers preset and pipeline template, from the ticket's
// sprint.started (run_preset, run_pipeline). presets: /api/admin/model-tiers/options' presets (null when that read failed); pipe:
// /api/pipeline's reply (null when it failed). A half that cannot be named from what was read is left out, never guessed.
export function setupLine(started, presets, pipe) {
  const d = (started && started.data) || {}, pr = String(d.run_preset || ''), pl = String(d.run_pipeline || '');
  let a = '', b = '';
  if (pr === 'custom') a = 'Custom';
  else if (pr && Array.isArray(presets)) { const p = presets.find(x => x && x.id === pr); a = p && p.name ? String(p.name) : pr; }
  if (pl === 'canon-default') b = "canon's default";
  else if (/^[0-9a-f]{12}$/.test(pl) && pipe && typeof pipe.digest === 'string') {
    const t = pl === pipe.digest && Array.isArray(pipe.templates) ? pipe.templates.find(x => x && x.id === pipe.template && pipe.template) : null;
    b = t && t.name ? String(t.name) : 'Custom pipeline';
  }
  return [a, b].filter(Boolean).join(' · ');
}

// live (t-5ef8, the rail's card): { cur, reached, tone, status, closed, times (node id → epoch ms, t-985c), rows (rowStates, t-bcc1) }. Without it the card is the
// Pipeline tab's preview, unchanged.
export function progressCardHtml(nodes, mode, live) {
  const title = (MODES.find(m => m[0] === mode) || MODES[0])[1];
  const shown = (nodes || []).filter(n => !(n.only === 'manual' && !isManual(mode)));
  const times = (live && live.times) || {}, now = (live && live.now) || Date.now();
  const at = t => Number.isFinite(t) ? when(t, now) : '';
  const timeSpan = (text, tip) => text ? `<span class="spc-t" title="${esc(tip)}">${esc(text)}</span>` : '';
  // one row's facts: what the ticket of this kind does there and, live, its state from its own end event (t-bcc1)
  const facts = n => {
    const [cls, text] = note(n, mode);
    const gone = cls === 'skip' || cls === 'off';
    const cur = !!live && n.id === live.cur;
    const rs = (live && live.rows && live.rows[n.id]) || { state: '', runs: 0 };
    const done = !!live && !gone && !cur && (live.closed || rs.state === 'done');
    return { cls, text, gone, cur, rs, done };
  };
  const row = n => {
    const { cls, text, gone, cur, rs, done } = facts(n);
    const [ncls, ntext] = cls === 'wait' && rs.state === 'done' ? ['', ''] : text || !live || gone ? [cls, text]
      : rs.state === 'skipped' ? ['skip', 'skipped'] : rs.state === 'notrun' && !cur ? ['skip', 'not run'] : rs.state === 'failed' && !cur ? ['fail', 'failed']
      : ['', ''];
    const t = live && !gone ? times[n.id] : undefined, hm = at(t);
    // t-985c: the current step's status is its tooltip and accessible name, not a line under it (user: pulse only, no box)
    const say = cur ? esc(`${label(n.id)}: ${live.status}${hm ? ' · started ' + hm : ''}`) : '';
    const tip = cur ? ` title="${say}" aria-label="${say}"` : '';
    // t-3df9 (user 11-23): line 2, muted and indented under the name: the model the row ran on, and the run count from run 2 (never a guess);
    // t-e7f6: Close's model is the session's, said so it never reads as the Evaluator's
    const m = shortModel(rs.model);
    const sub = !live || gone ? [] : [m && n.id === 'close' ? 'Session: ' + m : m, rs.runs > 1 ? `Run ${rs.runs}` : ''].filter(Boolean);
    return `<li class="spc-row${gone ? ' gone' : ''}${done ? ' done' : ''}${cur ? ' cur' : ''}" data-spc-row="${esc(n.id)}"${tip}><span class="spc-dot" aria-hidden="true"></span>`
      + `<span class="spc-n">${esc(label(n.id))}</span><span class="spc-k ${n.kind === 'you' ? 'you' : n.kind === 'agent' ? 'agent' : ''}">${esc(TAG[n.kind] || n.kind)}</span>`
      + (ntext ? `<span class="spc-note ${ncls}">${esc(ntext)}</span>` : '')
      + timeSpan(hm, Number.isFinite(t) ? fullWhen(t) : '')
      + (sub.length ? `<span class="spc-sub"${rs.model ? ` title="${esc(rs.model)}"` : ''}>${esc(sub.join(' · '))}</span>` : '')
      + (n.id === 'close' && isManual(mode) ? '<span class="spc-line">Your sign-off closes: the question reads your record back.</span>' : '')
      + '</li>';
  };
  // t-e7f6: a group's parent row: n of m (m = children that run for this ticket, n = those done or skipped), the worst child state, and
  // its time from the earliest child start to the latest child end once all are through. Nothing counts: struck through, no count.
  const group = g => {
    const fs = g.kids.map(n => ({ n, ...facts(n) })), counted = fs.filter(f => !f.gone);
    const through = counted.filter(f => f.done || (!!live && !f.cur && f.rs.state === 'skipped'));
    const failed = counted.some(f => f.rs.state === 'failed'), cur = counted.some(f => f.cur);   // failed outranks current
    const all = counted.length > 0 && through.length === counted.length;
    const gone = counted.length === 0;
    let state = '';
    if (live && !gone) state = failed ? ' grp-fail' : cur ? ' grp-cur' : all ? ' grp-done' : '';
    let tm = '', tip = '';
    if (live && !gone) {
      const starts = counted.map(f => times[f.n.id]).filter(Number.isFinite), ends = all ? counted.map(f => f.rs.end).filter(Number.isFinite) : [];
      if (starts.length) {
        const s0 = Math.min(...starts), e0 = ends.length ? Math.max(...ends) : NaN;
        tm = at(s0); tip = fullWhen(s0);
        if (Number.isFinite(e0)) { tm += '–' + (sameDay(new Date(s0), new Date(e0)) ? clock(new Date(e0)) : at(e0)); tip += ' – ' + fullWhen(e0); }
      }
    }
    const count = live && !gone ? `<span class="spc-note spc-count">${through.length} of ${counted.length}</span>` : '';
    // its own class and grp-* states, not a row's (spc-row, done, cur, gone): a locator or count of rows never matches a parent
    return `<li class="spc-grp${gone ? ' grp-gone' : ''}${state}" data-spc-grp="${esc(g.group)}"><span class="spc-dot" aria-hidden="true"></span>`
      + `<span class="spc-n">${esc(g.label)}</span>${count}${timeSpan(tm, tip)}`
      + `<ol class="spc-rail spc-kids">${g.kids.map(row).join('')}</ol></li>`;
  };
  const rows = groupRows(shown).map(x => x.kids ? group(x) : row(x)).join('');
  if (!live) return `<div class="spc-head">Sprint progress &middot; a ${esc(title)} ticket</div><ol class="spc-rail">${rows}</ol>`;
  const curShown = shown.some(n => n.id === live.cur);
  const setup = live.setup ? `<div class="spc-setup" title="Model tiers preset (Admin › Model tiers) · pipeline template (Factory › Pipeline)">${esc(live.setup)}</div>` : '';
  // the rail's section label already says "Sprint progress": the head names only a ticket option
  return `<div class="spc-live" data-tone="${esc(live.tone)}">${setup}${mode === 'normal' ? '' : `<div class="spc-head">a ${esc(title)} ticket</div>`}`
    + (curShown ? '' : `<div class="spc-status">${esc(live.status)}</div>`)
    + `<ol class="spc-rail">${rows}</ol></div>`;
}
