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
// a gate role's name is its node's label; the Second eval (evaluator2) shares the Evaluator's node and has its own name
const roleName = r => (r === 'evaluator2' ? 'Second eval' : ROLE_NODE[r] ? label(ROLE_NODE[r]) : r || 'Gate');
const tsOf = e => { const n = Date.parse(e && e.ts); return Number.isFinite(n) ? n : -Infinity; };
const attemptOf = d => (d && d.attempt ? ` · attempt ${d.attempt}` : '');

// t-5ef8: the live card's state, folded from GET /api/v1/sprint/<ticket>'s events (the latest of each lifecycle kind). The newest event
// decides the current node; planWritten (plan.md's Approach has content: nothing emits plan.written yet) and needsYou (the session waits
// on the person) refine it. Returns { cur: node id or '', tone: idle|blue|amber|red|green, status, closed }. Pure: no fetch, no DOM.
export function sprintProgress(nodes, events, { planWritten = false, needsYou = false } = {}) {
  const ids = (nodes || []).map(n => n.id);
  const latest = (Array.isArray(events) ? events : []).filter(e => e && typeof e.kind === 'string')
    .reduce((a, e) => (!a || tsOf(e) >= tsOf(a) ? e : a), null);
  const d = (latest && latest.data) || {}, role = String(d.role || ''), name = roleName(role);
  let r;
  switch (latest ? latest.kind : '') {
    case '': r = { cur: '', tone: 'idle', status: 'Not started' }; break;
    case 'sprint.started':
      r = planWritten ? { cur: 'approve-plan', tone: 'red', status: 'Waiting on you: approve the plan' } : { cur: 'plan', tone: 'blue', status: 'Writing the plan' };
      break;
    case 'plan.approved': r = { cur: 'build', tone: 'blue', status: 'Implementing' }; break;
    case 'gate.started': r = { cur: ROLE_NODE[role] || '', tone: 'amber', status: `${name} running${attemptOf(d)}` }; break;
    case 'gate.rejected': r = { cur: ROLE_NODE[role] || '', tone: 'red', status: `Close refused: ${d.reason || 'no reason given'}` }; break;
    case 'gate.finished':
      if (role === 'speccheck') r = { cur: 'approve-plan', tone: 'red', status: 'Waiting on you: approve the plan' };
      else if (role === 'reviewer') r = { cur: ids[ids.indexOf('reviewer') + 1] || '', tone: 'blue', status: 'In your session' };
      else if (d.verdict === 'pass') r = { cur: 'close', tone: 'blue', status: 'Ready to close' };
      else r = { cur: ROLE_NODE[role] || '', tone: 'red', status: `${name}: ${d.verdict || 'no verdict'}` };
      break;
    case 'close.confirmed': r = { cur: 'close', tone: 'blue', status: 'Closing' }; break;
    case 'sprint.completed': return { cur: '', tone: 'green', status: 'Closed', closed: true };
    default: r = { cur: '', tone: 'idle', status: latest.kind };
  }
  if (needsYou && r.tone !== 'idle') r = { ...r, tone: 'red', status: `Needs you · ${r.status}` };
  return { ...r, closed: false };
}

const pad = n => String(n).padStart(2, '0');
function eventLine(e) {
  const t = new Date(tsOf(e)), d = (e && e.data) || {};
  const at = Number.isFinite(t.getTime()) ? `${pad(t.getHours())}:${pad(t.getMinutes())}:${pad(t.getSeconds())}` : '--:--:--';
  return `<li class="spc-ev"><span class="spc-ev-t">${esc(at)}</span> ${esc(String(e.kind || ''))}${d.role ? ' ' + esc(String(d.role)) : ''}${esc(attemptOf(d))}</li>`;
}

// live (t-5ef8, the rail's card): { cur, tone, status, closed, events (this ticket's newest, oldest first), eventsNote }. Without it the
// card is the Pipeline tab's preview, unchanged.
export function progressCardHtml(nodes, mode, live) {
  const title = (MODES.find(m => m[0] === mode) || MODES[0])[1];
  const shown = (nodes || []).filter(n => !(n.only === 'manual' && !isManual(mode)));
  const curAt = live ? shown.findIndex(n => n.id === live.cur) : -1;
  const rows = shown.map((n, i) => {
    const [cls, text] = note(n, mode);
    const gone = cls === 'skip' || cls === 'off';
    const done = !!live && !gone && (live.closed || (curAt >= 0 && i < curAt));
    const cur = !!live && i === curAt;
    return `<li class="spc-row${gone ? ' gone' : ''}${done ? ' done' : ''}${cur ? ' cur' : ''}" data-spc-row="${esc(n.id)}"><span class="spc-dot" aria-hidden="true"></span>`
      + `<span class="spc-n">${esc(label(n.id))}</span><span class="spc-k ${n.kind === 'you' ? 'you' : n.kind === 'agent' ? 'agent' : ''}">${esc(TAG[n.kind] || n.kind)}</span>`
      + (text ? `<span class="spc-note ${cls}">${esc(text)}</span>` : '')
      + (cur ? `<span class="spc-status">${esc(live.status)}</span>` : '')
      + (n.id === 'close' && isManual(mode) ? '<span class="spc-line">Your sign-off closes: the question reads your record back.</span>' : '')
      + '</li>';
  }).join('');
  if (!live) return `<div class="spc-head">Sprint progress &middot; a ${esc(title)} ticket</div><ol class="spc-rail">${rows}</ol>`;
  const evs = Array.isArray(live.events) && live.events.length
    ? `<ol class="spc-evs">${live.events.map(eventLine).join('')}</ol>`
    : `<div class="spc-ev-empty">${esc(live.eventsNote || 'No events yet.')}</div>`;
  // the rail's section label already says "Sprint progress": the head names only a ticket option
  return `<div class="spc-live" data-tone="${esc(live.tone)}">${mode === 'normal' ? '' : `<div class="spc-head">a ${esc(title)} ticket</div>`}`
    + (curAt < 0 ? `<div class="spc-status">${esc(live.status)}</div>` : '')
    + `<ol class="spc-rail">${rows}</ol>${evs}</div>`;
}
