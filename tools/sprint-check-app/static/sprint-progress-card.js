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
  reviewer: ['gate.finished'], eval: ['gate.finished'], close: ['sprint.completed'],
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
    if (role) { const e = last('gate.finished', x => String(x.role || '') === role); return (e && d(e).model) || (byReport(role) || {}).model || ''; }
    if (id === 'build') { const e = last('implement.started'); return (e && d(e).model) || ''; }
    if (id === 'close') { const e = last('build.switch', x => x.stage === 'close' && x.outcome === 'started'); return (e && d(e).model) || ''; }
    return '';
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
    else if (INLINE_GATES.includes(id)) {
      const e = last('wrapup.gate_finished', x => String(x.gate || '') === id);
      const r = e ? String(d(e).result || '') : String(wrap[id] || '');   // t-e371: else the Wrapup Gates row in acceptance.md
      state = r === 'ran' ? 'done' : r === 'skipped' ? 'skipped' : '';
    }
    out[id] = { state, runs: GATE_ROLE[id] ? count('gate.started', role(GATE_ROLE[id])) : 0, model: modelOf(id) };
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

const hm = t => new Date(t).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });

// live (t-5ef8, the rail's card): { cur, reached, tone, status, closed, times (node id → epoch ms, t-985c), rows (rowStates, t-bcc1) }. Without it the card is the
// Pipeline tab's preview, unchanged.
export function progressCardHtml(nodes, mode, live) {
  const title = (MODES.find(m => m[0] === mode) || MODES[0])[1];
  const shown = (nodes || []).filter(n => !(n.only === 'manual' && !isManual(mode)));
  const curAt = live ? shown.findIndex(n => n.id === live.cur) : -1;
  const times = (live && live.times) || {};
  const rows = shown.map((n, i) => {
    const [cls, text] = note(n, mode);
    const gone = cls === 'skip' || cls === 'off';
    const cur = !!live && i === curAt;
    // t-bcc1: done only from the row's own end event (rowStates)
    const rs = (live && live.rows && live.rows[n.id]) || { state: '', runs: 0 };
    const done = !!live && !gone && !cur && (live.closed || rs.state === 'done');
    const [ncls, ntext] = cls === 'wait' && rs.state === 'done' ? ['', ''] : text || !live || gone ? [cls, text]
      : rs.state === 'skipped' ? ['skip', 'skipped'] : rs.state === 'notrun' && !cur ? ['skip', 'not run'] : rs.state === 'failed' && !cur ? ['fail', 'failed']
      : ['', ''];
    const at = live && !gone && Number.isFinite(times[n.id]) ? hm(times[n.id]) : '';
    // t-985c: the current step's status is its tooltip and accessible name, not a line under it (user: pulse only, no box)
    const say = cur ? esc(`${label(n.id)}: ${live.status}${at ? ' · started ' + at : ''}`) : '';
    const tip = cur ? ` title="${say}" aria-label="${say}"` : '';
    // t-3df9 (user 11-23): line 2, muted and indented under the name: the model the row ran on, and the run count from run 2 (never a guess)
    const sub = !live || gone ? [] : [shortModel(rs.model), rs.runs > 1 ? `Run ${rs.runs}` : ''].filter(Boolean);
    return `<li class="spc-row${gone ? ' gone' : ''}${done ? ' done' : ''}${cur ? ' cur' : ''}" data-spc-row="${esc(n.id)}"${tip}><span class="spc-dot" aria-hidden="true"></span>`
      + `<span class="spc-n">${esc(label(n.id))}</span><span class="spc-k ${n.kind === 'you' ? 'you' : n.kind === 'agent' ? 'agent' : ''}">${esc(TAG[n.kind] || n.kind)}</span>`
      + (ntext ? `<span class="spc-note ${ncls}">${esc(ntext)}</span>` : '')
      + (at ? `<span class="spc-t">${esc(at)}</span>` : '')
      + (sub.length ? `<span class="spc-sub"${rs.model ? ` title="${esc(rs.model)}"` : ''}>${esc(sub.join(' · '))}</span>` : '')
      + (n.id === 'close' && isManual(mode) ? '<span class="spc-line">Your sign-off closes: the question reads your record back.</span>' : '')
      + '</li>';
  }).join('');
  if (!live) return `<div class="spc-head">Sprint progress &middot; a ${esc(title)} ticket</div><ol class="spc-rail">${rows}</ol>`;
  // the rail's section label already says "Sprint progress": the head names only a ticket option
  return `<div class="spc-live" data-tone="${esc(live.tone)}">${mode === 'normal' ? '' : `<div class="spc-head">a ${esc(title)} ticket</div>`}`
    + (curAt < 0 ? `<div class="spc-status">${esc(live.status)}</div>` : '')
    + `<ol class="spc-rail">${rows}</ol></div>`;
}
