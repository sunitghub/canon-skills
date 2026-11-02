// t-c542: the ticket modal's read-only Machines node. One row per machine that worked on the ticket, from
// GET /api/ticket-machines (the ticket's events, each naming its host, and its evidence log headers, which is how a cloud
// session's machine arrives). The text of each machine is the server's (machine.Facts.Line): the board formats nothing.
import { esc, escAttr } from './board-helpers.js';
import { modalState, renderModalDocs } from './board-modal.js';
import { refreshModalActions, renderModalBody } from './board-docs.js';

export const MACHINES_VIEW = 'machines';

export function machinesNodeHTML() {
  const on = modalState.view === MACHINES_VIEW;
  return `<div class="doc-node"><span class="doc-expander-spacer"></span><button class="doc-tab doc-view${on ? ' active' : ''}" data-view="${MACHINES_VIEW}" title="Which machines worked on this ticket">Machines</button></div>`;
}

export function activateMachines(t) {
  if (modalState.editMode) return;
  modalState.ghost = '';
  modalState.view = MACHINES_VIEW;
  renderModalDocs(t);
  renderModalBody(t);
  refreshModalActions(t);
}

const when = iso => { const d = new Date(iso); return isNaN(d) ? '' : d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }); };

function rowHTML(m) {
  const who = m.source === 'events'
    ? `<code>${esc(m.host)}</code>`
    : `<span class="mc-where">${m.where === 'cloud' ? 'cloud' : 'this project'}</span>`;
  const what = m.line ? esc(m.line) : '<span class="mc-dim" title="This host wrote no machine.seen yet: it appears when its board next starts">facts not recorded yet</span>';
  const n = Number(m.count) || 0;
  const count = m.source === 'events' ? `${n} event${n === 1 ? '' : 's'}` : `${n} evidence log${n === 1 ? '' : 's'}`;
  return `<tr><td>${who}<div class="mc-dim">${m.where === 'cloud' ? 'cloud session' : 'local'}</div></td><td>${what}</td>`
    + `<td>${esc(count)}<div class="mc-dim" title="${escAttr(m.first ? 'first ' + when(m.first) : '')}">last ${esc(when(m.last))}</div></td></tr>`;
}

export async function renderMachinesPane(t, seq) {
  const body = document.getElementById('m-body');
  body.innerHTML = '<div class="machines-pane"><span class="mc-dim">Loading…</span></div>';
  let rows;
  try {
    const r = await fetch('/api/ticket-machines?ticket=' + encodeURIComponent(t.id));
    if (!r.ok) throw new Error('HTTP ' + r.status);
    rows = (await r.json()).machines;
  } catch (e) {
    if (seq !== modalState.renderSeq) return;
    body.innerHTML = `<div class="machines-pane"><p class="mc-err">Couldn't read the machines: ${esc(e.message)}</p></div>`;
    return;
  }
  if (seq !== modalState.renderSeq) return;   // the user moved on while this was loading
  if (!Array.isArray(rows) || !rows.length) {
    body.innerHTML = '<div class="machines-pane"><h3>No machine recorded yet</h3><p>Every event now names the machine that wrote it, and every test-evidence log names its OS, cores and RAM. A ticket worked on since then shows its machines here; a cloud session\'s machine arrives with <code>tkt import-results</code>.</p></div>';
    return;
  }
  body.innerHTML = `<div class="machines-pane"><table class="machines-table"><thead><tr><th>Machine</th><th>OS, chip, cores, RAM</th><th>Activity</th></tr></thead><tbody>${rows.map(rowHTML).join('')}</tbody></table>`
    + '<p class="mc-dim">From this ticket\'s events (each names the host that wrote it) and its test-evidence logs (they name the OS, never the host).</p></div>';
}
