import { DEBUG, LIVE_EDITABLE_SLUGS, availableDocTypes, docSlug, loadData, state } from './board-core.js';
import { WT_PREF_MAIN, age, effectiveStatus, esc, escAttr, openWorktreePreference, titleCase, typeBadge } from './board-helpers.js';
import { ckRowState, fetchDoc, findTicketById, postWrite, readiness, renderBoard } from './board-render.js';
import { activateGhost, exitEditMode, refreshModalActions, renderModalBody, saveEdit } from './board-docs.js';
import { cockpitState } from './board-cockpit.js';
import { renderCockpitDetails } from './board-cockpit-rail.js';
import { resetPanelDrag, resetPanelResize } from './board-panels.js';
import { setText } from './board-ui.js';

// ── Modal ─────────────────────────────────────────────────────────────────

export const modalState = { docOverride: {}, editMode: false, activeDoc: null, renderSeq: 0, docEtag: '', sections: {}, expanded: new Set(), seen: new Set(), pendingScroll: '', prefetchSeq: 0 };

// t-26f9: the doc changed since the editor opened it (the agent may have edited it). The person's text stays in the
// box; they choose to load theirs or to overwrite knowingly.
// t-8be2: a status/Demo write of a bound ticket returns the file's new etag AND the Description that etag describes.
// Adopt both on the ticket the board holds NOW (a poll may have replaced the object the handler started with), so the
// page's text and etag stay a pair: an edit never starts from older text under a newer etag.
export function adoptTicketWrite(id, data) {
  const cur = findTicketById(id);
  if (!cur || !data) return;
  if (data.etag) cur.ticket_etag = data.etag;
  if (typeof data.body === 'string') {
    cur.body = data.body;
    const h = data.body.match(/^#{1,6}\s+(.+)$/m);
    if (h) cur.title = h[1].trim();
  }
}

// A ticket's own fields (its Description) are read through /api/tickets, which carries the ticket_etag (t-8be2).
async function fetchTicketFresh(id) {
  try {
    const r = await fetch('/api/tickets?all=1');
    if (!r.ok) return null;
    const t = (await r.json()).find(x => x.id === id);
    return t ? { content: t.body || '', etag: t.ticket_etag || '' } : null;
  } catch { return null; }
}

export function showStaleEditNotice(t) {
  const editEl = document.getElementById('m-edit-area');
  if (!editEl || (!modalState.activeDoc && !t)) return;
  const isDoc = !!modalState.activeDoc;
  const fetchCur = () => isDoc ? fetchDoc(modalState.activeDoc) : fetchTicketFresh(t.id);
  const setEtag = e => { if (isDoc) modalState.docEtag = e; else t.ticket_etag = e; };
  let n = document.getElementById('stale-edit-notice');
  if (!n) {
    n = document.createElement('div');
    n.id = 'stale-edit-notice';
    n.className = 'acceptance-warning';
    const card = document.getElementById('m-editor-card');   // t-a205: the textarea sits inside the card now
    card.parentNode.insertBefore(n, card);
  }
  n.innerHTML = `⚠ This ${isDoc ? 'doc' : 'description'} changed since you opened it (the agent may have edited it). Your text is kept. `
    + '<button type="button" class="doc-cancel-btn" id="stale-reload">Reload theirs</button> '
    + '<button type="button" class="doc-save-btn" id="stale-overwrite">Overwrite with mine</button>';
  n.querySelector('#stale-reload').onclick = async () => {
    const cur = await fetchCur();
    if (!cur) return;
    editEl.value = cur.content; setEtag(cur.etag); n.remove();
  };
  n.querySelector('#stale-overwrite').onclick = async () => {
    const cur = await fetchCur();
    if (!cur) return;
    setEtag(cur.etag); n.remove();
    document.getElementById('btn-save-top')?.click();
  };
}

// t-bb97: the status chips row, now also holding the Demo/UX switch (it moved here from the Plan sign-off bar).
function renderModalMeta(t) {
  const statusColor = {
    open: 'var(--col-open)', in_progress: 'var(--col-progress)',
    closed: 'var(--col-done)', cancelled: 'var(--col-discarded)',
  }[t.status] || 'var(--text)';
  const { ready: mReady, label: mReadyLabel } = readiness(t);
  const mReadyColor = mReady ? 'var(--col-done)' : 'var(--text-muted)';
  document.getElementById('m-meta').innerHTML = [
    { label:'Status',   html:`<span style="color:${statusColor};font-weight:500">${esc(titleCase(t.status.replace('_',' ')))}</span>` },
    { label:'Type',     val: titleCase(t.type || 'task') },
    { label:'Priority', val: `P${t.priority ?? 2}` },
    { label:'Age',      val: age(t.created) || '—' },
    ...(openWorktreePreference(t) === WT_PREF_MAIN ? [{ label:'Worktree', html:`<span title="Chosen at New Ticket — the sprint runs in the main checkout.">Main checkout</span>` }]
      : openWorktreePreference(t) ? [{ label:'Worktree', html:`<span title="Chosen at New Ticket — created when you start the sprint">${esc(openWorktreePreference(t))} <span style="color:var(--text-muted)">· created when you start</span></span>` }] : []),
    { label:'Ready',    html:`<span style="color:${mReadyColor};font-weight:600;display:flex;align-items:center;gap:4px"><span style="width:7px;height:7px;border-radius:50%;background:${mReadyColor};display:inline-block;flex-shrink:0"></span>${esc(mReadyLabel)}</span>` },
  ].map(m => `<div class="meta-item"><span class="meta-label">${esc(m.label)}</span><span class="meta-val">${m.html ?? esc(m.val)}</span></div>`).join('');

  const demoOn = String(t.demo) === 'true';
  const demoBtn = document.createElement('button');
  demoBtn.type = 'button';
  demoBtn.className = 'signoff-demo-toggle';
  demoBtn.setAttribute('role', 'switch');
  demoBtn.setAttribute('aria-checked', String(demoOn));
  demoBtn.innerHTML = '<span class="sw-track"><span class="sw-knob"></span></span><span>Demo/UX</span>';
  // The demo flag lives in MAIN's ticket.md frontmatter, not the live worktree plan.md, so only a closed ticket locks it.
  const demoLocked = t.status === 'closed' || t.status === 'cancelled';
  demoBtn.disabled = demoLocked;
  demoBtn.title = demoLocked
    ? 'Ticket is closed — no further edits.'
    : 'Demo/Docs/UX light-close (live demos or docs/research/UX-mockup work): sprint complete runs security-review + the binding evaluator only (forced Haiku), skipping the advisory reviewer + rest of wrapup. Never drops below the evaluator.';
  demoBtn.addEventListener('click', async () => {
    const next = String(t.demo) !== 'true';
    demoBtn.disabled = true;
    try {
      const res = await postWrite(`/api/ticket/${t.id}/demo`, { demo: next }, 'change Demo/UX');
      if (res.ok) { t.demo = next ? 'true' : 'false'; const cur0 = findTicketById(t.id); if (cur0) cur0.demo = t.demo; adoptTicketWrite(t.id, res.data); }
    } finally {
      renderBoard();
      const cur = state.tickets.find(tk => tk.id === state.selectedId);
      if (cur) { renderModalMeta(cur); renderModalBody(cur); }
    }
  });
  const item = document.createElement('div');
  item.className = 'meta-item meta-demo';
  item.appendChild(demoBtn);
  document.getElementById('m-meta').appendChild(item);
}

export function openModal(id) {
  const t = findTicketById(id);
  if (!t) return;
  if (DEBUG) window.__sprintCheckOpenModalCount = (window.__sprintCheckOpenModalCount || 0) + 1;
  state.selectedId = id;
  modalState.editMode = false;
  modalState.activeDoc = null;   // t-e946: a ticket opens on Description (the tree's first node)
  modalState.ghost = '';
  // t-612f: every doc's ## sections, so the tree can show a + before a doc is opened (the rest arrive from prefetchDocSections)
  modalState.sections = { '': parseDocSections(t.body) };
  modalState.expanded = new Set(['']);
  modalState.seen = new Set(['']);
  modalState.pendingScroll = '';
  resetPanelDrag(document.getElementById('modal'));
  resetPanelResize(document.getElementById('modal'));

  setText('m-id',    t.id);
  setText('m-title', t.title);
  document.getElementById('m-type').innerHTML = typeBadge(t.type);

  renderModalMeta(t);

  renderModalDocs(t);
  renderModalBody(t);
  refreshModalActions(t);
  renderModalHeadless(t);
  prefetchDocSections(t);
  document.getElementById('modal-overlay').classList.add('open');
  renderBoard();
}

const HIDDEN_DOC_SLUGS = new Set(['blueprint']);

// ── Headless grading trigger (t-200b) ───────────────────────────────────────

let _headlessPollTimer = null;

export function stopHeadlessPoll() {
  if (_headlessPollTimer) { clearInterval(_headlessPollTimer); _headlessPollTimer = null; }
}

function startHeadlessPoll(ticketId) {
  stopHeadlessPoll();
  _headlessPollTimer = setInterval(() => {
    if (state.selectedId !== ticketId) { stopHeadlessPoll(); return; }
    fetch(`/api/ticket/${encodeURIComponent(ticketId)}/headless-run`)
      .then(r => r.json())
      .then(data => {
        renderHeadlessStatus(ticketId, data);
        if (data.status !== 'running') {
          stopHeadlessPoll();
          loadData(); // refresh so review-notes.md/eval-report.md appear as doc tabs once written
        }
      })
      .catch(() => stopHeadlessPoll());
  }, 3000);
}

function setHeadlessSteps(status, pass) {
  const steps = document.querySelectorAll('#m-headless .headless-step');
  if (steps.length !== 3) return;
  steps.forEach(s => s.classList.remove('active', 'done', 'fail', 'headless-pulse', 'headless-result-highlight'));
  if (status === 'idle') {
    steps[0].classList.add('active');
  } else if (status === 'running') {
    steps[0].classList.add('done');
    steps[1].classList.add('active', 'headless-pulse');
  } else {
    steps[0].classList.add('done');
    steps[1].classList.add('done');
    steps[2].classList.add(pass ? 'done' : 'fail');
    steps[2].classList.add('headless-result-highlight');
  }
}

function renderHeadlessStatus(ticketId, data) {
  if (state.selectedId !== ticketId) return;
  const el = document.getElementById('m-headless-status');
  if (!el) return;
  const runBtn = document.getElementById('m-headless-run');
  if (data.status === 'idle') {
    el.innerHTML = '';
    if (runBtn) runBtn.disabled = false;
    setHeadlessSteps('idle');
  } else if (data.status === 'running') {
    if (runBtn) runBtn.disabled = true;
    el.innerHTML = `<span class="headless-running">Running… (${Math.round(data.elapsed || 0)}s)</span>`;
    setHeadlessSteps('running');
  } else {
    if (runBtn) runBtn.disabled = false;
    const pass = /^HEADLESS_VERDICT: PASS$/m.test(data.output || '');
    el.innerHTML = `<span class="${pass ? 'headless-pass' : 'headless-fail'}">${pass ? 'PASS' : 'FAIL'}</span>` +
      ` &mdash; <span class="headless-view-output">view output</span>` +
      `<pre class="headless-output" style="display:none">${esc(data.output || '')}</pre>`;
    el.querySelector('.headless-view-output')?.addEventListener('click', () => {
      const pre = el.querySelector('.headless-output');
      pre.style.display = pre.style.display === 'none' ? 'block' : 'none';
    });
    setHeadlessSteps('done', pass);
  }
}

const HEADLESS_STEP_DESCRIPTIONS = [
  'Choose a branch, tag, or commit SHA to grade against, then start the run.',
  'Reviewer, evaluator, and security-review run as fresh subagents in the background.',
  'See the PASS/FAIL verdict below, with the full output one click away.',
];

function renderModalHeadless(t) {
  const el = document.getElementById('m-headless');
  stopHeadlessPoll();
  if (String(t.ci) !== 'true') { el.innerHTML = ''; return; }
  el.innerHTML = `
    <div class="headless-panel">
      <div class="headless-steps">
        <div class="headless-step" data-step-idx="0"><div class="headless-step-icon">1</div><div class="headless-step-label">Set base ref</div></div>
        <div class="headless-step-line"></div>
        <div class="headless-step" data-step-idx="1"><div class="headless-step-icon">2</div><div class="headless-step-label">Grading in progress</div></div>
        <div class="headless-step-line"></div>
        <div class="headless-step" data-step-idx="2"><div class="headless-step-icon">3</div><div class="headless-step-label">Result ready</div></div>
      </div>
      <div class="headless-steps-hint">Click a step for details</div>
      <div class="headless-step-desc" id="m-headless-step-desc"></div>
      <div class="headless-baseref-hint">Grades the diff between this commit/branch and your current code — e.g. <code class="doc-code">main</code> or a commit SHA.</div>
      <div class="headless-row">
        <input type="text" id="m-headless-baseref" value="HEAD~1" placeholder="e.g. main, or a commit SHA">
        <button id="m-headless-run" class="headless-run-btn" title="Start headless grading — runs reviewer, evaluator, and security-review against the base ref"><svg viewBox="0 0 16 16"><path d="M4 2.5v11l9-5.5z"/></svg> Start</button>
      </div>
      <div id="m-headless-status"></div>
    </div>`;
  const descEl = document.getElementById('m-headless-step-desc');
  const stepEls = el.querySelectorAll('.headless-step');
  stepEls.forEach(stepEl => {
    stepEl.addEventListener('click', () => {
      const idx = Number(stepEl.dataset.stepIdx);
      // Step 3 when done: toggle the results output directly
      if (idx === 2 && (stepEl.classList.contains('done') || stepEl.classList.contains('fail'))) {
        const outputToggle = document.querySelector('#m-headless-status .headless-view-output');
        if (outputToggle) outputToggle.click();
        return;
      }
      const alreadyOpen = descEl.classList.contains('expanded') && descEl.dataset.stepIdx === String(idx);
      if (alreadyOpen) {
        descEl.classList.remove('expanded');
        descEl.dataset.stepIdx = '';
        stepEls.forEach(s => s.classList.remove('selected'));
      } else {
        descEl.textContent = HEADLESS_STEP_DESCRIPTIONS[idx];
        descEl.dataset.stepIdx = String(idx);
        descEl.classList.add('expanded');
        stepEls.forEach(s => s.classList.toggle('selected', s === stepEl));
      }
    });
  });
  document.getElementById('m-headless-run').addEventListener('click', () => {
    const input = document.getElementById('m-headless-baseref');
    const baseRef = input.value.trim();
    if (!baseRef) { input.focus(); return; }
    postWrite(`/api/ticket/${encodeURIComponent(t.id)}/headless-run`, { base_ref: baseRef }, 'start the headless run')
      .then(res => {
        if (!res.ok) return; // t-1940: the reason is toasted; a refused start used to vanish silently
        renderHeadlessStatus(t.id, res.data);
        if (res.data.status === 'running') startHeadlessPoll(t.id);
      });
  });
  // Pick up an already-in-progress run (e.g. the modal was reopened) rather than
  // showing a blank idle state that hides real, ongoing work.
  fetch(`/api/ticket/${encodeURIComponent(t.id)}/headless-run`)
    .then(r => r.json())
    .then(data => {
      renderHeadlessStatus(t.id, data);
      if (data.status === 'running') startHeadlessPoll(t.id);
    })
    .catch(() => {});
}

// The ticket's board lane (effectiveStatus, so a worktree run sits with IN PROGRESS), newest first.
function laneTicketIds(cur) {
  if (!cur) return [];
  return state.tickets.filter(t => effectiveStatus(t) === effectiveStatus(cur))
    .sort((a, b) => (b.created || '').localeCompare(a.created || ''))
    .map(t => t.id);
}

function navigateTicket(dir) {
  if (modalState.editMode) return;
  const cur = state.tickets.find(t => t.id === state.selectedId);
  const ids = laneTicketIds(cur);
  const idx = ids.indexOf(state.selectedId);
  const nextId = ids[idx + dir];
  if (!nextId) return;
  openModal(nextId);
}

function visibleDocs(t) { return (t.docs || []).filter(d => !HIDDEN_DOC_SLUGS.has(docSlug(t, d.file))); }

export function renderModalDocs(t) {
  const docs = visibleDocs(t);
  const bar = document.getElementById('m-docs');
  const paneBar = document.getElementById('m-pane-bar');
  const locked = t.status === 'closed' || t.status === 'cancelled';
  const ghosts = locked ? [] : availableDocTypes(t);   // t-bb97: a doc that does not exist yet shows as a dashed ghost node

  const descActive = modalState.activeDoc === null && !modalState.ghost;
  const cs = cockpitFor(t);   // t-6254: a doc the sprint changed since the rail was last opened
  const node = (key, active, name, isNew) =>
    `<div class="doc-node" data-key="${escAttr(key)}">${expanderHTML(key)}<button class="doc-tab${active ? ' active' : ''}" data-file="${escAttr(key)}">${esc(name)}${isNew ? '<span class="doc-new">New</span>' : ''}</button></div>`;
  const descTab = docs.length > 0 || ghosts.length > 0 ? node('', descActive, 'Description') : '';
  const ghostNode = dt =>
    `<div class="doc-node"><button class="doc-tab doc-ghost${modalState.ghost === dt.slug ? ' active' : ''}" data-ghost="${escAttr(dt.slug)}" title="${escAttr('Not created yet — ' + dt.hint)}">${esc(dt.name)}<span class="doc-ghost-plus" aria-hidden="true">+</span></button></div>`;

  const ticketIds = laneTicketIds(t);
  const ticketIdx = ticketIds.indexOf(t.id);
  const navPrev = `<button class="doc-nav-btn" id="btn-ticket-prev" title="Previous ticket"${ticketIdx <= 0 ? ' disabled' : ''}>‹</button>`;
  const navNext = `<button class="doc-nav-btn" id="btn-ticket-next" title="Next ticket"${ticketIdx >= ticketIds.length - 1 ? ' disabled' : ''}>›</button>`;

  // t-e78b, t-26f9: a worktree-bound ticket's sprint docs are the live worktree copy, and board edits are saved there
  // (guarded by the etag each read returned). The Description tab is main's ticket.md, edited as before.
  const liveBranch = t.docs_from && t.docs_from.branch;
  const liveDoc = !!(liveBranch && modalState.activeDoc);
  // t-26f9: a bound ticket's docs are editable now; the badge says where edits land, and warns when the agent is working.
  const liveRow = liveDoc ? state.cockpitRows.get(t.id) : null;
  // The server writes only these three docs in a worktree; any other file there (design.md, eval-report.md) stays read-only.
  const liveReadOnly = liveDoc && !LIVE_EDITABLE_SLUGS.includes(docSlug(t, modalState.activeDoc));
  const liveBadge = liveDoc
    ? `<span class="doc-live-badge" id="doc-live-badge" title="${escAttr(`Edits save to ${liveBranch}'s copy of these files — the sprint session's working files`)}">Live from ${esc(liveBranch)} · edits save to its copy</span>`
      + (liveRow && ckRowState(liveRow) === 'working' ? `<span class="doc-working-note" id="doc-working-note">the agent is working in ${esc(liveBranch)} — your edit may collide</span>` : '')
    : '';
  const rightControls = modalState.editMode
    ? `<div class="doc-tab-right">${navPrev}${navNext}<button class="doc-save-btn" id="btn-save-top">Save</button><button class="doc-cancel-btn" id="btn-cancel-top">Cancel</button></div>`
    : liveReadOnly
      ? `<div class="doc-tab-right">${navPrev}${navNext}${liveBadge}<span class="doc-locked-badge" title="The board edits only acceptance, plan and research in a worktree; the sprint session owns this file">read-only here</span></div>`
    : modalState.docOverride[modalState.activeDoc] != null
      ? `<div class="doc-tab-right">${navPrev}${navNext}<span class="doc-locked-badge" title="The worktree session's copy; edit it there">worktree copy · read-only</span></div>`
    : locked
      ? `<div class="doc-tab-right">${navPrev}${navNext}<span class="doc-locked-badge" title="Reopen ticket to edit">read-only</span></div>`
      : `<div class="doc-tab-right">${navPrev}${navNext}${liveBadge}${modalState.ghost ? '' : '<span class="doc-edit-hint">Double-click to edit</span>'}</div>`;

  bar.innerHTML = descTab + docs.map(d => {
    return node(d.file ?? '', d.file === modalState.activeDoc, d.name, !!(cs && cs.fresh[docSlug(t, d.file)]));
  }).join('') + ghosts.map(ghostNode).join('');
  paneBar.innerHTML = rightControls;

  bar.querySelectorAll('.doc-tab:not(.doc-ghost)').forEach(btn => {
    btn.addEventListener('click', () => {
      if (modalState.editMode) return;
      activateDoc(t, btn.dataset.file || null);
    });
  });
  bar.querySelectorAll('.doc-ghost').forEach(btn => {
    btn.addEventListener('click', () => {
      if (modalState.editMode) return;
      activateGhost(t, btn.dataset.ghost);
    });
  });

  document.getElementById('btn-ticket-prev')?.addEventListener('click', () => navigateTicket(-1));
  document.getElementById('btn-ticket-next')?.addEventListener('click', () => navigateTicket(1));

  document.getElementById('btn-save-top')?.addEventListener('click', () => saveEdit(t));
  document.getElementById('btn-cancel-top')?.addEventListener('click', () => exitEditMode(t));

  // Re-inject the persistent check tip (innerHTML wipe removes it) — not on a live
  // worktree doc (t-e78b), whose checkboxes can't be toggled from the board.
  if (!liveDoc) {
    const tip = document.createElement('span');
    tip.id = 'm-check-tip';
    tip.className = 'doc-check-tip';
    tip.innerHTML = '<span class="doc-check-tip-icon">☑</span>Click to check off';
    paneBar.appendChild(tip);
  }
  renderDocChildren();
}

// t-612f: the tree's sections. Every doc's `##` headings and checkbox counts are parsed from its markdown (the
// Description from the ticket body, the others read once when the modal opens), so a doc shows a + before it is opened.
function slugOf(text) { return String(text).trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, ''); }

function parseDocSections(content) {
  const out = [];
  let cur = null, fenced = false;
  String(content || '').split('\n').forEach(l => {
    if (/^\s*```/.test(l)) { fenced = !fenced; return; }
    if (fenced) return;
    const h = /^##\s+(.+?)\s*#*\s*$/.exec(l);
    // the text the rendered heading shows: image and link markup removed
    if (h) { const text = h[1].replace(/!\[[^\]]*\]\([^)]*\)/g, '').replace(/\[([^\]]*)\]\([^)]*\)/g, '$1').replace(/[`*_]/g, '').trim(); cur = { text, slug: slugOf(text), done: 0, total: 0 }; out.push(cur); return; }
    const m = cur && /^\s*[-*]\s+\[( |x|X)\]/.exec(l);
    if (m) { cur.total++; if (m[1] !== ' ') cur.done++; }
  });
  return out;
}

function expanderHTML(key) {
  if ((modalState.sections[key] || []).length < 2) return '<span class="doc-expander-spacer"></span>';
  const open = modalState.expanded.has(key);
  return `<button type="button" class="doc-expander" data-key="${escAttr(key)}" aria-expanded="${open}" aria-label="${open ? 'Collapse' : 'Expand'} sections">${open ? '\u2212' : '+'}</button>`;
}

// the rendered doc: give its section headings ids to scroll to, refresh this doc's sections from the text just shown,
// and honour a pending jump (a child row of a doc that was not open)
export function markDocHeadings(container, content) {
  container.querySelectorAll('.doc-heading-2').forEach(h => { h.id = 'section-' + slugOf(h.textContent); });
  modalState.sections[modalState.activeDoc || ''] = parseDocSections(content);
  refreshDocTree();
  if (modalState.pendingScroll) {
    document.getElementById('section-' + modalState.pendingScroll)?.scrollIntoView({ block: 'start' });
    modalState.pendingScroll = '';
  }
}

export function refreshDocTree() {
  document.querySelectorAll('#m-docs .doc-node').forEach(node => {
    const old = node.querySelector('.doc-expander, .doc-expander-spacer');
    if (old) old.outerHTML = expanderHTML(node.dataset.key);
  });
  renderDocChildren();
}

function renderDocChildren() {
  const tree = document.getElementById('m-docs');
  tree.querySelectorAll('.doc-children').forEach(el => el.remove());
  tree.querySelectorAll('.doc-node').forEach(node => {
    const key = node.dataset.key, secs = modalState.sections[key] || [];
    if (secs.length < 2 || !modalState.expanded.has(key)) return;
    const wrap = document.createElement('div');
    wrap.className = 'doc-children';
    wrap.innerHTML = secs.map(sec =>
      `<button class="doc-child" data-key="${escAttr(key)}" data-slug="${escAttr(sec.slug)}">${esc(sec.text)}${sec.total ? `<span class="doc-child-count">${sec.done}/${sec.total}</span>` : ''}</button>`).join('');
    node.after(wrap);
  });
}

export function activateDoc(t, file, scrollSlug = '') {
  const key = file || '';
  modalState.ghost = '';
  modalState.activeDoc = file;
  if (!modalState.seen.has(key)) { modalState.seen.add(key); modalState.expanded.add(key); }   // opened for the first time: shown expanded; after that the choice is the user's
  const cs = cockpitFor(t);
  const slug = file ? docSlug(t, file) : '';
  if (cs && cs.fresh[slug]) { delete cs.fresh[slug]; renderCockpitDetails(cs); }   // t-6254: viewed, no longer New
  modalState.pendingScroll = scrollSlug;
  renderModalDocs(t);
  renderModalBody(t);
  refreshModalActions(t);
  document.getElementById('m-kbd').style.display = '';
}

// t-6254: the open cockpit tab for this ticket, else null (a board-opened modal has no New marks).
function cockpitFor(t) {
  return cockpitState && cockpitState.id === t.id && document.getElementById('cockpit-overlay').classList.contains('open') ? cockpitState : null;
}

// t-6254: opened from the cockpit, a worktree session's plan/acceptance come from the worktree, not main's copy.
export function fetchModalDoc(file) {
  const o = modalState.docOverride[file];
  return o != null ? Promise.resolve({ ok: true, json: () => Promise.resolve({ content: o, etag: '' }) }) : fetch(`/api/doc/${encodeURIComponent(file)}`);
}

function prefetchDocSections(t) {
  const seq = ++modalState.prefetchSeq;
  visibleDocs(t).forEach(d => {
    fetchModalDoc(d.file)
      .then(r => r.ok ? r.json() : null)
      .then(j => {
        if (!j || seq !== modalState.prefetchSeq || state.selectedId !== t.id) return;
        if (!(d.file === modalState.activeDoc && modalState.sections[d.file])) modalState.sections[d.file] = parseDocSections(j.content);
        refreshDocTree();
      })
      .catch(() => {});   // an unreadable doc just shows no +
  });
}
