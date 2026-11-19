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
    case 'plan.approved': case 'build.switch': return 'build';
    case 'close.started': return firstClosing(nodes, mode);
    case 'gate.started': case 'gate.rejected': return ROLE_NODE[role] || '';
    case 'gate.finished':
      if (role === 'speccheck') return 'approve-plan';
      if (role === 'reviewer') return ids[ids.indexOf('reviewer') + 1] || '';
      return d.verdict === 'pass' ? 'close' : ROLE_NODE[role] || '';
    case 'close.confirmed': return 'close';
    default: return '';
  }
}

// t-5ef8: the live card's state, folded from GET /api/v1/sprint/<ticket>'s events (the latest of each lifecycle kind). The newest event
// decides the current node; planWritten (plan.md's Approach has content: nothing emits plan.written yet) and needsYou (the session waits
// on the person) refine it. Returns { cur: node id or '', reached: the last row reached when cur is '', tone: idle|blue|amber|red|green,
// status, closed }. Pure: no fetch, no DOM.
export function sprintProgress(nodes, events, { planWritten = false, needsYou = false, mode = 'normal' } = {}) {
  const ids = (nodes || []).map(n => n.id);
  const evs = (Array.isArray(events) ? events : []).filter(e => e && typeof e.kind === 'string').sort((a, b) => tsOf(a) - tsOf(b));
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
    case 'build.switch': r = SWITCH_FAIL[d.outcome] ? { cur, tone: 'red', status: SWITCH_FAIL[d.outcome](d) } : { cur, tone: 'blue', status: 'Implementing' }; break;
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
    default: r = { cur: '', tone: 'idle', status: latest.kind };
  }
  if (needsYou && r.tone !== 'idle') r = { ...r, tone: 'red', status: `Needs you · ${r.status}` };
  return { ...r, reached: r.cur ? '' : reached, closed: false };
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
      case 'build.switch': if (d.outcome === 'started') put('build', e); break;
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

// live (t-5ef8, the rail's card): { cur, reached, tone, status, closed, times (node id → epoch ms, t-985c) }. Without it the card is the
// Pipeline tab's preview, unchanged.
export function progressCardHtml(nodes, mode, live) {
  const title = (MODES.find(m => m[0] === mode) || MODES[0])[1];
  const shown = (nodes || []).filter(n => !(n.only === 'manual' && !isManual(mode)));
  const curAt = live ? shown.findIndex(n => n.id === live.cur) : -1;
  const reachedAt = live && curAt < 0 ? shown.findIndex(n => n.id === live.reached) : -1;   // t-985c: rows passed stay done under a head status
  const times = (live && live.times) || {};
  const rows = shown.map((n, i) => {
    const [cls, text] = note(n, mode);
    const gone = cls === 'skip' || cls === 'off';
    const done = !!live && !gone && (live.closed || (curAt >= 0 && i < curAt) || (reachedAt >= 0 && i <= reachedAt));
    const cur = !!live && i === curAt;
    const at = live && !gone && Number.isFinite(times[n.id]) ? hm(times[n.id]) : '';
    // t-985c: the current step's status is its tooltip and accessible name, not a line under it (user: pulse only, no box)
    const tip = cur ? ` title="${esc(`${label(n.id)}: ${live.status}${at ? ' · started ' + at : ''}`)}" aria-label="${esc(`${label(n.id)}: ${live.status}${at ? ' · started ' + at : ''}`)}"` : '';
    return `<li class="spc-row${gone ? ' gone' : ''}${done ? ' done' : ''}${cur ? ' cur' : ''}" data-spc-row="${esc(n.id)}"${tip}><span class="spc-dot" aria-hidden="true"></span>`
      + `<span class="spc-n">${esc(label(n.id))}</span><span class="spc-k ${n.kind === 'you' ? 'you' : n.kind === 'agent' ? 'agent' : ''}">${esc(TAG[n.kind] || n.kind)}</span>`
      + (text ? `<span class="spc-note ${cls}">${esc(text)}</span>` : '')
      + (at ? `<span class="spc-t">${esc(at)}</span>` : '')
      + (n.id === 'close' && isManual(mode) ? '<span class="spc-line">Your sign-off closes: the question reads your record back.</span>' : '')
      + '</li>';
  }).join('');
  if (!live) return `<div class="spc-head">Sprint progress &middot; a ${esc(title)} ticket</div><ol class="spc-rail">${rows}</ol>`;
  // the rail's section label already says "Sprint progress": the head names only a ticket option
  return `<div class="spc-live" data-tone="${esc(live.tone)}">${mode === 'normal' ? '' : `<div class="spc-head">a ${esc(title)} ticket</div>`}`
    + (curAt < 0 ? `<div class="spc-status">${esc(live.status)}</div>` : '')
    + `<ol class="spc-rail">${rows}</ol></div>`;
}
