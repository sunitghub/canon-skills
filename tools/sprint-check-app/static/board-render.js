import { COLLAPSE_STATUSES, COLUMNS, COL_LIMIT, SHELL_TAB, docSlug, loadData, state } from './board-core.js';
import { ticketTags, age, ciBadge, demoBadge, divergenceLine, effectiveStatus, esc, escAttr, normalizeSearch, outcomeRatio, ticketMatchesQuery, typeBadge, whyQueryFromInput, worktreePrefLine, worktreeRun } from './board-helpers.js';
import { openModal } from './board-modal.js';
import { tagChipsHTML } from './board-tags.js';
import { moveCard } from './board-docs.js';
import { activeTabId, cockpitState, cockpitTabs, unmountTab } from './board-cockpit.js';
import { openCockpit, renderSidebarChanges } from './board-cockpit-rail.js';
import { cockpitForwardSlash, fetchWorktreeLock } from './board-worktree.js';
import { openCommitPanel } from './board-panels.js';
import { applySearch, setText } from './board-ui.js';
import { bindGithubCardButtons, ensureGithubStatus, ghButtonHTML, ghChipHTML, ghOut } from './board-github.js';

// ── Render ────────────────────────────────────────────────────────────────

export function render() {
  renderHeader();
  renderSidebar();
  renderBoard();
  refreshCockpitSessions();
  ensureGithubStatus();   // t-718b: a card that just went out on GitHub gets its stage now, not at the next poll
}

// t-2d2e: same normalization for the row's "Main checkout" test and the
// same-project test, so both agree on what "this project" means.
export const normProjectPath = p => String(p || '').replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase();
export const COCKPIT_TICKET_ID = /^t-[a-z0-9]{4}$/;
// t-391a: the "Cockpit sessions" panel lists active sessions across ALL projects
// the one daemon serves (nebula's model — one daemon, many projects). Read-only
// fetch of /api/cockpit-sessions (token-free, like /api/cockpit); clicking a row
// opens/attaches that session in the cockpit overlay, where the tokened Kill /
// Save & End live. No token-free kill is added — the board never holds the daemon
// token (t-ddc8). Basename split uses [\\/] so a Windows project path renders too.
// t-824e: a /sessions row's displayed state — the daemon's "state", or for a daemon older
// than t-824e its "status" (needs-you / running). Never the raw wire status ("awaiting-input").
export const CK_STATE_LABEL = { 'needs-you': 'needs you', done: 'done \u00b7 waiting for your next prompt', working: 'working', idle: 'idle', running: 'running' };
export const CK_SIGNAL_LABEL = { hook: 'Claude Code notification hook', 'copilot-menu': 'Copilot approval menu', activity: 'terminal activity only (no question signal)' };
export function ckRowState(row) {
  if (row && typeof row.state === 'string' && CK_STATE_LABEL[row.state]) return row.state;
  return row && row.status === 'needs-you' ? 'needs-you' : 'running';
}
export async function refreshCockpitSessions() {
  const panel = document.getElementById('cockpit-sessions');
  if (!panel) return;
  let sessions = [];
  try {
    const r = await fetch('/api/cockpit-sessions');
    if (r.ok) sessions = await r.json();
  } catch (e) { /* daemon absent → empty panel */ }
  if (!Array.isArray(sessions)) sessions = [];
  applyCardSessions(sessions);
  // t-d34e: inside a Cockpit tab the Agents rail, the card strips (applied above) and Admin already
  // show every session, so the embedded board has no panel. A standalone board keeps the
  // cross-project list (t-391a) — it has no rail.
  if (document.documentElement.classList.contains('canon-proj-embed')) sessions = [];
  if (!Array.isArray(sessions) || sessions.length === 0) {
    panel.hidden = true;
    panel.innerHTML = '';
    return;
  }
  const rows = sessions.map(s => {
    const ticket = String(s.ticket || '');
    const project = String(s.project_root || '');
    const agent = String(s.agent || '');
    const st = ckRowState(s);
    const statusCls = st;
    // t-19d1: where the session actually runs — "Main checkout", or the worktree's folder — not
    // just the project root (a worktree session used to look like it ran in main).
    const cwd = String(s.cwd || '');
    const where = !cwd || normProjectPath(cwd) === normProjectPath(project) ? 'Main checkout' : cwd.split(/[\\/]/).filter(Boolean).pop();
    return `<div class="cockpit-session-row" data-ticket="${escAttr(ticket)}" data-project="${escAttr(project)}" title="${escAttr(cwd || project)}">`
      + `<span class="cs-ticket">${esc(ticket)}</span>`
      + `<span class="cs-project">${esc(project)}</span>`
      + `<span class="cs-where">${esc(where)}</span>`
      + `<span class="cs-agent">${esc(agent)}</span>`
      + `<span class="cs-status ${statusCls}" title="${escAttr(CK_STATE_LABEL[st])}">${esc(st === 'done' ? 'done' : CK_STATE_LABEL[st])}</span>`
      + `</div>`;
  }).join('');
  panel.innerHTML = `<div class="cockpit-sessions-title">Cockpit sessions \u00b7 ${sessions.length}</div>`
    + `<div class="cockpit-sessions-list">${rows}</div>`;
  panel.hidden = false;
  panel.querySelectorAll('.cockpit-session-row').forEach(row => {
    row.addEventListener('click', () => openSessionRow(row.dataset.ticket, row.dataset.project));
  });
}

// t-28ec: this project's live sessions mark their board cards. The board re-renders only
// when a card's state changes; the ages on the strips are refreshed in place every poll.
function applyCardSessions(sessions) {
  const root = normProjectPath(state.gitRoot);
  const rows = new Map();
  for (const s of sessions) {
    const id = String((s && s.ticket) || '');
    if (!root || !COCKPIT_TICKET_ID.test(id) || normProjectPath(s.project_root) !== root) continue;
    rows.set(id, s);
  }
  const key = [...rows].map(([id, r]) => id + ':' + ckRowState(r)).sort().join('|');
  state.cockpitRows = rows;
  if (key !== state.cockpitRowsKey) { state.cockpitRowsKey = key; renderBoard(); return; }
  document.querySelectorAll('#board .card-state[data-id]').forEach(el => {
    const row = rows.get(el.dataset.id);
    if (row) el.innerHTML = cardStateInner(row);
  });
}
function ckDur(secs) {
  secs = Math.max(0, Math.floor(secs));
  if (secs < 60) return secs + 's';
  const m = Math.floor(secs / 60);
  return m < 60 ? m + 'm' : Math.floor(m / 60) + 'h ' + (m % 60) + 'm';
}
function cardStateInner(row) {
  const st = ckRowState(row);
  const num = v => (typeof v === 'number' && isFinite(v) && v >= 0) ? v : null;
  const since = num(row.state_secs), idle = num(row.idle_secs), limit = num(row.idle_limit_secs);
  const reap = st !== 'needs-you' && idle !== null && limit !== null ? ` \u00b7 reaps in ${ckDur(limit - idle)}` : '';
  const label = { 'needs-you': 'Needs you', working: 'Working', idle: 'Idle', done: 'Done', running: 'Running' }[st];
  const age = since !== null && st !== 'working' && st !== 'running' ? (st === 'needs-you' ? ' \u00b7 ' : ' ') + ckDur(since) : '';
  return `<span class="sdot"></span>${esc(label + age + (st === 'idle' || st === 'done' ? reap : ''))}`;
}
function cardStateHTML(t, row) {
  const st = ckRowState(row);
  return `<div class="card-state st-${st}" data-id="${escAttr(t.id)}" title="${escAttr(CK_STATE_LABEL[st] + (CK_SIGNAL_LABEL[row.signal] ? ' \u00b7 state from: ' + CK_SIGNAL_LABEL[row.signal] : ''))}">${cardStateInner(row)}</div>`;
}

// t-2d2e: a row from another project can't open here (the ticket isn't in this
// board's list). Inside the Cockpit shell, hand it to the shell, which switches to
// that project's tab; a standalone board has no shell, so say why nothing opens.
function openSessionRow(ticket, project) {
  if (!project || normProjectPath(project) === normProjectPath(state.gitRoot)) { openCockpit(ticket); return; }
  if (window.parent !== window && COCKPIT_TICKET_ID.test(ticket)) {
    window.parent.postMessage({ source: 'canon-board', type: 'open-session', tab: SHELL_TAB, project_root: project, ticket }, location.origin);
    return;
  }
  showToast(`⚠ ${ticket} belongs to ${project} — open that project's board`, 'warn');
}

export function renderHeader() {
  const { git, tickets } = state;
  // t-6a74: in a Cockpit project tab, show the full folder path instead of the
  // project name (brand text + version are hidden via html.canon-proj-embed).
  const _embed = document.documentElement.classList.contains('canon-proj-embed');
  setText('h-project',  _embed ? (git?.root || git?.project || 'project') : (git?.project || 'project'));
  document.getElementById('h-project').title = git?.root || '';
  state.gitRoot = cockpitForwardSlash(git?.root) || '';
  // t-644a: the board's own established non-git tell — total_commits is only
  // a number when `git rev-list --count HEAD` actually succeeded (the board's
  // git summary); already used above for the commits-total badge. Reused here to
  // gate every worktree-preference surface (modal row, rail accordion, board
  // chip) live, not cached at registration — reappears the moment git init
  // happens and this project's header next re-renders.
  // t-d218: is_git from the server; total_commits is absent in a repo with no commits yet (still git).
  state.isGitProject = git?.is_git === true || typeof git?.total_commits === 'number';
  document.documentElement.classList.toggle('no-git', !state.isGitProject);   // t-5a4b
  setText('h-branch',   git?.branch  || '—');
  setText('s-branch',   git?.branch  || '—');
  const mod = document.getElementById('s-modified');
  if ((git?.modified ?? 0) > 0) { mod.textContent = `${git.modified} modified`; mod.style.display=''; }
  else mod.style.display = 'none';
}

export function renderSidebar() {
  const { handoff, git, tickets } = state;

  // Now Working On
  const wip    = tickets.filter(t => effectiveStatus(t) === 'in_progress');
  const wipEl  = document.getElementById('s-wip');
  const wipItems = document.getElementById('s-wip-items');
  if (wip.length) {
    wipEl.classList.add('has-items');
    wipItems.innerHTML = wip.map(t =>
      `<div class="wip-item" data-id="${esc(t.id)}" role="button" tabindex="0" title="Open ticket">` +
        `<span class="wip-id">${esc(t.id)}</span>` +
        `<span class="wip-title">${esc(t.title)}</span>` +
        `<button class="wip-copy git-only" data-copy="${esc(t.id)}: " title="Copy commit prefix — paste into your git commit message">copy</button>` +
      `</div>`
    ).join('');
    wipItems.querySelectorAll('.wip-item').forEach(row => {
      row.addEventListener('click', e => {
        if (e.target.classList.contains('wip-copy')) return;
        openModal(row.dataset.id);
      });
      row.addEventListener('keydown', e => {
        if (e.key === 'Enter') row.click();
      });
    });
    wipItems.querySelectorAll('.wip-copy').forEach(btn => {
      btn.addEventListener('click', e => {
        e.stopPropagation();
        navigator.clipboard.writeText(btn.dataset.copy).then(() => {
          btn.textContent = 'done'; btn.classList.add('copied');
          setTimeout(() => { btn.textContent = 'copy'; btn.classList.remove('copied'); }, 1500);
        });
      });
    });
  } else {
    wipEl.classList.remove('has-items');
  }

  setText('s-focus', handoff?.focus || 'No HANDOFF.md Current Focus found.');
  document.getElementById('s-focus').title = handoff?.focus || '';

  const commitsTotalEl = document.getElementById('s-commits-total');
  if (typeof git?.total_commits === 'number') { commitsTotalEl.textContent = git.total_commits; commitsTotalEl.style.display = ''; }
  else commitsTotalEl.style.display = 'none';

  const commitsEl = document.getElementById('s-commits');
  commitsEl.innerHTML = (git?.log ?? []).slice(0,5).map(c =>
    `<div class="commit-item" data-hash="${esc(c.hash)}">` +
      `<span class="commit-hash">${esc(c.hash.slice(0,7))}</span>` +
      `<span class="commit-msg">${esc(c.message)}</span>` +
    `</div>`
  ).join('') || '<span style="color:var(--text-dim);font-size:12px">No commits</span>';

  commitsEl.querySelectorAll('.commit-item').forEach(el => {
    el.addEventListener('click', () => openCommitPanel(el.dataset.hash));
  });
  renderSidebarChanges();   // t-5a4b: only for a project without git

  const STATUS_ICONS = {
    open:        `<svg class="summary-icon" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><circle cx="8" cy="8" r="6"/><path d="M8 5v3.5l2 1.5"/></svg>`,
    in_progress: `<svg class="summary-icon" viewBox="0 0 16 16" fill="currentColor"><path d="M6 4.5l6 3.5-6 3.5V4.5z"/><rect x="3" y="4" width="1.5" height="8" rx=".5"/></svg>`,
    closed:      `<svg class="summary-icon" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8" r="6"/><path d="M5.5 8.5l2 2 3-4"/></svg>`,
    cancelled:   `<svg class="summary-icon" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><circle cx="8" cy="8" r="6"/><path d="M5.5 5.5l5 5M10.5 5.5l-5 5"/></svg>`,
  };
  // Donut chart: ticket types breakdown
  const TYPE_COLORS = { bug: '#ef4444', feature: '#3b82f6', task: '#22c55e', chore: '#a78bfa', epic: '#f59e0b' };
  const typeCounts = {};
  tickets.forEach(t => { const ty = t.type || 'task'; typeCounts[ty] = (typeCounts[ty] || 0) + 1; });
  const total = tickets.length;
  const R = 24, C = 2 * Math.PI * R;
  let offset = 0;
  const segments = Object.entries(typeCounts).map(([type, count]) => {
    const pct = total ? count / total : 0;
    const dash = pct * C;
    const seg = `<circle cx="32" cy="32" r="${R}" fill="none" stroke="${TYPE_COLORS[type] || '#64748b'}" stroke-width="8" stroke-dasharray="${dash} ${C - dash}" stroke-dashoffset="${-offset}" transform="rotate(-90 32 32)"/>`;
    offset += dash;
    return seg;
  });
  const emptyRing = total === 0 ? `<circle cx="32" cy="32" r="${R}" fill="none" stroke="var(--border)" stroke-width="8"/>` : '';
  const legend = Object.entries(typeCounts).map(([type, count]) =>
    `<div class="sidebar-donut-legend-item"><span class="sidebar-donut-legend-dot" style="background:${TYPE_COLORS[type] || '#64748b'}"></span><strong>${count}</strong><span>${esc(type)} ${outcomeRatio(type, tickets)}</span></div>`
  ).join('');
  const donutHtml = `<div class="sidebar-donut">
    <svg viewBox="0 0 64 64">${emptyRing}${segments.join('')}<text class="sidebar-donut-center" x="32" y="32" text-anchor="middle" dominant-baseline="central">${total}</text></svg>
    <div class="sidebar-donut-legend">${legend || '<span style="color:var(--text-dim)">No tickets</span>'}</div>
  </div>`;

  document.getElementById('s-summary').innerHTML = donutHtml + '<div class="sidebar-summary">' + COLUMNS.map(col => {
    const count = tickets.filter(t => effectiveStatus(t) === col.status).length;
    const iconColor = col.status === 'in_progress' ? 'var(--col-progress)'
                    : col.status === 'closed'      ? 'var(--col-done)'
                    : col.status === 'cancelled'   ? 'var(--col-discarded)'
                    : `var(--col-${col.status})`;
    return `<div class="summary-item" style="color:${iconColor}">
      ${STATUS_ICONS[col.status] || ''}
      <span style="color:var(--text-muted)">${count} ${esc(col.label.toLowerCase())}</span>
    </div>`;
  }).join('') + '</div>';
}

function renderWhyResults() {
  const el = document.getElementById('why-results');
  if (!el) return;
  const q = whyQueryFromInput(state.query);
  const visible = state.queryMode === 'why' && Boolean(q);
  el.classList.toggle('visible', visible);
  if (!visible) {
    el.innerHTML = '';
    return;
  }

  const why = state.why;
  const file = esc(q);
  if (why?.loading) {
    el.innerHTML =
      `<div class="why-results-head"><div class="why-title">Code archaeology: ${file}</div>` +
      `<div class="why-subtitle">loading</div></div>`;
    return;
  }
  if (why?.error) {
    el.innerHTML =
      `<div class="why-results-head"><div class="why-title">Code archaeology: ${file}</div></div>` +
      `<div class="why-result-empty">${esc(why.error)}</div>`;
    return;
  }

  const results = why?.file === q ? (why.results || []) : [];
  const more = why?.file === q ? (why.more || 0) : 0;
  const message = why?.file === q ? why.message : '';
  const fileGone = why?.file === q && why.file_exists === false && results.length > 0;
  const resolvedPath = why?.file === q ? why.resolved_path : null;
  const alternatives = why?.file === q ? (why.alternatives || []) : [];
  el.innerHTML =
    `<div class="why-results-head">` +
      `<div class="why-title">Code archaeology: ${file}</div>` +
      `<div class="why-subtitle">${results.length ? `${results.length} ticket${results.length === 1 ? '' : 's'}` : 'why mode'}</div>` +
    `</div>` +
    (resolvedPath ? `<div class="why-resolved-path">→ ${esc(resolvedPath)}</div>` : '') +
    (fileGone ? `<div class="why-file-gone">⚠ This file no longer exists in the current tree — showing historical results</div>` : '') +
    (alternatives.length ? `<div class="why-alternatives">Also in: ${alternatives.map(a => `<a class="why-alt-link" data-path="${esc(a)}">${esc(a)}</a>`).join(', ')}</div>` : '') +
    (results.length
      ? `<div class="why-result-list">` + results.map(r =>
          `<button class="why-result" type="button" data-id="${esc(r.id)}">` +
            `<div class="why-result-main">` +
              `<span class="why-result-id">${esc(r.id)}</span>` +
              `<span class="why-result-status">${esc(r.status)}</span>` +
              `<span>${esc(r.title)}</span>` +
            `</div>` +
            (r.decision ? `<div class="why-result-decision">→ ${esc(r.decision)}</div>` : '') +
          `</button>`
        ).join('') + `</div>` +
        (more > 0 ? `<div class="why-result-more">+${more} more, older</div>` : '')
      : `<div class="why-result-empty">${esc(message || 'No tickets found for this file.')}</div>`);
  el.querySelectorAll('.why-result').forEach(btn => {
    btn.addEventListener('click', () => openModal(btn.dataset.id));
  });
  el.querySelectorAll('.why-alt-link').forEach(link => {
    link.addEventListener('click', () => applySearch(link.dataset.path));
  });
}

export function renderBoard() {
  const board = document.getElementById('board');
  const query = state.queryMode === 'search' ? normalizeSearch(state.query) : '';
  const tickets = state.tickets.filter(ticketMatchesQuery);
  const countEl = document.getElementById('board-search-count');
  const emptyEl = document.getElementById('board-empty-search');
  renderWhyResults();
  if (countEl) {
    countEl.textContent = query ? `${tickets.length} of ${state.tickets.length}` : '';
  }
  if (emptyEl) {
    emptyEl.classList.toggle('visible', Boolean(query) && tickets.length === 0);
    emptyEl.textContent = `No tickets match “${state.query}”.`;
  }
  // The 8 s poll re-renders every column; a fresh .column-body starts at 0, so keep each scroll offset (t-dba9).
  const savedScroll = {};
  board.querySelectorAll('.column-body').forEach(b => { savedScroll[b.dataset.status] = b.scrollTop; });
  board.innerHTML = COLUMNS.map(col => {
    const waiting = t => { const r = state.cockpitRows.get(t.id); return !!r && ckRowState(r) === 'needs-you'; };
    const cards = tickets
      .filter(t => effectiveStatus(t) === col.status)
      .sort((a, b) => (col.status === 'in_progress' ? waiting(b) - waiting(a) : 0) || (b.created || '').localeCompare(a.created || ''));
    const needsHere = col.status === 'in_progress' ? cards.filter(waiting).length : 0;
    const limited = COLLAPSE_STATUSES.has(col.status) && !state.expandedCols.has(col.status);
    const visible = limited ? cards.slice(0, COL_LIMIT) : cards;
    const hidden  = cards.length - visible.length;
    return `
      <div class="column ${esc(col.cls)}">
        <div class="column-header">
          <div class="column-title"><div class="col-indicator"></div>${esc(col.label)}</div>
          ${needsHere ? `<span class="column-needs">${needsHere} needs you</span>` : ''}
          <span class="column-header-end">
            ${cards.length > 0 ? `<span class="column-count">${cards.length}</span>` : ''}
            ${col.status === 'open' ? `<button class="column-add" type="button" aria-label="New ticket" title="New ticket">+</button>` : ''}
          </span>
        </div>
        <div class="column-body" data-status="${esc(col.status)}">
          ${visible.length
            ? visible.map((t, i) => cardHTML(t, state.boardFirstRender ? i : undefined)).join('')
            : '<div class="column-empty">empty</div>'}
          ${hidden > 0
            ? `<button class="col-show-more" data-status="${esc(col.status)}">${hidden} older</button>`
            : ''}
          ${state.expandedCols.has(col.status) && cards.length > COL_LIMIT
            ? `<button class="col-show-more col-show-less" data-status="${esc(col.status)}">Show less ↑</button>`
            : ''}
        </div>
      </div>`;
  }).join('');

  state.boardFirstRender = false;
  board.querySelectorAll('.column-body').forEach(b => { b.scrollTop = savedScroll[b.dataset.status] || 0; });

  board.querySelectorAll('.column-add').forEach(btn => btn.addEventListener('click', () => document.getElementById('btn-create').click()));

  board.querySelectorAll('.col-show-more').forEach(btn => {
    btn.addEventListener('click', () => {
      const s = btn.dataset.status;
      if (state.expandedCols.has(s)) state.expandedCols.delete(s);
      else state.expandedCols.add(s);
      renderBoard();
    });
  });

  let dragId = null;

  // Shared hover/focus tooltip — custom-styled (native `title` is slow to appear and gives no
  // visual hint that hovering does anything), shown as long as the element is hovered/focused
  // (not a forced auto-dismiss timer). Any element wires in via showHoverTooltip(el, text).
  let _hoverTooltip = document.getElementById('hover-tooltip');
  if (!_hoverTooltip) {
    _hoverTooltip = document.createElement('div');
    _hoverTooltip.id = 'hover-tooltip';
    _hoverTooltip.className = 'hover-tooltip';
    document.body.appendChild(_hoverTooltip);
  }
  function showHoverTooltip(el, text) {
    const r = el.getBoundingClientRect();
    _hoverTooltip.textContent = text;
    _hoverTooltip.classList.add('visible');
    requestAnimationFrame(() => {
      _hoverTooltip.style.left = `${r.left + r.width / 2}px`;
      _hoverTooltip.style.top = `${r.top - 8}px`;
    });
  }
  function hideHoverTooltip() { _hoverTooltip.classList.remove('visible'); }

  // Generic [data-tooltip] wiring — any element with this attribute gets the shared tooltip,
  // no per-element event boilerplate needed (used by .outcome-dot in the sidebar legend, hence
  // `document.querySelectorAll` rather than `board.querySelectorAll` — renderSidebar() already
  // ran by this point in render()'s call order, so its DOM is present; ci-run-btn wires
  // explicitly below since it also needs the tooltip hidden on click).
  document.querySelectorAll('[data-tooltip]').forEach(el => {
    el.addEventListener('mouseenter', () => showHoverTooltip(el, el.dataset.tooltip));
    el.addEventListener('mouseleave', hideHoverTooltip);
    el.addEventListener('focus', () => showHoverTooltip(el, el.dataset.tooltip));
    el.addEventListener('blur', hideHoverTooltip);
  });

  board.querySelectorAll('.card-archive').forEach(btn => {
    btn.addEventListener('click', e => {
      e.stopPropagation();
      const t = findTicketById(btn.dataset.id);
      if (t) showConfirmToast('Archive ticket ' + esc(t.id) + '. Click to confirm!', () => moveCard(t, 'archived'));
    });
  });

  board.querySelectorAll('.ci-run-btn').forEach(btn => {
    btn.addEventListener('click', e => {
      e.stopPropagation();
      hideHoverTooltip();
      openModal(btn.dataset.id);
    });
    btn.addEventListener('mouseenter', () => showHoverTooltip(btn, 'Run headless grading'));
    btn.addEventListener('mouseleave', hideHoverTooltip);
    btn.addEventListener('focus', () => showHoverTooltip(btn, 'Run headless grading'));
    btn.addEventListener('blur', hideHoverTooltip);
  });

  bindGithubCardButtons(board);   // t-718b: Issue ↗ / PR ↗ / Create PR / Import results / Check & merge, and take back
  board.querySelectorAll('.card-start:not(.card-gh-btn)').forEach(btn => {
    btn.addEventListener('click', e => {
      e.stopPropagation();
      if (btn.disabled) return;
      openCockpit(btn.dataset.id);
    });
  });

  // t-9d93: the hover menu (Copy ID, Copy folder path, Open) replaces the hover COPY button.
  let cardMenu = document.getElementById('card-menu');
  if (!cardMenu) {
    cardMenu = document.createElement('div');
    cardMenu.id = 'card-menu';
    cardMenu.className = 'card-menu';
    cardMenu.setAttribute('role', 'menu');
    cardMenu.innerHTML = '<button type="button" role="menuitem" data-act="id">Copy ID</button><button type="button" role="menuitem" data-act="path">Copy folder path</button><button type="button" role="menuitem" data-act="open">Open</button>';
    document.body.appendChild(cardMenu);
    const closeMenu = (refocus) => {
      if (!cardMenu.classList.contains('open')) return;
      cardMenu.classList.remove('open');
      const owner = document.querySelector('.card-menu-btn[aria-expanded="true"]');
      if (owner) { owner.setAttribute('aria-expanded', 'false'); if (refocus) owner.focus(); }
    };
    cardMenu._close = closeMenu;
    document.addEventListener('pointerdown', e => { if (!e.target.closest('#card-menu, .card-menu-btn')) closeMenu(false); });
    document.addEventListener('keydown', e => { if (e.key === 'Escape' && cardMenu.classList.contains('open')) { e.stopPropagation(); closeMenu(true); } }, true);
    // A scroll closes the menu only once it has moved the menu's button. Chrome focuses a clicked button and scrolls a clipped one into
    // view, and that scroll's event arrives just after the click opened the menu (t-8627).
    window.addEventListener('scroll', () => {
      const owner = document.querySelector('.card-menu-btn[aria-expanded="true"]');
      if (owner && owner.getBoundingClientRect().top === cardMenu._ownerTop) return;
      closeMenu(false);
    }, true);
    // Tab-ing past the last item closes the menu. WebKit does not focus a clicked button, so a click inside the menu
    // reports a focusout with no relatedTarget: ignore it while the pointer is down in the menu.
    let menuPointer = false;
    cardMenu.addEventListener('pointerdown', () => { menuPointer = true; setTimeout(() => { menuPointer = false; }, 300); });
    cardMenu.addEventListener('focusout', e => {
      if (menuPointer) return;
      if (!e.relatedTarget || !e.relatedTarget.closest('#card-menu, .card-menu-btn')) closeMenu(false);
    });
    cardMenu.addEventListener('keydown', e => {
      if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
      const items = [...cardMenu.querySelectorAll('button')], i = items.indexOf(document.activeElement);
      items[(i + (e.key === 'ArrowDown' ? 1 : items.length - 1)) % items.length].focus();
      e.preventDefault();
    });
    cardMenu.addEventListener('click', e => {
      const item = e.target.closest('button[data-act]');
      if (!item) return;
      const id = cardMenu.dataset.id, act = item.dataset.act;
      const root = (state.gitRoot || '').replace(/\/+$/, '');
      if (act === 'open') { closeMenu(false); openModal(id); return; }
      const text = act === 'id' ? id : (root ? root + '/' : '') + '.tickets/' + id;
      navigator.clipboard.writeText(text).then(() => {
        item.textContent = 'Copied';
        setTimeout(() => closeMenu(true), 600);
      }).catch(() => closeMenu(true));
    });
  }
  board.querySelectorAll('.card-menu-btn').forEach(btn => {
    btn.addEventListener('click', e => {
      e.stopPropagation();
      if (btn.getAttribute('aria-expanded') === 'true') { cardMenu._close(true); return; }
      cardMenu._close(false);
      cardMenu.querySelector('[data-act="id"]').textContent = 'Copy ID';
      cardMenu.querySelector('[data-act="path"]').textContent = 'Copy folder path';
      cardMenu.dataset.id = btn.dataset.id;
      const r = btn.getBoundingClientRect();
      cardMenu._ownerTop = r.top;
      cardMenu.classList.add('open');
      cardMenu.style.left = Math.max(8, Math.min(r.left, innerWidth - cardMenu.offsetWidth - 8)) + 'px';
      cardMenu.style.top = Math.min(r.bottom + 4, innerHeight - cardMenu.offsetHeight - 8) + 'px';
      btn.setAttribute('aria-expanded', 'true');
      cardMenu.querySelector('button').focus();
    });
  });

  let cardPointerOpen = false;

  function openCard(el) {
    if (!el || cardPointerOpen) return;
    cardPointerOpen = true;
    const id = cardTicketId(el);
    openModal(id);
    setTimeout(() => { cardPointerOpen = false; }, 0);
  }

  board.querySelectorAll('.card').forEach(el => {
    el.addEventListener('pointerup', e => {
      if (e.button !== 0) return;
      if (e.target.closest('.card-archive, button, a, input, textarea, select, label')) return;
      if (el.classList.contains('dragging')) return;
      openCard(el);
    });

    el.addEventListener('click', e => {
      if (e.target.closest('.card-archive, button, a, input, textarea, select, label')) return;
      if (cardPointerOpen) return;
      const id = cardTicketId(el);
      openModal(id);
    });

    el.addEventListener('keydown', e => {
      if (e.key !== 'Enter' && e.key !== ' ') return;
      if (e.target !== el) return;
      e.preventDefault();
      const id = cardTicketId(el);
      openModal(id);
    });

    el.addEventListener('dragstart', e => {
      const id = cardTicketId(el);
      dragId = id;
      e.dataTransfer.setData('text/plain', dragId); // required by Safari to activate drag
      e.dataTransfer.effectAllowed = 'move';
      requestAnimationFrame(() => el.classList.add('dragging'));
    });
    el.addEventListener('dragend', () => {
      el.classList.remove('dragging');
      dragId = null;
    });
  });

  board.querySelectorAll('.column-body').forEach(col => {
    col.addEventListener('dragover', e => {
      e.preventDefault();
      e.dataTransfer.dropEffect = 'move';
      col.classList.add('drag-over');
    });
    col.addEventListener('dragleave', e => {
      if (!col.contains(e.relatedTarget)) col.classList.remove('drag-over');
    });
    col.addEventListener('drop', e => {
      e.preventDefault();
      col.classList.remove('drag-over');
      if (!dragId) return;
      const newStatus = col.dataset.status;
      const t = findTicketById(dragId);
      if (!t || t.status === newStatus) return;
      const { hasAcceptance } = readiness(t);
      if (newStatus === 'closed' && t.acceptance_unchecked) {
        showToast('⚠ Acceptance has unchecked items — mark all complete before closing', 'block');
        return;
      }
      if (newStatus === 'in_progress' && !hasAcceptance) {
        showToast('⚠ No acceptance criteria defined yet', 'warn');
      }
      moveCard(t, newStatus);
    });
  });

  renderCardWorktreeChips();
}

// t-44b0: the chip's label for a ticket locked to `cwd`. Paths are compared by the same fold the servers use
// (`pathKey`/`_path_key`: \ -> /, trailing / dropped, lowercased) because on Windows `git worktree list`
// prints C:/... while the daemon writes the native C:\... into .cockpit-cwd. A lock that matches no entry
// shows its folder name, never 'main' (that would read as a main-checkout ticket).
export function worktreeChipLabel(entries, cwd) {
  const key = p => String(p || '').replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase();
  const folder = p => String(p || '').replace(/[\\/]+$/, '').split(/[\\/]/).pop();
  const match = Array.isArray(entries) ? entries.find(e => e && key(e.path) && key(e.path) === key(cwd)) : null;
  if (match && match.is_main) return 'main';
  return (match && match.branch) || folder(cwd);
}

// t-644a: read-only worktree chip on each IN PROGRESS card, sourced from
// /api/worktree-lock/<id> (.cockpit-cwd) + /api/worktrees (branch names).
// Gated on state.isGitProject, same live /api/git check every other worktree
// surface uses — a non-git project never fetches, so the chip stays empty
// (and invisible, see .card-wt-chip:not(:empty) above).
async function renderCardWorktreeChips() {
  if (!state.isGitProject) return;
  const chips = Array.from(document.querySelectorAll('.card-wt-chip[data-id]'));
  if (!chips.length) return;
  let entries = [];
  try {
    const r = await fetch('/api/worktrees');
    if (r.ok) entries = await r.json();
  } catch {}
  await Promise.all(chips.map(async chip => {
    const id = chip.dataset.id;
    const lock = await fetchWorktreeLock(id);
    if (!lock.locked || !lock.cwd) return;
    const label = worktreeChipLabel(entries, lock.cwd);
    if (!document.body.contains(chip)) return; // board may have re-rendered mid-fetch
    chip.textContent = label;
    chip.title = 'Worktree: ' + label;
  }));
}

let _toastTimer = null;
let _pendingConfirm = null;
// t-1940: every board write goes through here, so a refused or failed save is
// never mistaken for a saved one. A non-2xx status, a JSON `ok: false`, or a
// network error is a failure: the reason is toasted, and the caller keeps or
// reverts its own UI. (403 from the origin guard answers HTML, hence the
// tolerant JSON parse.)
export async function postWrite(url, body, what, opts = {}) {
  let r, d = {};
  try {
    r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    d = await r.json().catch(() => ({}));
  } catch (err) {
    showToast(`⚠ Couldn't ${what}: the board server didn't answer`, 'block');
    return { ok: false, error: String(err) };
  }
  if (!r.ok || (d && d.ok === false)) {
    const why = (d && d.error) || `HTTP ${r.status}`;
    const stale = !!(d && d.code === 'stale');   // t-26f9: the doc changed since the page read it
    if (!(stale && opts.quietStale)) showToast(`⚠ Couldn't ${what}: ${why}`, 'block');
    return { ok: false, error: why, stale };
  }
  return { ok: true, data: d };
}

// t-26f9: a doc write echoes the etag its page read (sha256 of the file's bytes, or "absent") as base_hash, so it can
// never silently replace a change made since; a bound ticket's docs are written in its worktree.
export async function fetchDoc(file) {
  try {
    const r = await fetch(`/api/doc/${encodeURIComponent(file)}`);
    if (!r.ok) return null;
    const d = await r.json();
    return { content: d.content || '', etag: d.etag || '' };
  } catch { return null; }
}
// Read-modify-write: when the file changed under us, re-read and re-apply once; a second collision is reported.
export async function updateDoc(file, transform, what) {
  for (let attempt = 0; attempt < 2; attempt++) {
    const cur = await fetchDoc(file);
    if (!cur) { showToast(`⚠ Couldn't ${what}: the doc couldn't be read`, 'block'); return { ok: false }; }
    let next;
    try { next = transform(cur.content, attempt); }
    catch (e) { showToast(`⚠ Couldn't ${what}: ${e.message}`, 'block'); return { ok: false }; }
    const res = await postWrite(`/api/doc/${encodeURIComponent(file)}`, { content: next, base_hash: cur.etag }, what, { quietStale: attempt === 0 });
    if (!res.stale) return res;
  }
  return { ok: false, stale: true };
}

export function showToast(msg, type = 'warn') {
  const el = document.getElementById('drop-toast');
  if (!el) return;
  clearTimeout(_toastTimer);
  _pendingConfirm = null;
  el.textContent = msg;
  el.className = type + ' show';
  _toastTimer = setTimeout(() => { el.classList.remove('show'); }, 3000);
}
function showConfirmToast(msg, onConfirm) {
  const el = document.getElementById('drop-toast');
  if (!el) return;
  clearTimeout(_toastTimer);
  _pendingConfirm = onConfirm;
  el.innerHTML = msg + '<button class="toast-confirm">Confirm</button>';
  el.className = 'confirm show';
  _toastTimer = setTimeout(() => { el.classList.remove('show'); _pendingConfirm = null; }, 4000);
}

// Small inline icons shared by board surfaces (t-7723); strokes take the surrounding text color.
const ICO = {
  clock: '<svg viewBox="0 0 12 12" aria-hidden="true"><circle cx="6" cy="6" r="5"/><path d="M6 3v3l2 1.2"/></svg>',
};
function ico(name) { return ICO[name] || ''; }

export function readiness(t) {
  const slugs = (t.docs || []).map(d => docSlug(t, d.file));
  const hasAcceptance = slugs.includes('acceptance');
  const hasPlan = slugs.includes('plan');
  // acceptance_has_items: true=complete, false=exists but missing criteria/test items, null=unknown
  const acceptanceIncomplete = hasAcceptance && t.acceptance_has_items === false;
  // acceptance_unchecked: true if any box anywhere in acceptance.md (including ## QA) is unchecked
  const acceptanceUnchecked = hasAcceptance && t.acceptance_unchecked === true;
  const planIncomplete = hasPlan && t.plan_has_approach === false;
  const planApproved = hasPlan && t.plan_approved === true;
  const ready = hasAcceptance && hasPlan && !acceptanceIncomplete && !acceptanceUnchecked && !planIncomplete && planApproved;
  const label = !hasAcceptance ? 'needs acc'
    : acceptanceIncomplete ? 'incomplete'
    : acceptanceUnchecked ? 'unchecked items'
    : !hasPlan ? 'needs plan'
    : planIncomplete ? 'plan incomplete'
    : !planApproved ? 'needs signoff'
    : 'ready';
  return { ready, hasAcceptance, hasPlan, acceptanceIncomplete, acceptanceUnchecked, planIncomplete, planApproved, label };
}

function cardHTML(t, idx) {
  const { ready, label, acceptanceIncomplete, acceptanceUnchecked, planIncomplete } = readiness(t);
  const animClass = (idx !== undefined) ? ' animate-in' : '';
  const animStyle = (idx !== undefined) ? ` style="--i:${idx}"` : '';
  const pri = t.priority ?? 2;
  const priLabel = ['P0 critical','P1 high','P2 normal','P3 low','P4 backlog'][pri] ?? `P${pri}`;
  // Cockpit Start/Resume: t-644a removed the old repo-wide pre-block here —
  // cmd_start's real gate (t-01a4) is per-worktree now, so a ticket anywhere
  // else being in_progress no longer means THIS one can't start; only the
  // daemon/CLI's own actual same-worktree conflict does, surfaced as a real
  // error from the Start attempt itself (see cockpit.html's own start()
  // error handling) rather than guessed at ahead of time from a global count
  // the board has no way to evaluate per-worktree without asking the daemon.
  let startBtn = '';
  const run = worktreeRun(t);
  const live = state.cockpitRows.get(t.id);
  if (live) {   // a live local session keeps its Answer/Open button, even on a ticket also out on GitHub
    startBtn = ckRowState(live) === 'needs-you'
      ? `<button class="card-start answer" data-id="${esc(t.id)}" title="Answer — this session is waiting on you">Answer ▸</button>`
      : `<button class="card-start open" data-id="${esc(t.id)}" title="Open this ticket's live session">Open ▸</button>`;
  } else if (ghOut(t)) {
    startBtn = ghButtonHTML(t);   // t-718b: out on GitHub — one stage button instead of Start (one place at a time)
  } else if (run) {
    startBtn = `<button class="card-start resume" data-id="${esc(t.id)}" title="Resume this sprint — it's in progress in worktree ${escAttr(run.branch)}">▶ Resume</button>`;
  } else if (t.status === 'open') {
    startBtn = `<button class="card-start" data-id="${esc(t.id)}" title="Start this sprint in the cockpit">▶ Start</button>`;
  } else if (t.status === 'in_progress') {
    startBtn = `<button class="card-start resume" data-id="${esc(t.id)}" title="Resume this sprint in the cockpit">▶ Resume</button>`;
  }
  return `
    <div class="card${live && ckRowState(live) === 'needs-you' ? ' s-need' : ''}${animClass}" data-id="${esc(t.id)}" data-priority="${pri}" draggable="true" tabindex="0"${animStyle}>
      ${live ? cardStateHTML(t, live) : ''}
      <div class="card-head">
        <span class="card-id">${esc(t.id)}</span>
        <button class="card-menu-btn" type="button" data-id="${esc(t.id)}" aria-haspopup="menu" aria-expanded="false" aria-label="Card menu for ${esc(t.id)}" title="Copy ID, copy folder path, open">⋯</button>
        ${typeBadge(t.type)}
        ${ciBadge(t)}
        ${demoBadge(t)}
        ${String(t.ci) === 'true' ? `<button class="ci-run-btn b-accent${t.headless_running ? ' running' : ''}" data-id="${esc(t.id)}" aria-label="Run headless grading"><svg viewBox="0 0 16 16" width="12" height="12" fill="currentColor"><path d="M4 2.5v11l9-5.5z"/></svg></button>` : ''}
      </div>
      <div class="card-body">
        ${t.status === 'closed' ? `<button class="card-archive" data-id="${esc(t.id)}" title="Archive this ticket">archive</button>` : ''}
        <p class="card-title">${esc(t.title)}</p>
        ${ticketTags(t).length ? `<div class="card-tags">${tagChipsHTML(ticketTags(t), 3)}</div>` : ''}
        ${t.status === 'in_progress' ? `<span class="card-wt-chip" data-id="${esc(t.id)}"></span>` : ''}
        ${ghChipHTML(t)}
        ${run ? `<div class="card-wt-pref card-wt-run" title="In progress in worktree ${escAttr(run.branch)} (this checkout's copy still says open until the branch merges).">Worktree: ${esc(run.branch)}</div>` : `${worktreePrefLine(t)}
        ${divergenceLine(t)}`}
      </div>
      <div class="card-footer">
        <span class="card-age" title="Created ${escAttr(age(t.created))}">${ico('clock')}${esc(age(t.created))}</span>
        <span class="card-pri" title="${escAttr(priLabel)}"><span class="pri-bars ${pri <= 1 ? 'p-hi' : pri === 2 ? 'p-mid' : 'p-lo'}" aria-hidden="true"><i></i><i></i><i></i></span>P${esc(pri)}</span>
        <span class="ready-indicator ${ready ? 'ready' : (acceptanceIncomplete || acceptanceUnchecked || planIncomplete) ? 'incomplete' : 'not-ready'}" data-id="${esc(t.id)}">
          ${ready
            ? `<span class="ready-dot"></span><span class="ready-label">ready</span>`
            : `<span class="ready-flag" aria-label="${esc(label)} — open the ticket for details">${esc(label)}</span>`}
        </span>
        ${startBtn}
      </div>
    </div>`;
}

function cardTicketId(el) {
  const attr = el?.getAttribute('data-id') || el?.dataset?.id || '';
  if (attr) return attr;
  const label = el?.querySelector('.card-id')?.textContent?.trim() || '';
  return label.replace(/^"|"$/g, '');
}

function normalizeTicketId(id) {
  return String(id ?? '').trim().replace(/^"+|"+$/g, '');
}

export function findTicketById(id) {
  const want = normalizeTicketId(id);
  return state.tickets.find(t => normalizeTicketId(t.id) === want) || state.scratch.get(want);
}

// t-47f1: a scratch session is the plain agent in the project's main checkout, with no
// ticket behind it. The cockpit treats it as a pseudo-ticket (id s-xxxx, minted by the
// shell) so tabs, the terminal and End reuse the ticket paths; the rail shows only a label.
export const SCRATCH_ID = /^s-[a-z0-9]{4}$/;
// t-f553: messages to the active tab's daemon page (which holds the session token).
export function startPromote(thenEnd) {
  cockpitState.promoteThenEnd = !!thenEnd;
  if (!postToTab(cockpitState, { type: 'promote-request', thenEnd: !!thenEnd })) { showToast('⚠ Start the agent first', 'warn'); return; }
  showToast('Asked the agent to create the ticket — approve its tkt create command in the terminal.');
}
// Click the scratch title to rename it (Enter saves, Esc cancels); the daemon keeps it so the
// Agents rail, Admin and notifications show it too.
export function editScratchTitle() {
  const t = findTicketById(activeTabId);
  if (!t || !t.scratch) return;
  const el = document.getElementById('ck-tc-title');
  if (el.querySelector('input')) return;
  const input = document.createElement('input');
  input.className = 'ck-title-input';
  input.maxLength = 80;
  input.value = t.title === 'Scratch session' ? '' : t.title;
  input.placeholder = 'Name this scratch session';
  el.textContent = '';
  el.appendChild(input);
  input.focus();
  let done = false;
  const finish = (save) => {
    if (done) return; done = true;
    if (save) {
      const v = input.value.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 80);
      t.title = v || 'Scratch session';
      announceScratchTabs();
      postToTab(cockpitState, { type: 'set-title', title: v });
    }
    document.getElementById('ck-tc-title').textContent = t.title;
    document.getElementById('ck-title').textContent = t.title;
    document.getElementById('ck-title').title = t.title || '';   // t-b91f: the full title when the bar truncates it
  };
  // Esc/Enter belong to this field — not the board's own Escape (which closes the cockpit).
  input.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); finish(true); }
    else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finish(false); }
  });
  input.addEventListener('blur', () => finish(true));
}
export function postToTab(tab, msg) {
  if (!tab || !tab.iframeEl || !tab.iframeEl.contentWindow || !tab.addr) return false;
  tab.iframeEl.contentWindow.postMessage(Object.assign({ source: 'canon-cockpit' }, msg), 'http://' + tab.addr);
  return true;
}
// The agent reported the ticket it created: offer to continue this conversation as it.
export function showPromotedChoice(ticket) {
  const box = document.getElementById('ck-scratch-promoted');
  box.hidden = false;
  box.textContent = '';
  const p = document.createElement('div');
  p.textContent = ticket + ' created. Continue this conversation as that ticket? The scratch session ends and the ticket\u2019s cockpit resumes it.';
  const row = document.createElement('div');
  row.className = 'ck-scratch-actions';
  const yes = document.createElement('button');
  yes.className = 'ck-scratch-btn'; yes.type = 'button'; yes.textContent = 'Continue as ' + ticket;
  yes.addEventListener('click', () => { box.hidden = true; cockpitState.promotedTicket = null; postToTab(cockpitState, { type: 'adopt', ticket }); });
  const no = document.createElement('button');
  no.className = 'ck-scratch-btn ghost'; no.type = 'button'; no.textContent = 'Not now';
  no.addEventListener('click', () => { box.hidden = true; cockpitState.promotedTicket = null; });
  row.append(yes, no);
  box.append(p, row);
}
// Adopted: the scratch session has ended; open the ticket there (or just report it).
export async function finishAdopt(scratchId, ticket, cwd, thenEnd) {
  state.adoptCwd = state.adoptCwd || {};
  state.adoptCwd[ticket] = cwd;
  unmountTab(scratchId);
  state.scratch.delete(scratchId);
  try { await loadData(); render(); } catch { renderBoard(); }
  if (thenEnd) { showToast('Saved as ' + ticket + ' \u2014 Resume it any time to continue this conversation.'); return; }
  if (findTicketById(ticket)) openCockpit(ticket);
}
// t-f553: tell the shell which scratch tabs here haven't started their agent, so its Agents
// list shows them (the daemon only reports running sessions).
export function announceScratchTabs() {
  if (window.parent === window) return;
  const tabs = Object.keys(cockpitTabs).filter(id => SCRATCH_ID.test(id) && !cockpitTabs[id].started).map(id => {
    const t = state.scratch.get(id);
    return { id, title: t && t.title !== 'Scratch session' ? t.title : '' };
  });
  try { window.parent.postMessage({ source: 'canon-board', type: 'scratch-tabs', tab: SHELL_TAB, tabs }, location.origin); } catch {}
}
export function newScratchId() {   // t-e162: the path bar's "+ Scratch" mints its own id
  const a = 'abcdefghijklmnopqrstuvwxyz0123456789', b = new Uint8Array(4);
  crypto.getRandomValues(b);
  return 's-' + [...b].map(x => a[x % 36]).join('');
}
// Where a scratch session runs: the main checkout, or the daemon-made worktree (t-e162).
export function renderScratchWhere(tab) {
  const el = document.getElementById('ck-scratch-where');
  if (!el) return;
  const cwd = tab && tab.actualCwd;
  el.textContent = !cwd ? 'Starts in the main checkout, or its own scratch worktree when that is busy.'
    : normProjectPath(cwd) === normProjectPath(state.gitRoot) ? 'Running in the main checkout.'
    : 'Running in worktree ' + cwd.split(/[\\/]/).filter(Boolean).pop() + ' — removed on End if nothing was done in it.';
}
export function openScratch(id, opts = {}) {
  if (!SCRATCH_ID.test(id)) return;
  // t-57ab: opts.term opens the restricted terminal (the daemon page gets mode=term) instead of an agent.
  if (!state.scratch.has(id)) state.scratch.set(id, { id, title: opts.term ? 'Terminal' : 'Scratch session', status: 'scratch', scratch: true, term: !!opts.term, docs: [] });
  openCockpit(id);
}

// t-1543: this file's load-time code; board-main.js runs it after every module has loaded.
export function initRender() {
  document.getElementById('drop-toast')?.addEventListener('click', e => {
    if (e.target.matches('.toast-confirm') && _pendingConfirm) {
      const fn = _pendingConfirm;
      _pendingConfirm = null;
      clearTimeout(_toastTimer);
      document.getElementById('drop-toast').classList.remove('show');
      fn();
    }
  });
}
