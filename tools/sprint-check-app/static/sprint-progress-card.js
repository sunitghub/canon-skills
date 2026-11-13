// t-2755: the Sprint progress card, drawn from the resolved pipeline (GET /api/pipeline's nodes) for one kind of ticket. One pure function,
// so the Pipeline tab's "Preview a ticket" (now) and a ticket's live card (t-5ef8) draw the same list and cannot drift. Display only: it
// builds a string from the nodes it is given, escapes every value, and sends nothing.
import { esc } from './cockpit-core.js';

export const LABEL = { start: 'Start', plan: 'Plan', 'approve-plan': 'Approve plan', build: 'Build', 'your-test': 'Your test', reviewer: 'Reviewer', eval: 'Evaluator', close: 'Close' };
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

export function progressCardHtml(nodes, mode) {
  const title = (MODES.find(m => m[0] === mode) || MODES[0])[1];
  const rows = (nodes || []).filter(n => !(n.only === 'manual' && !isManual(mode))).map(n => {
    const [cls, text] = note(n, mode);
    const gone = cls === 'skip' || cls === 'off';
    return `<li class="spc-row${gone ? ' gone' : ''}" data-spc-row="${esc(n.id)}"><span class="spc-dot" aria-hidden="true"></span>`
      + `<span class="spc-n">${esc(label(n.id))}</span><span class="spc-k ${n.kind === 'you' ? 'you' : n.kind === 'agent' ? 'agent' : ''}">${esc(TAG[n.kind] || n.kind)}</span>`
      + (text ? `<span class="spc-note ${cls}">${esc(text)}</span>` : '')
      + (n.id === 'close' && isManual(mode) ? '<span class="spc-line">Your sign-off closes: the question reads your record back.</span>' : '')
      + '</li>';
  }).join('');
  return `<div class="spc-head">Sprint progress &middot; a ${esc(title)} ticket</div><ol class="spc-rail">${rows}</ol>`;
}
