import { SHELL_TAB, loadData, state } from './board-core.js';
import { CK_SIGNAL_LABEL, CK_STATE_LABEL, COCKPIT_TICKET_ID, SCRATCH_ID, announceScratchTabs, ckRowState, findTicketById, finishAdopt, openScratch, postToTab, render, renderBoard, renderScratchWhere, showPromotedChoice, showToast, startPromote } from './board-render.js';
import { findLiveDaemonSession, openTicketWhenLoaded, renderCockpitRail, renderTabStrip, stopCockpitPoll } from './board-cockpit-rail.js';
import { applyActualWorkingCwd, maybeMountCockpitTerminal } from './board-worktree.js';

// ── Cockpit (t-ddc8): one-window mode ───────────────────────────────────────
// Board↔cockpit switch. The board owns no PTY — it ensures the shipped
// cockpit-daemon is running (POST /api/cockpit) and iframes its /cockpit page.
// Acceptance/Test Plan are view-only (t-96a8) — a human watching the agent
// work could inadvertently check a box that isn't actually verified, so the
// rail only ever reads acceptance.md, never writes to it. Since nothing here
// writes, there is no whole-document checkbox index to compute or keep in
// sync — the earlier toggle-write path's index-offset math is gone with it.
// worktreeCwd: null = no row selected yet (OPEN-ticket Start stays gated,
// t-cd06), '' = Main checkout selected, otherwise an absolute worktree path.
//
// t-8a2a: multi-session support. cockpitTabs holds one state object per open
// ticket (keyed by ticket id), each carrying its own iframeEl + everything
// cockpitState used to hold alone. cockpitState is now just a REFERENCE to
// cockpitTabs[activeTabId] — reassigned by setActiveTab(), never copied — so
// every existing `cockpitState.X` read/write below keeps working unchanged
// against whichever tab is currently active, with zero call-site rewrites.
// Only functions that must reach a BACKGROUND tab's own state (the message
// listener, the shared poll loop) address cockpitTabs[id] directly.
export const cockpitTabs = {};
export let activeTabId = null;
export let cockpitState = null;

export function newCockpitTabState(id, iframeEl) {
  // t-82f4: previewEl/previewCollapsed mirror iframeEl's per-tab persistence —
  // the preview pane used to be one global singleton, reset on every reopen.
  return { id, addr: null, status: null, worktreeCwd: null, actualCwd: null, worktreeDocs: null, docSeen: {}, docSeenSrc: '', fresh: {}, _ending: false, iframeEl, pendingMessage: '', previewEl: null, previewCollapsed: true };
}

// Sets the terminal status message AND remembers it on the active tab, so
// switching tabs can restore the right text into the one shared #ck-term-msg
// element (see setActiveTab) instead of leaking the last-active tab's text.
// t-d254: a worktree created before its ticket was committed can't see it.
// Name the exact fix-up (commit on the main checkout, then merge that branch in)
// instead of a vague "commit .tickets/" — shown as text via setTermMessage.
export function missingTicketMessage(ticketId, worktreePath, mainBranch) {
  const main = mainBranch || 'main';
  return `This worktree doesn't contain ${ticketId}, so a Start here would fail — Start sprint is disabled. `
    + `Use the Main checkout, or bring the ticket in: on the Main checkout run `
    + `git add .tickets/${ticketId} then git commit -m "chore: add ticket ${ticketId}" -- .tickets/${ticketId}, `
    + `then git -C "${worktreePath}" merge ${main}`;
}

// t-d254: swap a button into a busy "spinner + label" state and back. The label is
// text (textContent), the spinner a fixed element, so nothing here parses HTML.
export function setButtonBusy(btn, busyLabel, idleLabel) {
  btn.textContent = '';
  if (busyLabel) {
    const sp = document.createElement('span');
    sp.className = 'ck-spin';
    sp.setAttribute('aria-hidden', 'true');
    btn.append(sp, busyLabel);
    btn.setAttribute('aria-busy', 'true');
  } else {
    btn.textContent = idleLabel;
    btn.removeAttribute('aria-busy');
  }
}

export function setTermMessage(text) {
  const el = document.getElementById('ck-term-msg');
  if (el) el.textContent = text;
  if (cockpitState) cockpitState.pendingMessage = text;
}

// The iframe belonging to whichever tab is currently active — replaces the
// old single #ck-iframe lookup at every call site that only ever acts on the
// active tab (mount/terminal-status functions; the message listener is the
// one exception, since it must resolve the SOURCE tab, not just the active one).
export function activeIframe() {
  return cockpitState ? cockpitState.iframeEl : null;
}

// Switches which tab is "active": reassigns cockpitState to point at it,
// toggles which tab's iframe is visible in the DOM (never re-src'd — no
// reconnect), and restores that tab's own pending terminal message into the
// one shared #ck-term-msg element.
//
// The active tab's iframe also gets id="ck-iframe" (cleared on every other
// tab's iframe) — this is what "singular rail, driven by the active tab"
// (grill #1) means for the terminal DOM node itself, and it's why every
// pre-t-8a2a call site (and Playwright test) that looked up #ck-iframe still
// resolves correctly with zero changes: there's still exactly one #ck-iframe
// in the DOM, it just now migrates between tabs on switch.
export function setActiveTab(id) {
  activeTabId = id;
  cockpitState = cockpitTabs[id] || null;
  // t-82f4: preview containers get the same show/hide-only swap as terminal
  // iframes, in the same pass — a backgrounded tab's mounted preview (if any)
  // stays alive in the DOM, never re-created.
  for (const [tid, tab] of Object.entries(cockpitTabs)) {
    const isActive = tid === id;
    if (tab.iframeEl) {
      tab.iframeEl.style.display = isActive ? '' : 'none';
      if (isActive) tab.iframeEl.id = 'ck-iframe';
      else tab.iframeEl.removeAttribute('id');
    }
    if (tab.previewEl) tab.previewEl.style.display = isActive ? '' : 'none';
  }
  document.getElementById('ck-preview').classList.toggle('collapsed', !cockpitState || cockpitState.previewCollapsed);
  const msgEl = document.getElementById('ck-term-msg');
  if (msgEl) msgEl.textContent = (cockpitState && cockpitState.pendingMessage) || '';
  // t-f553: the "Continue as <id>" choice belongs to the tab whose agent created the ticket.
  if (cockpitState && cockpitState.promotedTicket) showPromotedChoice(cockpitState.promotedTicket);
  else document.getElementById('ck-scratch-promoted').hidden = true;
}

// t-824e: the active tab's state chip + reaper line. The live status stream says
// needs-you the instant the hook fires; the daemon's /sessions row (refreshed
// by the shared cockpit poll) adds working / idle / done and the reaper clock.
// A daemon older than t-824e sends no "state": fall back to needs-you / running (ckRowState).
function fmtWait(secs) {
  const m = Math.floor(secs / 60);
  return m >= 60 ? Math.floor(m / 60) + 'h ' + (m % 60) + 'm' : m > 0 ? m + 'm' : 'under a minute';
}
export function renderSessionStateChip() {
  const chip = document.getElementById('ck-state-chip'), reaper = document.getElementById('ck-reaper');
  if (!sessionIsLive()) { chip.hidden = true; reaper.hidden = true; return; }
  const row = cockpitState.daemonRow || null;
  const num = v => (typeof v === 'number' && isFinite(v) && v >= 0) ? v : null;
  let st = row ? ckRowState(row) : 'running';
  if (cockpitState.status === 'needs-you') st = 'needs-you';
  chip.className = 'ck-state-chip st-' + st;
  chip.textContent = CK_STATE_LABEL[st];
  const signal = row && CK_SIGNAL_LABEL[row.signal];
  chip.title = signal ? 'State from: ' + signal : 'State from the session\u2019s status';
  chip.hidden = false;
  const idle = row && num(row.idle_secs), limit = row && num(row.idle_limit_secs);
  // t-91c5: the Agents sidebar already shows the countdown ("reaps in 29m"), so the top bar says only "Auto Save" and
  // keeps the full sentence as the tooltip.
  let reaperText = '', reaperTip = '';
  if (st === 'needs-you') { reaperText = 'Auto Save paused'; reaperTip = 'Auto-save paused \u00b7 waiting on you'; }
  else if (idle !== null && limit !== null) { reaperText = 'Auto Save'; reaperTip = 'Auto-save & end in ' + fmtWait(Math.max(0, limit - idle)) + ' \u00b7 resets on activity'; }
  reaper.textContent = reaperText;
  if (reaperTip) reaper.title = reaperTip; else reaper.removeAttribute('title');
  reaper.hidden = !reaperText;
}
export async function refreshSessionStateChip() {
  const tab = cockpitState, id = activeTabId;
  if (!tab || !document.getElementById('cockpit-overlay').classList.contains('open') || !sessionIsLive()) { renderSessionStateChip(); return; }
  const row = await findLiveDaemonSession(id);
  if (tab !== cockpitState) return; // switched tabs while the lookup was in flight
  tab.daemonRow = row;
  renderSessionStateChip();
}

// ── Preview pane (t-b19b) ───────────────────────────────────────────────────
// v1 scope, deliberately: the daemon never starts/stops/manages any process.
// A static-file deliverable gets served read-only into a sandboxed iframe; a
// server-needing deliverable gets a static "run this yourself" message.

// t-82f4: lazily creates (and mounts into #ck-preview-body) TAB's own detached
// preview container — mirrors how a tab's terminal iframe is created once and
// then only shown/hidden. Every render* function below writes into a specific
// tab's container, never the shared body directly, so switching tabs can never
// clobber another tab's already-mounted preview.
function previewBodyFor(tab) {
  if (!tab.previewEl) {
    const el = document.createElement('div');
    el.className = 'ck-preview-tab-body';
    el.style.display = tab.id === activeTabId ? '' : 'none';
    document.getElementById('ck-preview-body').appendChild(el);
    tab.previewEl = el;
  }
  return tab.previewEl;
}

function renderPreviewMessage(text) {
  const body = previewBodyFor(cockpitState);
  body.innerHTML = '<div class="ck-preview-msg"></div>';
  body.querySelector('.ck-preview-msg').textContent = text;
}

// t-533f: a local absolute path → the file:/// URL a real browser opens (POSIX, Windows drive,
// UNC). Each segment is percent-encoded so spaces and '#' survive; '' for anything else.
export function fileUrlFor(p) {
  if (typeof p !== 'string' || !p) return '';
  const enc = parts => parts.filter(Boolean).map(encodeURIComponent).join('/');
  let m = p.match(/^\\\\([^\\/]+)[\\/](.+)$/);
  if (m) return `file://${encodeURIComponent(m[1])}/${enc(m[2].split(/[\\/]/))}`;
  m = p.match(/^([A-Za-z]):[\\/](.*)$/);
  if (m) return `file:///${m[1].toUpperCase()}:/${enc(m[2].split(/[\\/]/))}`;
  if (p.startsWith('/')) return `file:///${enc(p.split('/'))}`;
  return '';
}

// The note row above the sandboxed preview. It never opens or navigates to the daemon preview
// URL: top-level, that page would share the daemon's origin and could read the token /cockpit
// embeds (t-533f research.md). The user pastes the file:/// URL into a real browser instead.
function previewNoteFor(relpath, absPath) {
  const note = document.createElement('div');
  note.className = 'ck-preview-note';
  const text = document.createElement('span');
  text.className = 'ck-preview-note-text';
  text.textContent = 'Preview is sandboxed — forms and storage are disabled. Open it in your browser to use the app.';
  note.appendChild(text);
  const url = fileUrlFor(absPath);
  if (!url) {
    const hint = document.createElement('span');
    hint.className = 'ck-preview-copy-status';
    hint.textContent = `Open ${relpath} from the project folder in your browser.`;
    note.appendChild(hint);
    return note;
  }
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'ck-preview-copy';
  btn.textContent = 'Copy file link';
  btn.title = url;
  btn.setAttribute('aria-label', `Copy the file link for ${relpath} to open in your browser`);
  const status = document.createElement('span');
  status.className = 'ck-preview-copy-status';
  status.setAttribute('role', 'status');
  btn.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(url);
      status.textContent = "Copied — paste it into your browser's address bar.";
    } catch {
      status.textContent = "Copy this link into your browser's address bar:";
      let input = note.querySelector('.ck-preview-copy-url');
      if (!input) {
        input = document.createElement('input');
        input.className = 'ck-preview-copy-url';
        input.readOnly = true;
        input.setAttribute('aria-label', 'File link');
        input.value = url;
        note.appendChild(input);
      }
      input.focus();
      input.select();
    }
  });
  note.appendChild(btn);
  note.appendChild(status);
  return note;
}

function renderPreviewFile(session, previewToken, relpath, absPath) {
  if (!cockpitState.addr || !session || !previewToken || !relpath) {
    renderPreviewMessage("Couldn't load the preview (missing session details).");
    return;
  }
  // t-8fbc: the previewToken is a PATH segment (…/preview/<token>/<relpath>),
  // not a ?token= query, so a relative sibling asset (./style.css) requested by
  // the served page keeps the token — a query string is dropped on relative URL
  // resolution, a path prefix is not.
  const url = `http://${cockpitState.addr}/session/${encodeURIComponent(session)}/preview/${encodeURIComponent(previewToken)}/${encodeURIComponent(relpath)}`;
  const body = previewBodyFor(cockpitState);
  body.innerHTML = '';
  body.appendChild(previewNoteFor(relpath, absPath));
  const iframe = document.createElement('iframe');
  // allow-scripts only, deliberately no allow-same-origin — the previewed
  // app-under-test is untrusted content; this keeps it at an opaque origin
  // so it can't reach real daemon endpoints even if it reads its own token
  // straight off location.pathname (see t-b19b plan.md's Pre-mortem). Moving
  // the token from location.search to location.pathname is identical exposure.
  iframe.setAttribute('sandbox', 'allow-scripts');
  iframe.src = url;
  body.appendChild(iframe);
}

function renderPreviewServerCmd(cmd) {
  const body = previewBodyFor(cockpitState);
  body.innerHTML = '<div class="ck-preview-msg">This app needs a running server — run this yourself:<br><br><code></code></div>';
  body.querySelector('code').textContent = cmd;
}

export function requestPreview() {
  const iframe = activeIframe();
  if (!iframe || !iframe.contentWindow || !cockpitState || !cockpitState.addr) return;
  renderPreviewMessage('Asking the agent how to preview this ticket’s deliverable…');
  iframe.contentWindow.postMessage({ source: 'canon-cockpit', type: 'preview-request' }, 'http://' + cockpitState.addr);
}

export function sessionIsLive() {
  return !!cockpitState && (cockpitState.status === 'running' || cockpitState.status === 'needs-you');
}

export function openLeaveConfirm() {
  const needsYou = cockpitState.status === 'needs-you';
  // Reset every control fresh — a prior session's in-flight save could have
  // left "Cancel" disabled and stale status text behind.
  document.getElementById('ck-leave-save').disabled = needsYou;
  // End without saving never needs the agent's cooperation (it force-ends via
  // the daemon, same as the closed-ticket short-circuit) — stays enabled even
  // while needs-you blocks the normal Save & End path.
  document.getElementById('ck-leave-skip').disabled = false;
  document.getElementById('ck-leave-cancel').disabled = false;
  document.getElementById('ck-leave-save').style.display = '';
  document.getElementById('ck-leave-skip').style.display = '';
  document.getElementById('ck-leave-skip').textContent = 'End without saving';
  document.getElementById('ck-leave-save').textContent = 'Save & End';
  document.getElementById('ck-leave-confirm-title').textContent = 'A sprint session is still running';
  document.getElementById('ck-leave-cancel').textContent = 'Cancel';
  document.getElementById('ck-leave-confirm-body').textContent = needsYou
    ? 'The agent is waiting on you right now — Cancel to go back and resolve the prompt, then you can Save & End, or End without saving.'
    : "Save & End saves this sprint's state to HANDOFF and ends the session. End without saving skips that and ends immediately — use it if the save is stuck. Cancel to keep working here.";
  document.getElementById('ck-leave-confirm-status').textContent = '';
  const discardBtn = document.getElementById('ck-leave-discard');
  discardBtn.hidden = true;
  discardBtn.classList.remove('armed');
  discardBtn.disabled = false;
  delete discardBtn.dataset.mode;
  document.getElementById('ck-leave-confirm').classList.add('open');
  if (SCRATCH_ID.test(cockpitState.id || '')) {   // t-47f1: nothing to save — End only
    // t-f553: offer to keep the work as a ticket before ending
    document.getElementById('ck-leave-save').textContent = 'Save as ticket, then end';
    document.getElementById('ck-leave-skip').textContent = 'Just end';
    document.getElementById('ck-leave-confirm-title').textContent = 'Save this session as a ticket?';
    document.getElementById('ck-leave-confirm-body').textContent = 'Save as ticket asks the agent to create a ticket from this session (you approve its tkt create command), then ends it — Resume the ticket later to continue the conversation. Just end ends it now.';
    // t-86fe: ask the daemon what ending would leave behind; showScratchChanges fills it in.
    cockpitState.leaveChanges = null;
    document.getElementById('ck-leave-confirm-status').textContent = 'Checking for changes…';
    postToTab(cockpitState, { type: 'changes-request' });
    return;
  }
  // t-b999: a closed ticket has nothing to save (t-98d8 force-ends it anyway), so don't offer
  // Save & End. The in-memory status can be stale (sprint complete runs in the terminal), so
  // re-read it; a failed read keeps the normal dialog.
  const tab = cockpitState;
  const localClosed = (state.tickets || []).some(t => t.id === tab.id && t.status === 'closed');
  if (localClosed) showClosedLeave();
  else isTicketClosed(tab.id).then(closed => {
    if (closed && cockpitState === tab && document.getElementById('ck-leave-confirm').classList.contains('open')) showClosedLeave();
  });
}

// t-86fe: the End dialog for a scratch session that would leave changes behind.
function showScratchChanges(c) {
  if (!document.getElementById('ck-leave-confirm').classList.contains('open')) return;
  const statusEl = document.getElementById('ck-leave-confirm-status');
  statusEl.textContent = '';
  cockpitState.leaveChanges = c;
  if (!c.total && !c.commits) return;   // clean: the t-f553 dialog as it is
  const plural = (n, w) => n + ' ' + w + (n === 1 ? '' : 's');
  const what = [c.total ? plural(c.total, 'changed file') : '', c.commits ? plural(c.commits, 'commit') + ' in its worktree' : ''].filter(Boolean).join(' and ');
  document.getElementById('ck-leave-confirm-title').textContent = (c.no_git ? 'This session changed ' + plural(c.total, 'file') : 'This session has ' + what);
  const body = document.getElementById('ck-leave-confirm-body');
  body.textContent = 'Save as ticket hands them to a new ticket. Keep changes ends the session and leaves them in place, noted in HANDOFF.md.'
    + (c.no_git ? ' Ending keeps every change in your folder. Restore original puts back the files it edited or deleted, as they were when the session started; files it added stay.'
      : c.can_discard ? ' Discard throws away the file changes (edits and new files; ignored files stay).'
      : c.total ? ' Discard isn\u2019t offered: this checkout already had uncommitted changes when the session started.' : '');
  if (c.files.length) {
    const ul = document.createElement('ul');
    ul.className = 'ck-leave-files';
    for (const f of c.files.slice(0, 10)) {
      const li = document.createElement('li');
      li.textContent = (f.status ? f.status + ' ' : '') + f.path;
      ul.append(li);
    }
    if (c.total > 10) {
      const li = document.createElement('li');
      li.textContent = 'and ' + (c.total - 10) + ' more';
      ul.append(li);
    }
    body.append(ul);
  }
  document.getElementById('ck-leave-skip').textContent = 'Keep changes, end';
  const discardBtn = document.getElementById('ck-leave-discard');
  discardBtn.textContent = c.no_git ? 'Restore original files, end' : 'Discard changes, end';
  discardBtn.dataset.mode = c.no_git ? 'restore' : '';   // t-5a4b: without git, this button puts the originals back
  discardBtn.hidden = c.no_git ? !c.total : !c.can_discard;
}

function showClosedLeave() {
  document.getElementById('ck-leave-save').style.display = 'none';
  document.getElementById('ck-leave-confirm-body').textContent =
    'This ticket is closed — there is nothing to save. End without saving to close the session, or Cancel to keep working here.';
}

function closeLeaveConfirm() {
  document.getElementById('ck-leave-confirm').classList.remove('open');
}

// t-8a2a: shared by closeTab() and teardownCockpit() — removes a tab's own
// iframe from the DOM (dropping its connection outright, a stronger and
// simpler guarantee than the old single-tab `iframe.src = 'about:blank'`)
// and drops its entry from cockpitTabs. If it was the active tab, switches to
// another open tab, or hides the overlay + stops the shared poll if none remain.
export function unmountTab(id) {
  const tab = cockpitTabs[id];
  if (!tab) return;
  if (tab.iframeEl && tab.iframeEl.parentNode) tab.iframeEl.parentNode.removeChild(tab.iframeEl);
  // t-82f4: free the tab's own preview container too, same as its terminal
  // iframe above — otherwise a closed tab's preview iframe leaks, detached
  // from the tab strip but still parented under #ck-preview-body.
  if (tab.previewEl && tab.previewEl.parentNode) tab.previewEl.parentNode.removeChild(tab.previewEl);
  delete cockpitTabs[id];
  announceScratchTabs();
  if (activeTabId === id) {
    const remaining = Object.keys(cockpitTabs);
    if (remaining.length) {
      const nextId = remaining[remaining.length - 1];
      setActiveTab(nextId);
      // setActiveTab only swaps which iframe/message-buffer is active — the
      // topbar/rail labels (ck-id, ck-title, worktree/plan/state panels) are
      // stale until re-rendered for the tab we just switched to.
      const nextTicket = findTicketById(nextId);
      if (nextTicket) renderCockpitRail(nextTicket);
      // The ticket vanished from state.tickets between that tab opening and
      // this switch (e.g. archived/deleted elsewhere while backgrounded) —
      // don't leave the previous tab's stale labels on screen.
      else { document.getElementById('ck-id').textContent = nextId; document.getElementById('ck-title').textContent = ''; document.getElementById('ck-title').title = ''; }
    } else {
      activeTabId = null;
      cockpitState = null;
      document.getElementById('cockpit-overlay').classList.remove('open');
      stopCockpitPoll();
      renderSessionStateChip(); // null cockpitState -> hides it; no other path re-renders this once the last tab closes
    }
  }
  renderTabStrip();
}

// User-initiated tab close (the strip's "×") — NEVER ends the session; the
// daemon keeps it live regardless (t-c6fa attaches a later Start/Resume to
// it instead of double-spawning). This is the HIGH blast-radius boundary the
// ticket exists to enforce: closeTab() must never call teardownCockpit(), and
// must never send any daemon request.
export function closeTab(id) {
  unmountTab(id);
}

// A session genuinely ended (Save & End / End without saving / a daemon exit
// event) — unmount its tab and refresh the board, since the ticket's status
// may have changed server-side. `id` defaults to the active tab, since every
// call site that ends a session acts on whichever tab is currently shown.
export function teardownCockpit(id) {
  id = id || activeTabId;
  if (!id || !cockpitTabs[id]) return;
  // t-82f4: unmountTab() already frees this tab's own preview container and,
  // if it was active, setActiveTab() re-syncs the panel for whichever tab is
  // next (or the overlay just closes if none remain) — no separate reset needed.
  unmountTab(id); // already re-renders the needs-you badge for whichever path it takes (switch or last-tab-closed)
  loadData().then(render).catch(() => renderBoard());
}

// t-98d8: fresh ticket-status read for the Save & End short-circuit. The cockpit
// poll never reloads /api/tickets and `sprint complete` runs in the terminal, so
// the in-memory `state` can be stale exactly when this matters. Fail safe: any
// fetch/parse error returns false, so the normal save-and-end path runs.
async function isTicketClosed(id) {
  try {
    const r = await fetch('/api/tickets?all=1');
    if (!r.ok) return false;
    const tickets = await r.json();
    const t = (tickets || []).find(x => x && x.id === id);
    return !!t && t.status === 'closed';
  } catch { return false; }
}

// t-0db3: extracted so the Canon Cockpit shell's close-tab guard can drive the
// SAME vetted flow via postMessage. skipSave=true = "End without saving" (routes
// through the daemon's force-end, same as the already-closed short-circuit) — a
// clean daemon end, never a silent orphan/kill.
async function ckLeaveSaveAndEnd(skipSave, opts) {
  const iframe = activeIframe();
  const statusEl = document.getElementById('ck-leave-confirm-status');
  const saveBtn = document.getElementById('ck-leave-save');
  // t-9eda: check reentry FIRST, before the liveness check below — a prior
  // end sequence still in flight (its own finish() hasn't cleared this yet)
  // must always no-op, regardless of what sessionIsLive() would say at this
  // instant. Checking liveness first would let a stale/flipped status route
  // a reentrant call into the teardown branch instead of a no-op, silently
  // tearing down state the first invocation still owns — reintroducing the
  // exact bug this ticket fixes. A second invocation is already handled by
  // the first sequence; there is nothing new to do here.
  if (cockpitState._ending) return;
  if (!skipSave && SCRATCH_ID.test(cockpitState.id || '')) {   // t-f553: "Save as ticket, then end"
    closeLeaveConfirm();
    startPromote(true);
    return;
  }
  // t-8efc: the modal's liveness check runs once, at open time. If the
  // automatic idle-reap ends the session while the modal is still sitting
  // open, cockpitState.status already advances to non-live (the daemon's
  // exit event drives this via the existing 'status' postMessage) — but
  // nothing re-reads it until now. Without this check, save-and-end fires
  // into an already-dead session and hangs the full 90s fallback for
  // nothing.
  if (!sessionIsLive()) {
    closeLeaveConfirm();
    teardownCockpit();
    return;
  }
  cockpitState._ending = true;
  // t-76dc: "End without saving" writes nothing, so unlike Save & End it can
  // dismiss its modal immediately — matching cockpit.html's confirmCloseTab,
  // which closes its own warning modal right away without ever touching the
  // iframe's src, so the SSE stream (the only channel that can report a
  // slow/failed kill) keeps running underneath. teardownCockpit() itself is
  // NOT called yet here — only once cockpitState._onEnded actually fires
  // below, same as before — so a slow/failed kill is still never silently
  // orphaned, only the confirm dialog closes early.
  const termMsg = document.getElementById('ck-term-msg');
  // t-86fe: a scratch session ends through the daemon's end guard — it notes anything left
  // behind in HANDOFF.md, and discards only when asked.
  const scratchEnd = SCRATCH_ID.test(cockpitState.id || '')
    ? { source: 'canon-cockpit', type: 'end-scratch', discard: !!(opts && opts.discard), restore: !!(opts && opts.restore) } : null;
  if (skipSave) {
    closeLeaveConfirm();
    iframe.style.visibility = 'hidden';
    termMsg.textContent = scratchEnd ? 'Ending…' : 'Ending without saving…';
  } else {
    // Cancel must not be clickable mid-save either — closeLeaveConfirm() only
    // hides the modal, it doesn't abort the pending save-and-end sequence, so
    // a "successful" cancel would tear the cockpit down anyway once the
    // marker/timeout fires, with no dialog left open to explain why.
    document.getElementById('ck-leave-cancel').disabled = true;
    document.getElementById('ck-leave-skip').disabled = true;
    saveBtn.disabled = true;
    statusEl.textContent = 'Ending…';
  }
  let done = false;
  let closed = false;
  const finish = (msg) => {
    if (done) return; done = true;
    cockpitState._onEnded = null;
    cockpitState._onSaveRefused = null;
    cockpitState._ending = false;
    if (!skipSave) statusEl.textContent = msg; // modal already closed for skipSave
    closeLeaveConfirm();
    teardownCockpit();
  };
  // t-98d8: arm the ended-handler and the fallback BEFORE the async status
  // fetch below, not after — otherwise an idle-reap 'ended' landing during the
  // fetch window arrives while _onEnded is still null (teardownCockpit clears
  // it) and is dropped, leaving the flow to resolve only via the 90s fallback.
  // `closed` is read lazily by this closure, so it reflects the fetch result if
  // 'ended' fires after it, and defaults to the (harmless) save-and-end message
  // if it fires during the fetch.
  cockpitState._onEnded = () => finish(closed ? 'Ended — ticket already closed, no state to save.' : (skipSave ? 'Ended without saving.' : 'Saved and ended.'));
  // Overridable so tests don't wait 90 real seconds; production leaves it unset.
  const fallbackMs = window.__cockpitSaveFallbackMs || 90000;
  const fallbackTimer = setTimeout(() => {
    if (done) return;
    // The marker never showed up — force the kill directly rather than just
    // blanking the iframe, or the session orphans anyway (the exact bug
    // this whole flow exists to prevent).
    iframe.contentWindow.postMessage(scratchEnd || { source: 'canon-cockpit', type: 'force-end' }, 'http://' + cockpitState.addr);
    setTimeout(() => finish('Timed out waiting for save — ended anyway. It may be incomplete.'), 3000);
  }, fallbackMs);
  // t-f91a: the daemon refused Save & End because copilot is waiting on a selection menu
  // (a tool-call approval, folder trust). Nothing was typed and nothing ended: cancel the
  // fallback kill, give the controls back, and say why. The modal stays open; the user
  // answers the menu in the terminal, then retries — or picks End without saving.
  cockpitState._onSaveRefused = () => {
    if (done) return;
    clearTimeout(fallbackTimer);
    cockpitState._onEnded = null;
    cockpitState._onSaveRefused = null;
    cockpitState._ending = false;
    statusEl.textContent = 'Copilot is waiting for your answer to a prompt in the terminal — answer it there, then Save & End again (or End without saving).';
    document.getElementById('ck-leave-cancel').disabled = false;
    document.getElementById('ck-leave-skip').disabled = false;
    saveBtn.disabled = false;
  };
  // t-98d8: an already-closed ticket has no in-progress state worth a full agent
  // save turn — skip the save-state prompt and end cleanly via force-end. Status
  // is fetched fresh (isTicketClosed), failing safe to the save path on error.
  closed = await isTicketClosed(cockpitState.id);
  if (done) return; // idle-reap already ended us during the fetch — nothing to send
  if (closed || skipSave) {
    if (!skipSave) statusEl.textContent = 'Ticket already closed — ending…'; // skipSave's modal is already closed
    iframe.contentWindow.postMessage(scratchEnd || { source: 'canon-cockpit', type: 'force-end' }, 'http://' + cockpitState.addr);
  } else {
    statusEl.textContent = 'Saving state — the agent is writing HANDOFF (one agent turn, may take a moment)…';
    iframe.contentWindow.postMessage({ source: 'canon-cockpit', type: 'save-and-end' }, 'http://' + cockpitState.addr);
  }
}

// t-1543: this file's load-time code; board-main.js runs it after every module has loaded.
export function initCockpit() {
  // t-f6b6: the board and the daemon page are different origins (different
  // port), so the only channel for "is a session live" and "please save state
  // then end" is postMessage — and the only real trust boundary is validating
  // every INCOMING message's origin/source before acting on it (outbound is
  // fine with "*": no secret ever rides in these payloads, just status labels
  // and a fixed command name).
  // t-8a2a: multiple iframes exist now (one per open tab), so this must resolve
  // WHICH tab a message came from — not just check against a single global
  // iframe — or a background tab's status/needs-you/ended updates go missing.
  window.addEventListener('message', (e) => {
    let sourceId = null, tab = null;
    for (const [tid, tb] of Object.entries(cockpitTabs)) {
      if (tb.iframeEl && e.source === tb.iframeEl.contentWindow) { sourceId = tid; tab = tb; break; }
    }
    if (!tab || !tab.addr) return;
    if (e.origin !== 'http://' + tab.addr) return;
    const d = e.data;
    if (!d || d.source !== 'canon-cockpit') return;
    const isActive = sourceId === activeTabId;
    if (d.type === 'prefix-armed' || d.type === 'prefix-cancel' || d.type === 'prefix-key') {   // t-a198: relay the terminal's prefix to the shell
      if (isActive && window.parent !== window && (d.type !== 'prefix-key' || (typeof d.key === 'string' && d.key.length <= 2))) {
        window.parent.postMessage({ source: 'canon-board', type: d.type, key: typeof d.key === 'string' ? d.key : '', tab: SHELL_TAB }, location.origin);
      }
      return;
    }
    if (d.type === 'status') {
      tab.status = d.status;
      if (isActive) { renderSessionStateChip(); refreshSessionStateChip(); }
      renderTabStrip();
    } else if (d.type === 'started') {
      // applyActualWorkingCwd renders rail DOM that belongs to the active tab
      // only (grill #1) — a background tab just remembers its own cwd for when
      // it becomes active later.
      if (SCRATCH_ID.test(tab.id || '')) {   // t-e162: scratch rail shows where it runs, no worktree picker
        if (!tab.started) { tab.started = true; announceScratchTabs(); }   // t-f553: the daemon reports it now
        tab.actualCwd = d.cwd || '';
        if (isActive) renderScratchWhere(tab);
      } else if (isActive) applyActualWorkingCwd(d.cwd, d.requested);
      else tab.actualCwd = d.cwd || '';
    } else if (d.type === 'ended' && tab._onEnded) {
      tab._onEnded();
    } else if (d.type === 'changes') {   // t-86fe
      if (isActive) showScratchChanges({ total: Number(d.total) || 0, commits: Number(d.commits) || 0, can_discard: d.can_discard === true,
        no_git: d.no_git === true,
        files: Array.isArray(d.files) ? d.files.filter(f => f && typeof f.path === 'string').map(f => ({ status: String(f.status || '').slice(0, 2), path: f.path })) : [] });
    } else if (d.type === 'changes-failed') {
      if (isActive) document.getElementById('ck-leave-confirm-status').textContent = 'Couldn\u2019t check for changes \u2014 Just end keeps any changes in place.';
    } else if (d.type === 'scratch-ended') {
      if (d.error) showToast('\u26a0 Discard failed \u2014 changes kept and noted in HANDOFF.md: ' + String(d.error).slice(0, 160), 'warn');
      else if (d.note_error) showToast('\u26a0 Ended, but HANDOFF.md couldn\u2019t be updated: ' + String(d.note_error).slice(0, 160), 'warn');
      else if (d.files || d.commits) showToast('Ended \u2014 changes kept and noted in HANDOFF.md.');
    } else if (d.type === 'end-scratch-failed') {
      // Nothing ended: stop the pending end (and its fallback kill), show the terminal again.
      if (tab._onSaveRefused) tab._onSaveRefused();
      if (tab.iframeEl) tab.iframeEl.style.visibility = '';
      if (isActive) document.getElementById('ck-term-msg').textContent = '';
      showToast('\u26a0 ' + String(d.reason || 'Ending failed').slice(0, 200), 'warn');
    } else if (d.type === 'promote-refused') {   // t-f553
      showToast('⚠ ' + String(d.reason || 'Promote refused').slice(0, 200), 'warn');
    } else if (d.type === 'ticket-promoted' && typeof d.ticket === 'string' && COCKPIT_TICKET_ID.test(d.ticket)) {
      if (tab.promoteThenEnd) { postToTab(tab, { type: 'adopt', ticket: d.ticket }); }
      else {
        tab.promotedTicket = d.ticket;   // per tab: shown when this tab is (or becomes) active
        if (isActive) showPromotedChoice(d.ticket);
      }
    } else if (d.type === 'adopted' && typeof d.ticket === 'string' && COCKPIT_TICKET_ID.test(d.ticket)) {
      finishAdopt(sourceId, d.ticket, String(d.cwd || ''), !!tab.promoteThenEnd);
    } else if (d.type === 'adopt-failed') {
      showToast('⚠ ' + String(d.reason || 'Could not continue as the ticket').slice(0, 200), 'warn');
    } else if (d.type === 'save-refused' && tab._onSaveRefused) {
      tab._onSaveRefused();   // t-f91a: copilot is on a menu waiting for the user — nothing was typed
    } else if (d.type === 'preview-file') {
      if (isActive) renderPreviewFile(d.session, d.previewToken, d.relpath, d.path);
    } else if (d.type === 'preview-server-cmd') {
      if (isActive) renderPreviewServerCmd(d.cmd);
    } else if (d.type === 'preview-timeout') {
      if (isActive) renderPreviewMessage("Couldn't determine how to preview this ticket's deliverable — the agent didn't respond with a recognized marker within 60s.");
    } else if (d.type === 'preview-rejected') {
      if (isActive) renderPreviewMessage('The reported preview path was rejected (must resolve to a location inside the project).');
    } else if (d.type === 'preview-no-session') {
      if (isActive) renderPreviewMessage('No active sprint session — start or resume the sprint, then try Preview again.');
    } else if (d.type === 'daemon-restarting') {
      // t-74d6: the stale daemon is exiting (its /shutdown returned 200). Give it
      // a moment to fully exit, then re-ensure — ensure_cockpit finds the old
      // daemon.json addr unhealthy, clears it, and launches a fresh build — and
      // remount the terminal at the new addr. A background tab just remembers it
      // needs a remount, applied next time it becomes active (see openCockpit).
      if (tab.iframeEl) tab.iframeEl.style.visibility = 'hidden';
      tab.addr = null;
      if (isActive) {
        setTermMessage('Restarting cockpit daemon…');
        setTimeout(() => {
          const ct = findTicketById(sourceId) || { id: sourceId, status: 'open' };
          maybeMountCockpitTerminal(ct);
        }, 500);
      } else {
        tab.pendingMessage = 'Restarting cockpit daemon…';
        tab.needsRemount = true;
      }
    }
  });

  document.getElementById('ck-leave-cancel').addEventListener('click', closeLeaveConfirm);

  document.getElementById('ck-leave-save').addEventListener('click', () => ckLeaveSaveAndEnd(false));
  document.getElementById('ck-leave-skip').addEventListener('click', () => ckLeaveSaveAndEnd(true));
  // t-86fe: Discard takes a second click — the first one says what it will do.
  document.getElementById('ck-leave-discard').addEventListener('click', (e) => {
    const btn = e.currentTarget;
    if (!btn.classList.contains('armed')) {
      const n = (cockpitState.leaveChanges && cockpitState.leaveChanges.total) || 0;
      btn.classList.add('armed');
      btn.textContent = btn.dataset.mode === 'restore' ? 'Replace my current files with the originals'
        : 'Discard ' + n + ' file' + (n === 1 ? '' : 's') + ' \u2014 can\u2019t be undone';
      return;
    }
    ckLeaveSaveAndEnd(true, btn.dataset.mode === 'restore' ? { restore: true } : { discard: true });
  });

  // t-0db3: Canon Cockpit shell → board control bridge. When this board is embedded
  // as a shell project tab, the shell's close-tab guard asks it to Save & End / End
  // the tab's live agent session. SAME-ORIGIN ONLY (the shell and this board are
  // served by the same board server; the daemon terminal is a DIFFERENT origin and
  // is handled by the daemon-iframe listener above). We only ever invoke the board's
  // own existing, vetted controls — this exposes NO new daemon capability.
  // t-416c: the first interaction inside a pane (a click, a key, or focus moving into its terminal frame) ends its pulse
  ['pointerdown', 'keydown'].forEach(function (t) { document.addEventListener(t, function () { delete document.documentElement.dataset.panePulse; }, true); });
  window.addEventListener('blur', function () { delete document.documentElement.dataset.panePulse; });
  window.addEventListener('message', (e) => {
    if (window.parent === window) return;                 // standalone board — no shell
    if (e.origin !== location.origin) return;             // reject cross-origin senders
    if (e.source !== window.parent) return;               // only our embedding shell
    const d = e.data;
    if (!d || d.source !== 'canon-cockpit-shell') return;
    if (d.type === 'open-ticket') {                        // t-2d2e: shell routed a cross-project Sessions row here
      if (typeof d.ticket === 'string' && COCKPIT_TICKET_ID.test(d.ticket)) openTicketWhenLoaded(d.ticket, 20);
      return;
    }
    if (d.type === 'end-session-request') {                // t-a198: prefix then e. Opens the existing confirmation for a LIVE session; never ends anything itself
      if (cockpitState && !cockpitState._ending && sessionIsLive()) openLeaveConfirm();
      return;
    }
    if (d.type === 'pane-state') {                         // t-416c: the shell says whether this board is a split pane, the focused one, and pulsing
      const root = document.documentElement;
      if (d.split === true) root.dataset.pane = d.focused === true ? 'focused' : 'idle'; else delete root.dataset.pane;
      if (d.split === true && d.pulse === true) root.dataset.panePulse = '1'; else delete root.dataset.panePulse;
      return;
    }
    if (d.type === 'focus-search') {                       // t-a198: prefix then /
      const s = document.getElementById('board-search');
      if (s) { s.focus(); s.select(); }
      return;
    }
    if (d.type === 'open-scratch') {                       // t-47f1: shell's "+ Scratch", or a scratch row reopened
      if (typeof d.id === 'string' && SCRATCH_ID.test(d.id)) openScratch(d.id);
      return;
    }
    if (d.type !== 'save-and-end' && d.type !== 'end') return;
    if (!cockpitState) return;                            // t-8a2a: no active tab — nothing to end
    if (cockpitState._ending) return;                     // t-9eda: already ending — ckLeaveSaveAndEnd would no-op anyway
    if (!sessionIsLive()) return;                         // nothing live to end (shell poller reconciles)
    openLeaveConfirm();                                   // reuse the vetted flow's state setup
    // end === skip the save turn; a scratch session (t-47f1) has no save turn at all
    ckLeaveSaveAndEnd(d.type === 'end' || SCRATCH_ID.test(cockpitState.id || ''));
  });
}
