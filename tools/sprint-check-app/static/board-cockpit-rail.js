import { SHELL_TAB, docSlug, state } from './board-core.js';
import { displayTicketId, effectiveStatus, esc, escAttr } from './board-helpers.js';
import { SCRATCH_ID, announceScratchTabs, findTicketById, normProjectPath, renderScratchWhere, showToast } from './board-render.js';
import { activateDoc, modalState, openModal } from './board-modal.js';
import { hasFilledCheckbox, hasUsefulSectionText, parseGateModel, sectionContent } from './board-docs.js';
import { activeTabId, closeTab, cockpitState, cockpitTabs, newCockpitTabState, openLeaveConfirm, refreshSessionStateChip, renderSessionStateChip, sessionIsLive, setActiveTab, teardownCockpit } from './board-cockpit.js';
import { cockpitPathKey, fetchWorktreeLock, formatStateAsParagraphs, maybeMountCockpitTerminal, renderCockpitWorktree } from './board-worktree.js';

// t-a198: the keyboard prefix (see the shell). Keys typed with focus in the board come here; the terminal frame's
// come through the message relay above. Ignored in fields and under a modal; a standalone board has no shell.
// canon:prefix-keys:begin (t-a198) — identical in cockpit.html, static/board-cockpit-rail.js and cockpit-daemon/web/cockpit.html; tests/prefix-keys-parity.sh pins the copies
function canonPrefixLabel() {
  var v = 'ctrl+.';
  try { var s = localStorage.getItem('canon-prefix'); if (s && /^ctrl\+[^A-Za-z0-9\s\\+]$/.test(s)) v = s; } catch (e) {}
  return v;
}
function canonPrefixKeys(emit) {
  var armed = false, timer = null, swallow = null;
  function disarm() { armed = false; if (timer) { clearTimeout(timer); timer = null; } }
  function handle(e) {
    var t = e.type, k = e.key;
    if (swallow !== null && e.code === swallow && (t === 'keypress' || t === 'keyup')) {
      if (t === 'keyup') swallow = null;
      e.preventDefault(); e.stopPropagation();
      return true;
    }
    if (t !== 'keydown' || e.isComposing) return false;
    if (k === 'Control' || k === 'Shift' || k === 'Alt' || k === 'Meta' || k === 'AltGraph' || k === 'CapsLock') return false;
    swallow = null;
    if (armed) {
      disarm();
      swallow = e.code;
      e.preventDefault(); e.stopPropagation();
      if (k === 'Escape') emit('cancel', ''); else emit('key', k);
      return true;
    }
    var altgr = e.getModifierState && e.getModifierState('AltGraph');
    if (e.ctrlKey && !e.altKey && !altgr && !e.metaKey && !e.shiftKey && !e.repeat && k === canonPrefixLabel().slice(5)) {
      armed = true; swallow = e.code;
      timer = setTimeout(function () { if (armed) { disarm(); emit('cancel', ''); } }, 1500);
      e.preventDefault(); e.stopPropagation();
      emit('armed', '');
      return true;
    }
    return false;
  }
  return { handle: handle, cancel: function () { if (armed) { disarm(); emit('cancel', ''); } } };
}
// canon:prefix-keys:end
export const boardKeys = canonPrefixKeys((type, key) => {
  if (window.parent === window) return;
  try { window.parent.postMessage({ source: 'canon-board', type: 'prefix-' + type, key, tab: SHELL_TAB }, location.origin); } catch {}
});
function boardKeyBlocked(e) {
  const t = e.target;
  if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return true;
  return !!document.querySelector('#commit-overlay.open, #create-overlay.open, #modal-overlay.open, #tour-overlay.open');
}

// t-2d2e: a freshly opened project tab's ticket list loads after its iframe does.
export function openTicketWhenLoaded(ticket, tries) {
  if (findTicketById(ticket)) { openCockpit(ticket); return; }
  if (tries > 0) { setTimeout(() => openTicketWhenLoaded(ticket, tries - 1), 250); return; }
  showToast(`⚠ ${ticket} not found in this project`, 'warn');
}

// t-bc04: ticket status badge (topbar #ck-status + rail #ck-tc-status), colored
// to match the board's status columns (--col-* vars). Live-updates via the poll.
export function statusBadgeInfo(status) {
  switch (status) {
    case 'in_progress': return { label: 'in progress', cls: 'st-progress' };
    case 'closed':      return { label: 'closed',      cls: 'st-done' };
    case 'cancelled':   return { label: 'discarded',   cls: 'st-discarded' };
    case 'archived':    return { label: 'archived',    cls: 'st-discarded' };
    case 'open':        return { label: 'open',        cls: 'st-open' };
    case 'scratch':     return { label: 'scratch',     cls: 'st-open' };
    default:            return { label: status || '',  cls: 'st-open' };
  }
}
function renderCockpitStatusBadge(t) {
  const info = statusBadgeInfo(t && t.status);
  for (const id of ['ck-status', 'ck-tc-status']) {
    const el = document.getElementById(id);
    if (!el) continue;
    el.textContent = info.label;
    el.className = 'ck-status-badge ' + info.cls;
  }
}

// t-bc04: clamp the preview width to a sane range so a stale/huge persisted
// value can't wedge the pane off-screen.
function clampPreviewW(w) {
  // Allow the preview to grow to most of the window (splitter can move far
  // left); keep a thin terminal sliver visible. No fixed px ceiling — the old
  // 900px cap was the wall that made the splitter feel stuck on wide screens.
  const max = Math.round(window.innerWidth * 0.92);
  return Math.max(240, Math.min(w, max));
}
let _ckPreviewResizeWired = false;
// t-bc04: apply the persisted width and wire the left-edge drag handle (once).
// Width is driven by the --ck-preview-w CSS var (not an inline width), so the
// more-specific `.ck-preview.collapsed{width:40px}` rule still wins on collapse.
function ensurePreviewResize() {
  const pv = document.getElementById('ck-preview');
  const handle = document.getElementById('ck-preview-resize');
  if (!pv || !handle) return;
  const stored = parseInt(localStorage.getItem('ck-preview-w') || '', 10);
  if (!isNaN(stored)) pv.style.setProperty('--ck-preview-w', clampPreviewW(stored) + 'px');
  if (_ckPreviewResizeWired) return;
  _ckPreviewResizeWired = true;
  let startX = 0, startW = 0, dragging = false;
  handle.addEventListener('mousedown', (e) => {
    dragging = true; startX = e.clientX; startW = pv.getBoundingClientRect().width;
    document.body.style.userSelect = 'none';
    e.preventDefault();
  });
  document.addEventListener('mousemove', (e) => {
    if (!dragging) return;
    // Panel is on the right (border-left): dragging left widens it.
    pv.style.setProperty('--ck-preview-w', clampPreviewW(startW + (startX - e.clientX)) + 'px');
  });
  document.addEventListener('mouseup', () => {
    if (!dragging) return;
    dragging = false;
    document.body.style.userSelect = '';
    localStorage.setItem('ck-preview-w', String(clampPreviewW(Math.round(pv.getBoundingClientRect().width))));
  });
}

// t-8a2a: renders the tab strip into both containers it can appear in — on
// the board (visible when the overlay is closed) and mirrored in the topbar
// (visible while a session is open) — from the same cockpitTabs data, so
// "back to board shows N running" and in-overlay switching both work from one
// render call. A pill's own needs-you dot is how a BACKGROUND tab's status
// stays visible without switching to it (the topbar badge only reflects the
// active tab).
export function renderTabStrip() {
  const ids = Object.keys(cockpitTabs);
  const html = ids.map(id => {
    const tab = cockpitTabs[id];
    const t = findTicketById(id);
    const label = t ? displayTicketId(t) : id;
    const needsYou = tab.status === 'needs-you';
    return `<span class="ck-tab-pill${id === activeTabId ? ' active' : ''}" data-tab-id="${esc(id)}">`
      + (needsYou ? '<span class="ck-tab-pill-needsyou" title="Agent is waiting on you"></span>' : '')
      + `<span class="ck-tab-pill-id">${esc(label)}</span>`
      + `<button class="ck-tab-pill-close b-neutral" data-tab-id="${esc(id)}" title="Close tab (session stays running)" type="button">×</button>`
      + `</span>`;
  }).join('');
  for (const containerId of ['ck-tab-strip', 'ck-tab-strip-topbar']) {
    const el = document.getElementById(containerId);
    if (!el) continue;
    el.innerHTML = html;
    el.hidden = ids.length === 0;
  }
  document.querySelectorAll('.ck-tab-pill').forEach(pill => {
    pill.addEventListener('click', () => openCockpit(pill.dataset.tabId));
  });
  document.querySelectorAll('.ck-tab-pill-close').forEach(btn => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      closeTab(btn.dataset.tabId);
    });
  });
}

// Rail rendering for the ACTIVE tab only (grill #1: rail/badge stay singular,
// driven by whichever tab is active, re-rendered on switch — no per-tab
// accordion/scroll state). Shared by a fresh tab open and a switch to an
// already-open tab; never touches the terminal iframe itself.
export async function renderCockpitRail(t) {
  renderSessionStateChip();
  refreshSessionStateChip();
  document.getElementById('cockpit').classList.toggle('scratch-mode', !!t.scratch);
  document.getElementById('ck-id').textContent = displayTicketId(t);
  document.getElementById('ck-title').textContent = t.title || '';
  document.getElementById('ck-title').title = t.title || '';   // t-b91f: the full title when the bar truncates it
  document.getElementById('ck-tc-id').textContent = displayTicketId(t);
  document.getElementById('ck-tc-title').textContent = t.title || '';
  renderCockpitStatusBadge(t);
  if (t.scratch) {   // t-47f1: no worktree, plan, acceptance or state to show
    document.getElementById('ck-model').textContent = 'model: agent default';
    renderScratchWhere(cockpitState);
    return;
  }
  renderCockpitModel(t);
  await renderCockpitWorktree(t);
  // t-1357: once the worktree lock/main path are known, pull the active
  // ticket's docs from the worktree the session runs in (if any) so the rail
  // reflects that tree, not the main checkout. Then (re)render the doc panels.
  await fetchCockpitWorktreeDocs(t);
  renderCockpitModel(t);
  await renderCockpitDocs(t);
  await renderCockpitState(t);
}

// t-8a2a: one shared 5s poll for every open tab, not N independent timers
// (grill #2) — daemon-staleness relay reaches EVERY open tab's iframe each
// tick, but the rail-refresh render calls only run for the active tab (that
// DOM belongs to whichever tab is shown). Started once, by the first tab to
// open; stops itself once the last tab closes (also enforced by unmountTab).
let cockpitPollTimer = null;

export function stopCockpitPoll() {
  if (cockpitPollTimer) { clearInterval(cockpitPollTimer); cockpitPollTimer = null; }
}

function ensureCockpitPollTimer() {
  if (cockpitPollTimer) return;
  cockpitPollTimer = setInterval(async () => {
    const ids = Object.keys(cockpitTabs);
    if (!ids.length) { stopCockpitPoll(); return; }
    // t-74d6: re-check daemon staleness on the poll (GET /api/cockpit =
    // discover, never relaunch) and re-relay to every open tab's iframe, so a
    // daemon that drifts while sessions are open surfaces the banner without
    // a remount — this matters for a backgrounded tab too, since the drift
    // affects the real running process regardless of visibility.
    try {
      const cr = await fetch('/api/cockpit');
      const cd = await cr.json();
      if (cd && cd.running) {
        const bi = { stale: !!cd.stale, running_build: cd.running_build || null, latest_build: cd.latest_build || null };
        for (const tid of ids) {
          const tab = cockpitTabs[tid];
          tab.buildInfo = bi;
          if (tab.addr && tab.iframeEl && tab.iframeEl.contentWindow) {
            tab.iframeEl.contentWindow.postMessage({ source: 'canon-cockpit', type: 'daemon-build', info: bi }, 'http://' + tab.addr);
          }
        }
      }
    } catch {}
    refreshSessionStateChip(); // t-824e: the active tab's state chip + reaper line
    const ct = findTicketById(activeTabId);
    if (!ct || ct.scratch) return;
    await fetchCockpitWorktreeDocs(ct);
    renderCockpitDocs(ct);
    renderCockpitState(ct);
    renderCockpitStatusBadge(ct);
  }, 5000);
}

export async function openCockpit(id) {
  const t = findTicketById(id);
  if (!t) return;
  state.selectedId = id;
  ensurePreviewResize();
  document.getElementById('cockpit').classList.remove('rail-collapsed');
  document.getElementById('cockpit-overlay').classList.add('open');

  if (cockpitTabs[id]) {
    // Already open — switch only. Never re-src's the iframe, never
    // reconnects; the terminal keeps its live connection while backgrounded.
    // t-82f4: same guarantee now extends to the preview pane — setActiveTab()
    // below restores this tab's own preview container + collapsed state
    // exactly as left, instead of the old unconditional reset.
    setActiveTab(id);
    await renderCockpitRail(t);
    if (cockpitState.needsRemount) {
      cockpitState.needsRemount = false;
      await maybeMountCockpitTerminal(t);
    }
    renderTabStrip();
    return;
  }

  // New tab: mount a fresh, persistent iframe for this ticket. data-tab-id
  // is a STABLE identifier (unlike id="ck-iframe", which migrates to
  // whichever tab is active) — lets a background tab's own iframe still be
  // located directly, e.g. for tests.
  const iframe = document.createElement('iframe');
  iframe.title = 'Agent terminal';
  iframe.style.visibility = 'hidden';
  iframe.dataset.tabId = id;
  document.getElementById('ck-term').appendChild(iframe);
  cockpitTabs[id] = newCockpitTabState(id, iframe);
  setActiveTab(id);
  announceScratchTabs();
  // t-cd06: resuming an in_progress ticket reuses its persisted worktree
  // server-side (the daemon owns that, not the board) — only a fresh OPEN
  // start needs an explicit row picked before the terminal is allowed to mount.
  cockpitState.worktreeCwd = (t.status === 'open') ? null : '';
  if (state.adoptCwd && typeof state.adoptCwd[id] === 'string') {   // t-f553: continue where the scratch session ran
    const c = state.adoptCwd[id];
    cockpitState.worktreeCwd = (!c || normProjectPath(c) === normProjectPath(state.gitRoot)) ? '' : c;
    delete state.adoptCwd[id];
  }
  renderTabStrip();
  await renderCockpitRail(t);
  await maybeMountCockpitTerminal(t);
  ensureCockpitPollTimer();
}

// t-8a2a (grill #3): "← Board" only hides the overlay — no session ends, no
// iframe is touched. Every open tab (this one and any others) keeps running
// hidden in the background; the board's own tab strip still shows them, and
// reopening any of them restores that view without reconnecting. Ending a
// session is now a separate, explicit action — see #ck-end-session below.
export function closeCockpit() {
  document.getElementById('cockpit-overlay').classList.remove('open');
}

// t-2687: a tab that was never attached (closed/reopened, or opened from the COCKPIT SESSIONS
// row and Start not yet pressed) has no session id/token, so the board can't end the daemon's
// live session for that ticket (t-ddc8: the board never holds the daemon token). Tearing the
// tab down anyway looked like success while the session kept running — find it and say so.
export async function findLiveDaemonSession(ticketId) {
  try {
    const r = await fetch('/api/cockpit-sessions');
    if (!r.ok) return null;
    const list = await r.json();
    if (!Array.isArray(list)) return null;
    const root = state.git && state.git.root ? cockpitPathKey(state.git.root) : '';
    // Match the project too so two projects sharing a ticket id don't collide — but when either root is
    // unknown (e.g. the board fell back to mock git data) it can't be checked, so the ticket id decides.
    // /api/cockpit-sessions lists only non-exited sessions (daemon handleSessions).
    return list.find(s => String(s.ticket) === ticketId
      && (!root || !s.project_root || cockpitPathKey(s.project_root) === root)) || null;
  } catch { return null; }
}

function openDetachedSessionNotice(s) {
  // A notice, not a choice: hide the two actions (a disabled Save & End still reads as clickable)
  // and let the dismiss button say OK. openLeaveConfirm() restores all three for the normal dialog.
  document.getElementById('ck-leave-save').style.display = 'none';
  document.getElementById('ck-leave-skip').style.display = 'none';
  const ok = document.getElementById('ck-leave-cancel');
  ok.disabled = false;
  ok.textContent = 'OK';
  // t-f553: a scratch tab has no sprint; its button is Start agent.
  const scratch = SCRATCH_ID.test(String(s.ticket || ''));
  document.getElementById('ck-leave-confirm-title').textContent = scratch ? 'A scratch session is still running' : 'A sprint session is still running';
  document.getElementById('ck-leave-confirm-body').textContent =
    `A ${String(s.agent || 'agent')} session for this ${scratch ? 'scratch session' : 'ticket'} is still running in the daemon but isn't attached to this tab, ` +
    `so End Session can't end it from here. Click ▶ ${scratch ? 'Start agent' : 'Start sprint'} to reattach, then End Session.`;
  document.getElementById('ck-leave-confirm-status').textContent = '';
  document.getElementById('ck-leave-confirm').classList.add('open');
}

// t-1357: when the cockpit session runs in a WORKTREE, its plan/acceptance/
// HANDOFF live on the worktree's branch — the board's main .tickets/<id>/ shows
// only the committed ticket.md. Pull those docs from the effective worktree so
// the rail reflects the tree the agent is editing. Effective cwd = the daemon-
// resolved actual cwd (post-Start, t-7590) else the persisted lock cwd. Skips
// (clears the cache → main-checkout path) for the main checkout or when there's
// no worktree. Fails safe: any error clears the cache.
async function fetchCockpitWorktreeDocs(t) {
  let eff = cockpitState.actualCwd;
  if (!eff) {
    const lock = cockpitState.worktreeLock || {};
    if (lock.locked && lock.cwd) eff = lock.cwd;
  }
  const mainPath = cockpitState.worktreeMainPath;
  if (!eff || (mainPath && cockpitPathKey(eff) === cockpitPathKey(mainPath))) {
    cockpitState.worktreeDocs = null;
    return;
  }
  try {
    const r = await fetch(`/api/cockpit-docs/${encodeURIComponent(t.id)}?cwd=${encodeURIComponent(eff)}`);
    cockpitState.worktreeDocs = r.ok ? await r.json() : null;
  } catch {
    cockpitState.worktreeDocs = null;
  }
}

// Model chip is read-only, sourced from plan.md's `Gate model:` (or the default).
async function renderCockpitModel(t) {
  const el = document.getElementById('ck-model');
  el.textContent = 'model: from plan.md';
  let planContent = (cockpitState.worktreeDocs || {}).plan; // t-1357: worktree plan wins
  if (planContent == null) {
    const planDoc = (t.docs || []).find(d => docSlug(t, d.file) === 'plan');
    if (!planDoc) return;
    try {
      const r = await fetch(`/api/doc/${encodeURIComponent(planDoc.file)}`);
      if (!r.ok) return;
      planContent = (await r.json()).content || '';
    } catch { return; }
  }
  const gm = parseGateModel(planContent || '');
  if (gm.filled && gm.value) el.textContent = `model: ${gm.value} · plan.md`;
}

// t-6254: the rail's Ticket details row. The poll already reads plan.md and acceptance.md (the worktree's copy wins,
// t-1357); the first read is the baseline, a later change marks that doc New until the popup shows it. View-only.
const CK_WATCHED_DOCS = [['plan', 'Plan'], ['acceptance', 'Acceptance']];

// null = the ticket has no such doc; undefined = the read failed (skip this tick, never read it as "absent").
async function fetchCockpitDoc(t, slug) {
  const wd = (cockpitState.worktreeDocs || {})[slug];
  if (wd != null) return wd;
  const doc = (t.docs || []).find(d => docSlug(t, d.file) === slug);
  if (!doc) return null;
  try {
    const r = await fetch(`/api/doc/${encodeURIComponent(doc.file)}`);
    if (r.ok) return (await r.json()).content || '';
  } catch {}
  return undefined;
}

// A doc still at its seeded skeleton has nothing to read yet; the first real content is "written", later edits "updated".
function ckDocHasSubstance(slug, text) {
  if (text == null) return false;
  if (slug === 'plan') return hasUsefulSectionText(sectionContent(text, 'Approach'), ['How will we implement it?']);
  return hasFilledCheckbox(sectionContent(text, 'Criteria'));
}

function ckNewestFresh(cs) {   // fresh keeps insertion order, so the last key is the newest change
  const keys = Object.keys(cs.fresh);
  return keys.length ? keys[keys.length - 1] : '';
}

export function renderCockpitDetails(cs) {
  if (!cs || cs !== cockpitState) return;
  const slug = ckNewestFresh(cs);
  const badge = document.getElementById('ck-details-badge');
  badge.style.display = slug ? '' : 'none';
  badge.textContent = slug ? cs.fresh[slug] : '';
  document.getElementById('ck-details-note').style.display = slug ? 'none' : '';   // the badge takes the note's line
}

export async function renderCockpitDocs(t) {
  const cs = cockpitState;
  const src = cs.worktreeDocs ? 'worktree' : 'main';
  if (cs.docSeenSrc !== src) { cs.docSeenSrc = src; cs.docSeen = {}; cs.fresh = {}; }   // another copy of the docs is not a change
  for (const [slug, name] of CK_WATCHED_DOCS) {
    const content = await fetchCockpitDoc(t, slug);
    if (cs !== cockpitState) return;   // the tab switched while reading
    if (content === undefined) continue;
    if (!(slug in cs.docSeen)) { cs.docSeen[slug] = content; continue; }
    const prev = cs.docSeen[slug];
    if (prev === content) continue;
    cs.docSeen[slug] = content;
    if (content === null) continue;
    delete cs.fresh[slug];
    cs.fresh[slug] = `${name} ${ckDocHasSubstance(slug, prev) ? 'updated' : 'written'}`;
  }
  renderCockpitDetails(cs);
  renderCockpitChanges(t);
}

// Opens the ticket viewer over the cockpit on the newest New doc (or Description). A worktree session's plan and
// acceptance are the worktree's copies, shown read-only.
export function openCockpitDetails() {
  const t = findTicketById(activeTabId);
  const cs = cockpitState;
  if (!t || !cs) return;
  modalState.docOverride = {};
  for (const [slug] of CK_WATCHED_DOCS) {
    const wd = (cs.worktreeDocs || {})[slug];
    const doc = (t.docs || []).find(d => docSlug(t, d.file) === slug);
    if (wd != null && doc) modalState.docOverride[doc.file] = wd;
  }
  openModal(t.id);
  const slug = ckNewestFresh(cs);
  const doc = slug && (t.docs || []).find(d => docSlug(t, d.file) === slug);
  if (doc) activateDoc(t, doc.file);
}

// t-5a4b: "Changes since you started" for a project without git — the daemon's snapshot comparison
// (added / edited / deleted / renamed since the session's baseline), shown in the sidebar and the cockpit.
const CHANGE_SYMBOL = { added: '+', modified: '~', deleted: '\u2212', renamed: '\u2192' };
async function fetchChanges(id) {
  try { const r = await fetch('/api/cockpit-changes?id=' + encodeURIComponent(id)); return r.ok ? await r.json() : null; } catch { return null; }
}
function changeRows(c, max) {
  const files = Array.isArray(c && c.files) ? c.files : [];
  const rows = files.slice(0, max).map(f => {
    const what = f.status === 'renamed' ? `${f.from} \u2192 ${f.path}` : f.path;
    const lines = (f.added_lines || f.removed_lines) ? ` (+${f.added_lines || 0} \u2212${f.removed_lines || 0})` : '';
    return `<div class="change-row"><span class="change-sym">${esc(CHANGE_SYMBOL[f.status] || '~')}</span><span class="change-path" title="${escAttr(what)}">${esc(what)}</span><span class="change-lines">${esc(lines)}</span></div>`;
  });
  const total = Number(c && c.total) || files.length;
  if (total > max) rows.push(`<div class="change-more">and ${total - max} more</div>`);
  if (!rows.length) rows.push(`<div class="change-empty">${esc((c && c.note) || 'Nothing has changed yet.')}</div>`);
  else if (c && c.note) rows.push(`<div class="change-empty">${esc(c.note)}</div>`);
  return rows.join('');
}
async function renderCockpitChanges(t) {
  if (state.isGitProject || !t || !t.id) return;
  const box = document.getElementById('ck-changes');
  if (!box) return;
  const c = await fetchChanges(t.id);
  box.innerHTML = changeRows(c, 20);
  const n = c && Number(c.total);
  document.getElementById('ck-changes-count').textContent = n ? `(${n})` : '';
}
let sidebarChangesStamp = 0;
export async function renderSidebarChanges() {
  if (state.isGitProject) return;
  const box = document.getElementById('s-changes');
  if (!box || Date.now() - sidebarChangesStamp < 8000) return;
  sidebarChangesStamp = Date.now();
  const active = (state.tickets || []).filter(t => effectiveStatus(t) === 'in_progress').slice(0, 3);
  if (!active.length) { box.innerHTML = '<div class="change-empty">No sprint is running.</div>'; return; }
  const parts = await Promise.all(active.map(async t => `<div class="change-ticket">${esc(t.id)}</div>` + changeRows(await fetchChanges(t.id), 6)));
  box.innerHTML = parts.join('');
}

// Finds this ticket's own bullet under HANDOFF.md's "## In Progress" section
// (the save-state convention documented in tools/handoff.md: "- Ticket or
// file path — current state" — free-form prose, not a rigid schema) by
// matching the ticket id anywhere in the bullet's own top line, then
// capturing any indented continuation lines until the next top-level bullet.
export function findHandoffStateForTicket(raw, ticketId) {
  if (!raw) return null;
  const section = sectionContent(raw, 'In Progress');
  if (!section) return null;
  const idRe = new RegExp('\\b' + ticketId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b');
  let current = null, matched = null;
  const flush = () => { if (current && idRe.test(current[0])) matched = current.join('\n').trim(); };
  for (const line of section.split('\n')) {
    if (/^-\s+/.test(line)) {
      flush();
      if (matched) break;
      current = [line];
    } else if (current) {
      current.push(line);
    }
  }
  if (!matched) flush();
  return matched;
}

// t-8ff0: decide what the STATUS panel shows for a ticket. Prefer the id-matched
// ## In Progress bullet (findHandoffStateForTicket, unchanged — multi-ticket
// HANDOFFs). When none names the ticket, fall back to ## Current Focus — but only
// when this ticket is the active sprint (canon is single-active-sprint, so Current
// Focus IS about it) OR Current Focus names the id, so an UNRELATED ticket's focus
// is never shown. Returns { text, source: 'in-progress' | 'current-focus' | null }.
export function handoffDisplayState(raw, ticketId, isActive) {
  const bullet = findHandoffStateForTicket(raw, ticketId);
  if (bullet) return { text: bullet, source: 'in-progress' };
  const focus = raw ? sectionContent(raw, 'Current Focus') : '';
  if (focus) {
    const idRe = new RegExp('\\b' + ticketId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b');
    if (isActive || idRe.test(focus)) return { text: focus, source: 'current-focus' };
  }
  return { text: null, source: null };
}

// t-6ecc: the actionable "## Next Steps" list, shown in the STATUS panel alongside
// Current Focus (Current Focus is context; Next Steps is the action). Same id-scoping
// discipline as handoffDisplayState's Current-Focus fallback — only when this ticket is
// the active sprint OR the section names its id, so an unrelated ticket's steps are
// never shown. Returns the section text, or '' when absent/out-of-scope.
export function handoffNextSteps(raw, ticketId, isActive) {
  const steps = raw ? sectionContent(raw, 'Next Steps') : '';
  if (!steps) return '';
  if (isActive) return steps;
  const idRe = new RegExp('\\b' + ticketId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b');
  return idRe.test(steps) ? steps : '';
}

// Renders this ticket's HANDOFF.md state bullet, if any — a fresh fetch each
// call (not the page-load-cached state.handoff) so it reflects a save the
// live agent just made, not a stale snapshot from when the cockpit opened.
export async function renderCockpitState(t) {
  const box = document.getElementById('ck-state');
  let raw = '';
  const wdHandoff = (cockpitState.worktreeDocs || {}).handoff; // t-1357: worktree HANDOFF wins
  if (wdHandoff != null) {
    raw = wdHandoff;
  } else {
    try {
      const r = await fetch('/api/handoff');
      if (r.ok) raw = (await r.json()).raw || '';
    } catch {}
  }
  const st = handoffDisplayState(raw, t.id, t.status === 'in_progress');

  // t-cd06: the locked worktree is durable (.tickets/<id>/.cockpit-cwd) but
  // previously only surfaced in the WORKTREE accordion above — show it here
  // too, since Status is read independently and HANDOFF.md itself has no
  // idea which directory the session actually runs in.
  let worktreeLine = '';
  const lock = await fetchWorktreeLock(t.id);
  if (lock.locked && lock.cwd) {
    // Short label, not the full absolute path (that forced the rail to be
    // stretched wider just to read it) — the path is still available as a
    // hover tooltip for anyone who wants it.
    // t-f15b: cockpitPathKey compare (see the WORKTREE-panel selection logic
    // below for why a raw === silently fails on Windows).
    let label = lock.cwd;
    try {
      const wtr = await fetch('/api/worktrees');
      if (wtr.ok) {
        const entries = await wtr.json();
        const match = entries.find(e => cockpitPathKey(e.path) === cockpitPathKey(lock.cwd));
        if (match) label = match.is_main ? 'Main checkout (current)' : (match.branch || '(detached)');
      }
    } catch {}
    worktreeLine = `<div class="ck-worktree-sub" style="margin-bottom:8px;" title="${esc(lock.cwd)}">Running in: ${esc(label)}</div>`;
  }

  let stateHtml;
  if (st.source === 'in-progress') {
    stateHtml = formatStateAsParagraphs(st.text, t);
  } else if (st.source === 'current-focus') {
    // t-8ff0: labeled so the project focus is never mistaken for per-ticket state.
    stateHtml = '<div class="ck-state-source">Current focus (no per-ticket state yet):</div>' + formatStateAsParagraphs(st.text, t);
  } else {
    stateHtml = '<div class="ck-add-hint">No saved state yet for this ticket in HANDOFF.md.</div>';
  }
  // t-6ecc: surface the actionable "## Next Steps" alongside Current Focus.
  const nextSteps = handoffNextSteps(raw, t.id, t.status === 'in_progress');
  const nextHtml = nextSteps
    ? '<div class="ck-state-source" style="margin-top:10px;">Next steps:</div>' + formatStateAsParagraphs(nextSteps, t)
    : '';
  box.innerHTML = worktreeLine + stateHtml + nextHtml;
}

// t-1543: this file's load-time code; board-main.js runs it after every module has loaded.
export function initCockpitRail() {
  ['keydown', 'keypress', 'keyup'].forEach(type => document.addEventListener(type, e => {
    if (window.parent === window) return;
    if (type === 'keydown' && boardKeyBlocked(e)) { boardKeys.cancel(); return; }
    boardKeys.handle(e);
  }, true));

  document.getElementById('ck-end-session').addEventListener('click', async () => {
    if (!cockpitState || cockpitState._ending) return;
    if (sessionIsLive()) { openLeaveConfirm(); return; }
    const tab = cockpitState;
    const detached = await findLiveDaemonSession(tab.id);
    if (cockpitState !== tab || tab._ending) return; // switched tabs (or an end began) during the lookup
    // Start sprint may have attached while we were looking: then this is a live tab, and tearing it down
    // (or calling it unattached) would be the original orphan bug again.
    if (sessionIsLive()) { openLeaveConfirm(); return; }
    if (detached) { openDetachedSessionNotice(detached); return; }
    teardownCockpit();
  });
}
