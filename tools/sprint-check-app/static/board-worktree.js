import { state } from './board-core.js';
import { WT_PREF_MAIN, esc, escAttr, md, worktreeRun } from './board-helpers.js';
import { showToast } from './board-render.js';
import { activeIframe, cockpitState, missingTicketMessage, requestPreview, setButtonBusy, setTermMessage } from './board-cockpit.js';
import { closeCockpit, openCockpitDetails } from './board-cockpit-rail.js';
import { bindGithubPickerRows, ghOut, githubPickerRowsHTML, hideGithubPanel, showGithubPanel } from './board-github.js';

// t-ccd6: promise-returning confirm/notice in the board's own style. okOnly = a
// notice (resolves true on OK, false on Escape). Escape cancels, Enter confirms
// (a focused button handles its own Enter), focus returns to the opener.
let appDialogDismiss = null;
function appDialog({ title, body, okLabel = 'OK', cancelLabel = 'Cancel', okOnly = false }) {
  if (appDialogDismiss) appDialogDismiss(false);
  return new Promise(resolve => {
    const ov = document.getElementById('app-dialog');
    const ok = document.getElementById('app-dialog-ok');
    const cancel = document.getElementById('app-dialog-cancel');
    const opener = document.activeElement;
    document.getElementById('app-dialog-title').textContent = title;
    document.getElementById('app-dialog-body').textContent = body;
    ok.textContent = okLabel;
    cancel.textContent = cancelLabel;
    cancel.hidden = okOnly;
    const done = v => {
      appDialogDismiss = null;
      ov.classList.remove('open');
      document.removeEventListener('keydown', onKey, true);
      ok.onclick = cancel.onclick = null;
      if (opener && opener.focus) opener.focus();
      resolve(v);
    };
    const onKey = e => {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); done(false); }
      else if (e.key === 'Tab') {
        const order = okOnly ? [ok] : [ok, cancel];
        const i = order.indexOf(document.activeElement);
        e.preventDefault();
        order[(i + (e.shiftKey ? order.length - 1 : 1)) % order.length].focus();
      }
    };
    appDialogDismiss = done;
    ok.onclick = () => done(true);
    cancel.onclick = () => done(false);
    document.addEventListener('keydown', onKey, true);
    ov.classList.add('open');
    // Deferred: opened from an Enter keydown, a synchronous focus would send that
    // same keypress to the OK button and confirm the dialog it just opened.
    setTimeout(() => { if (appDialogDismiss === done) ok.focus(); }, 0);
  });
}

// t-ccd6: one place for the unlock request (the Unlock button and the switch
// dialog both use it). Resolves null on success, else the reason to show.
async function unlockTicketWorktree(ticketId) {
  try {
    const r = await fetch(`/api/worktree-unlock/${encodeURIComponent(ticketId)}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
    const d = await r.json().catch(() => ({}));
    if (!r.ok || !d.ok) return d && d.error ? d.error : `HTTP ${r.status}`;
    return null;
  } catch (err) { return String(err); }
}

// t-cd06: shared by every /api/worktree-lock caller below (init-selection,
// the switch-worktree confirm, and the Status line) — one fetch shape, one
// fail-safe default, so a request failure never silently degrades to
// "treat as unlocked" in one caller and "skip the check" in another.
export async function fetchWorktreeLock(ticketId) {
  try {
    const r = await fetch(`/api/worktree-lock/${encodeURIComponent(ticketId)}`);
    if (r.ok) return await r.json();
  } catch {}
  return { locked: false, cwd: null, main_dirty: null };
}

// t-cd06: WORKTREE accordion — single-select rows sourced live from
// `git worktree list --porcelain` (no cockpit-owned registry, per the
// ticket's resolved design), plus a "+ New" row that creates one. Only
// re-rendered on cockpit open, not on the 5s poll — the list rarely changes
// mid-session and re-rendering would clobber an in-progress "+ New" typing.
export async function renderCockpitWorktree(t) {
  const tab = cockpitState; // the tab being rendered — cockpitState may move to another tab across the awaits below
  // t-644a: hide the whole accordion section for a non-git project — same
  // live state.isGitProject check the New Ticket modal's Worktree row uses,
  // not cached at registration so it reappears once git init happens.
  const section = document.getElementById('ck-worktree-section');
  if (section) section.style.display = state.isGitProject ? '' : 'none';
  // t-d218: no worktree choice exists outside git, so there's nothing to pick — run in the project
  // itself. Leaving worktreeCwd null here gated Start forever with no rows to select.
  if (!state.isGitProject) { if (tab.worktreeCwd === null) tab.worktreeCwd = ''; return; }
  const box = document.getElementById('ck-worktree');
  let entries = [];
  try {
    const r = await fetch('/api/worktrees?ticket=' + encodeURIComponent(t.id));
    if (r.ok) entries = await r.json();
  } catch {}

  const rowHTML = (cwd, label, sub, extraAttr) => {
    // t-3e58: normalized compare (see selectCockpitWorktree) so a re-render keeps
    // the highlight even when worktreeCwd and this row's cwd differ in format.
    // t-470d: require an actual selection first — cockpitPathKey maps BOTH null
    // ("nothing picked yet", the fresh-OPEN sentinel maybeMountCockpitTerminal
    // gates on) and '' (the Main row) to '', so without the null guard the Main
    // row rendered selected on a fresh OPEN start while the terminal stayed gated
    // ("Select a worktree above") — a contradictory highlight. No row is selected
    // until worktreeCwd is set by selectCockpitWorktree (or the in_progress lock).
    const selected = cockpitState.worktreeCwd !== null && cockpitPathKey(cockpitState.worktreeCwd) === cockpitPathKey(cwd);
    return `<div class="ck-worktree-row${selected ? ' selected' : ''}" data-cwd="${esc(cwd)}"${extraAttr || ''}>
      <div class="ck-worktree-radio"></div>
      <div class="ck-worktree-labels">
        <div class="ck-worktree-label">${esc(label)}</div>
        ${sub ? `<div class="ck-worktree-sub">${esc(sub)}</div>` : ''}
      </div>
    </div>`;
  };

  const mainEntry = entries.find(e => e.is_main);
  const others = entries.filter(e => !e.is_main);

  // t-816e (deferred t-4272): resolve a locked cwd to a friendly label so the
  // Unlock button + confirm can NAME the worktree, not just show a raw path.
  // Matches by cockpitPathKey (symlink/format-robust, per t-3e58/t-eed3).
  const worktreeLabelForCwd = (cwd) => {
    if (!cwd) return 'a worktree';
    const key = cockpitPathKey(cwd);
    if (mainEntry && key === cockpitPathKey(mainEntry.path)) return 'Main checkout';
    const hit = others.find(e => cockpitPathKey(e.path) === key);
    if (hit) return hit.branch || '(detached)';
    return String(cwd).replace(/[\\/]+$/, '').split(/[\\/]/).pop() || cwd;
  };
  cockpitState.worktreeLabel = worktreeLabelForCwd;   // t-ccd6: selectCockpitWorktree names worktrees too

  // t-e5ff: track which worktree cwds can actually see the ticket. The daemon
  // reports tickets_visible=false for a non-main worktree when .tickets/ is
  // gitignored (git only materializes tracked files there). Default to visible
  // when the field is absent (older daemon) so we never over-block. The main
  // checkout uses cwd '' in this rail and is always visible.
  cockpitState.worktreeVisibleByCwd = {};
  cockpitState.worktreeVisibleByCwd[''] = !mainEntry || mainEntry.tickets_visible !== false;
  for (const e of others) cockpitState.worktreeVisibleByCwd[e.path] = e.tickets_visible !== false;
  const anyBlocked = others.some(e => e.tickets_visible === false);

  // t-2a1c: physical presence of .tickets/<id> per worktree (ticket-scoped),
  // mirroring the daemon's own handleStart stat. This is the accurate signal
  // the daemon actually guards on — stricter than the project-level
  // check-ignore `tickets_visible` above, and it catches the un-ignored-but-
  // uncommitted case that check-ignore reports as "visible". Default to present
  // when the field is absent (older backend that doesn't report it) so we never
  // over-block. Main ('') always holds .tickets/ (daemon exempts it).
  cockpitState.worktreePresentByCwd = {};
  cockpitState.worktreePresentByCwd[''] = true;
  for (const e of others) cockpitState.worktreePresentByCwd[e.path] = e.ticket_present !== false;
  cockpitState.worktreeMainPath = mainEntry ? mainEntry.path : null;
  cockpitState.worktreeMainBranch = mainEntry ? mainEntry.branch : null; // t-d254: named in the missing-ticket fix-up

  // t-cd06: an already-locked in_progress ticket's real worktree must show
  // as selected here — the daemon uses the locked cwd regardless of what's
  // displayed, so defaulting the picker to Main checkout on every reopen was
  // actively misleading about which directory the session actually runs in.
  // t-f15b: cockpitPathKey (not raw ===) — lock.cwd is daemon-native (backslashes
  // on Windows), mainEntry.path is git's own forward-slash-normalized report;
  // a raw compare silently fails on Windows and left the Main row unselected.
  let lock = { locked: false, cwd: null };
  if (t.status === 'in_progress') {
    lock = await fetchWorktreeLock(t.id);
    if (lock.locked && lock.cwd) {
      cockpitState.worktreeCwd = (mainEntry && cockpitPathKey(lock.cwd) === cockpitPathKey(mainEntry.path)) ? '' : lock.cwd;
    }
  }
  // t-2a1c: remember the lock so maybeMountCockpitTerminal can gate on the
  // EFFECTIVE run cwd (the daemon reuses this locked cwd and ignores the picker).
  cockpitState.worktreeLock = lock;

  // t-644a: pre-fill from a worktree_preference declared at New Ticket time —
  // only when not already locked (a real binding always wins) and nothing has
  // been explicitly picked yet this session. If the preference matches an
  // EXISTING worktree, pre-select that row; otherwise it names a branch that
  // doesn't exist yet, so pre-fill the +New input instead of pre-selecting a
  // row that isn't there. An absent preference changes nothing (existing gate
  // behavior: nothing pre-selected until the user picks).
  // t-644a fix: line 5075 sets worktreeCwd='' (Main) for every non-open
  // ticket before this function runs, so a `worktreeCwd === null` guard here
  // never fires for the common unlocked-in_progress case (a board-side status
  // flip that hasn't gone through tkt's in_progress write, so no
  // .cockpit-cwd exists yet) — gate on the lock itself instead.
  let wtNewDefault = `sprint/${t.id}`;
  // t-15ee: an explicit choice from New Ticket that has no worktree yet — a stated intent, unlike
  // the default `sprint/<id>` suggestion — so "+ New" starts enabled (still behind a confirm).
  let wtPrefPending = '';
  const running = worktreeRun(t);
  const runRow = running ? others.find(e => e.branch === running.branch) : null;
  if (!lock.locked && runRow) {
    // t-19d1: the sprint is already in progress in this worktree (see worktreeRun) — Resume goes there.
    if (cockpitState.worktreeCwd === null) cockpitState.worktreeCwd = runRow.path;
  } else if (!lock.locked && t.worktree_preference === WT_PREF_MAIN) {
    // t-19d1: the ticket chose Main checkout at New Ticket — preselect it.
    if (cockpitState.worktreeCwd === null && !tab.ghPick) cockpitState.worktreeCwd = '';
  } else if (!lock.locked && t.worktree_preference && !tab.ghPick) {   // a GitHub pick selects no worktree row
    const match = others.find(e => e.branch === t.worktree_preference && !e.held_by); // t-2241: never preselect a worktree another ticket holds
    if (match) cockpitState.worktreeCwd = match.path;
    else {
      wtNewDefault = t.worktree_preference;
      // Arm only when the list really loaded (a failed fetch leaves it empty) and the choice isn't the
      // main checkout's own branch — otherwise the click could only end in an "already exists" alert.
      if (mainEntry && mainEntry.branch !== t.worktree_preference) wtPrefPending = t.worktree_preference;
    }
  }
  // t-19d1: no preference and the main checkout is the only worktree — there's no real choice to
  // protect (t-cd06/t-470d's explicit pick guards against the WRONG checkout), so preselect Main.
  // A GitHub pick (t-718b) leaves worktreeCwd null on purpose: that is not "nothing picked yet".
  if (!lock.locked && !t.worktree_preference && mainEntry && others.length === 0 && cockpitState.worktreeCwd === null && !tab.ghPick) {
    cockpitState.worktreeCwd = '';
  }
  tab.wtPrefPending = wtPrefPending;

  // t-2241: rows only for worktrees this ticket can use — Main, its own, and free
  // ones. Worktrees another ticket still needs (server `held_by`) collapse into one
  // unselectable "N worktrees unavailable" group (reasons per row). Once the ticket's
  // own worktree is selected, show just that
  // row + "Change worktree"; the full picker stays in the DOM (hidden) so every
  // handler below wires up unchanged.
  const held = others.filter(e => e.held_by);
  const usable = others.filter(e => !e.held_by);
  const ownSelected = tab.worktreeCwd
    ? usable.find(e => e.own && cockpitPathKey(e.path) === cockpitPathKey(tab.worktreeCwd)) : null;
  const compact = !!ownSelected && !tab.wtShowAll;
  let html = `<div class="ck-worktree-active-note" id="ck-worktree-note"></div>`;
  if (compact) {
    html += rowHTML(ownSelected.path, ownSelected.branch || '(detached)', ownSelected.path);
    html += `<button type="button" class="ck-worktree-change" id="ck-worktree-change">Change worktree</button>`;
  }
  html += `<div class="ck-worktree-full"${compact ? ' hidden' : ''}>`;
  html += rowHTML('', 'Main checkout (current)', mainEntry ? mainEntry.path : '');
  for (const e of usable) {
    if (!compact || e !== ownSelected) html += rowHTML(e.path, e.branch || '(detached)', e.path); // compact already shows it above
  }
  if (held.length) {
    html += `<details class="ck-worktree-held"><summary>${held.length} worktree${held.length === 1 ? '' : 's'} unavailable</summary>`
      + held.map(e => `<div class="ck-worktree-held-row" data-branch="${escAttr(e.branch || '')}">
          <span class="ck-worktree-held-branch">${esc(e.branch || '(detached)')}</span>
          <span class="ck-worktree-held-why">${esc(e.held_by.ticket ? e.held_by.ticket + ' · ' : '')}${esc(e.held_by.reason || '')}${e.held_by.reason === 'folder missing' ? ' — run <code>git worktree prune</code>' : ''}</span>
        </div>`).join('')
      + `</details>`;
  }
  html += githubPickerRowsHTML(t, tab);   // t-718b: GitHub places (busy GitHub #N rows, and GitHub · new issue)
  html += `<div class="ck-worktree-new">
    <button type="button" class="ck-worktree-new-plus" title="Create a worktree for the branch named here (asks to confirm)">+ New</button>
    <input id="ck-worktree-new-input" value="${esc(wtNewDefault)}" spellcheck="false" autocomplete="off">
  </div>
  <div class="ck-add-hint">${wtPrefPending
    ? `You chose <b>${esc(wtPrefPending)}</b> when creating this ticket — click + New to create it (you'll be asked to confirm), or pick Main checkout.`
    : 'Click + New (or press Enter) to create this worktree — you\'ll be asked to confirm. Edit the name first to use a different branch.'}</div>`;
  if (anyBlocked) {
    html += `<div class="ck-worktree-warn" role="alert">
      <strong>.tickets/ is gitignored</strong> — a git worktree only carries tracked files, so a worktree can't see this ticket and a sprint started there can't find it. Use the <strong>Main checkout</strong>, or track <code>.tickets/</code> in git.
    </div>`;
  }
  // t-d254: a worktree only carries committed files. Warn before any click when
  // the ticket's own docs are uncommitted (runtime logs alone don't count), and
  // let + New offer to commit them. A failed or 400 lookup (e.g. a non-canon id)
  // leaves commitPlan null → today's plain confirm, never a false warning.
  let commitPlan = null;
  try {
    const r = await fetch('/api/ticket-commit/' + encodeURIComponent(t.id));
    if (r.ok) commitPlan = await r.json();
  } catch {}
  const needsCommit = !!(commitPlan && !commitPlan.blocked && Array.isArray(commitPlan.required) && commitPlan.required.length);
  // t-165f: with the Main checkout row selected the session reads .tickets/ straight from the folder, so nothing is
  // missing and the box would read as an action to take; + New still offers the commit (needsCommit below).
  // Rendered hidden for Main and flipped by selectCockpitWorktree, since a row click does not re-render the rail.
  if (needsCommit) {
    const hideForMain = tab.worktreeCwd === '' ? ' hidden' : '';
    // t-b59d: a ticket already in HEAD only lags: a new worktree gets its last committed version, it is not
    // missing. Only an explicit ticket_in_head === true takes the new wording; a server without the field
    // keeps the old sentence.
    html += commitPlan.ticket_in_head === true
      ? `<div class="ck-worktree-warn" id="ck-worktree-uncommitted" role="status"${hideForMain}>
      <strong>${esc(t.id)} has uncommitted changes</strong> — a new worktree gets its last committed version. + New will offer to commit them first.
    </div>`
      : `<div class="ck-worktree-warn" id="ck-worktree-uncommitted" role="status"${hideForMain}>
      <strong>${esc(t.id)} isn't committed yet</strong> — a new worktree won't contain it. + New will offer to commit it first.
    </div>`;
  }
  html += `</div>`; // .ck-worktree-full
  // t-fe3c: when the ticket is locked to a worktree, offer to clear that lock so
  // the next Start/Resume uses the picked worktree (the daemon otherwise reuses
  // the saved cwd and ignores the picker). Confirmed with an explanation on click.
  if (lock.locked) {
    // t-816e: name the locked worktree on the button itself, not just in a hover title.
    const lockedLabel = worktreeLabelForCwd(lock.cwd);
    const lockedLabelAttr = esc(lockedLabel);   // esc() is attribute-safe since t-d2e1 (t-816e had quote-escaped it here)
    html += `<button type="button" class="ck-worktree-unlock" id="ck-worktree-unlock" title="This ticket is locked to ${lockedLabelAttr} — clear the saved worktree so the next Start/Resume uses the one you pick">Unlock worktree (${esc(lockedLabel)})</button>`;
  }
  box.innerHTML = html;
  updateWorktreeNote();
  document.getElementById('ck-worktree-change')?.addEventListener('click', () => {
    tab.wtShowAll = true;
    renderCockpitWorktree(t);
  });

  const ownKeys = new Set(usable.filter(e => e.own).map(e => cockpitPathKey(e.path)));
  // t-24b1: the GitHub place row may still read "checking…"; board-github binds it, now or once the doctor answers.
  bindGithubPickerRows(box, tab, row => {
    // t-718b: GitHub is a place with no local session: no worktree is selected and the terminal never mounts.
    tab.ghPick = true;
    tab.worktreeCwd = null;
    box.querySelectorAll('.ck-worktree-row').forEach(r => r.classList.toggle('selected', r === row));
    updateWorktreeNote();
    maybeMountCockpitTerminal(t);
  });
  box.querySelectorAll('.ck-worktree-row:not([data-github])').forEach(row => {
    row.addEventListener('click', async () => {
      await selectCockpitWorktree(t, row.dataset.cwd);
      // t-2241: picking the ticket's own worktree collapses the picker to it. Re-check the
      // selection after the await — selectCockpitWorktree may have refused (locked ticket).
      if (ownKeys.has(cockpitPathKey(row.dataset.cwd)) && cockpitPathKey(tab.worktreeCwd || '') === cockpitPathKey(row.dataset.cwd)) {
        tab.wtShowAll = false;
        renderCockpitWorktree(t);
      }
    });
  });
  const unlockBtn = document.getElementById('ck-worktree-unlock');
  if (unlockBtn) {
    unlockBtn.addEventListener('click', async () => {
      // t-816e: name the worktree (branch label) alongside the raw path.
      const lockedLabel = worktreeLabelForCwd(lock.cwd);
      const lockedPath = lock.cwd || 'a worktree';
      const msg = `This ticket is locked to:\n\n  ${lockedLabel} (${lockedPath})\n\n`
        + `The cockpit reuses that directory for every Start/Resume and ignores the worktree selected here. `
        + `Unlocking clears the saved worktree AND the saved session, so the next Start begins a `
        + `fresh session in the worktree you pick next (e.g. the Main checkout) — it does not resume `
        + `the current conversation in a different directory. `
        + `A currently-running session keeps its directory until it ends.`;
      if (!await appDialog({ title: "Unlock this ticket's worktree?", body: msg, okLabel: 'Unlock' })) return;
      const unlockErr = await unlockTicketWorktree(t.id);
      if (unlockErr) { await appDialog({ title: 'Could not unlock', body: unlockErr, okOnly: true }); return; }
      // Lock cleared → drop the stale pre-selection, re-render (picker + t-e5ff
      // bubble re-evaluate), and refresh the terminal panel to the new state.
      cockpitState.worktreeCwd = null;
      await renderCockpitWorktree(t);
      maybeMountCockpitTerminal(t);
    });
  }
  const input = document.getElementById('ck-worktree-new-input');
  const btn = box.querySelector('.ck-worktree-new-plus');
  // Branch names already visible as a row — block resubmitting one of these
  // before it ever reaches the confirm dialog, rather than letting the
  // server's "path already exists" round-trip surface as a generic alert.
  const existingBranches = new Set(others.map(e => e.branch).filter(Boolean));
  // t-29cc: one rule for click and Enter, the untouched suggestion included —
  // create()'s confirm dialog is the guard against an unwanted worktree. The main
  // checkout's branch is excluded too: it's never a row in `others`, and a
  // `main` preference pre-fills it (git refuses a second checkout of it).
  const mainBranch = mainEntry ? mainEntry.branch : '';
  const canCreate = v => v.length > 3 && !existingBranches.has(v) && v !== mainBranch;
  btn.disabled = !canCreate(input.value.trim());
  input.addEventListener('focus', () => input.select());
  input.addEventListener('input', () => {
    btn.disabled = !canCreate(input.value.trim());
  });
  const create = async () => {
    const branch = input.value.trim();
    if (branch.length <= 3 || branch === mainBranch) return;
    if (existingBranches.has(branch)) {
      const h = held.find(e => e.branch === branch);
      await appDialog({ title: `Can't create "${branch}"`, okOnly: true, body: h && h.held_by.reason === 'folder missing'
        ? `"${branch}" has a stale worktree entry (its folder is gone). Run "git worktree prune" in the project, or pick another name.`
        : h
        ? `"${branch}" is in use by ${h.held_by.ticket || 'another ticket'} (${h.held_by.reason}) — pick another name.`
        : `"${branch}" already has a worktree — select it from the list above instead.` });
      return;
    }
    if (needsCommit) {
      if (await openTicketCommitDialog(t.id, commitPlan, branch) === 'cancel') return;
    } else if (!await appDialog({ title: 'Create a new worktree?', body: `Create a new git worktree for branch "${branch}"?`, okLabel: 'Create worktree' })) return;
    input.disabled = true;
    btn.disabled = true;
    setButtonBusy(btn, 'Creating…');
    try {
      const r = await fetch('/api/worktrees', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ branch })
      });
      const d = await r.json();
      if (!r.ok || !d.ok) {
        await appDialog({ title: 'Could not create worktree', body: d && d.error ? d.error : `HTTP ${r.status}`, okOnly: true });
        setButtonBusy(btn, null, '+ New');
        input.disabled = false;
        btn.disabled = false;
        return;
      }
      await renderCockpitWorktree(t);
      // t-3e58: select via the matching rendered row's own data-cwd (resolved by
      // normalized key) so cockpitState.worktreeCwd holds the canonical value a
      // manual click would set — the POST create-response d.path may differ in
      // format from the GET-list data-cwd on Windows.
      const createdKey = cockpitPathKey(d.path);
      const createdRow = [...document.querySelectorAll('#ck-worktree .ck-worktree-row')]
        .find(row => cockpitPathKey(row.dataset.cwd) === createdKey);
      selectCockpitWorktree(t, createdRow ? createdRow.dataset.cwd : d.path);
    } catch (err) {
      await appDialog({ title: 'Could not create worktree', body: String(err), okOnly: true });
      setButtonBusy(btn, null, '+ New');
      input.disabled = false;
      btn.disabled = false;
    }
  };
  btn.addEventListener('click', create);
  input.addEventListener('keydown', (e) => { if (e.key === 'Enter') create(); });
}

// t-d254: the commit-first dialog. Lists the server's classification — Required
// (checked, locked), Recommended (checked), Optional (unchecked), and other
// uncommitted files (listed, never committed) — and on "Commit & create" posts
// the checked paths. The server re-derives eligibility, so this list is only a
// request. File names are inserted as text nodes (no HTML), so a hostile name is
// inert. Resolves 'committed' | 'cancel'. There is deliberately no "create without
// committing": that worktree couldn't see the ticket, so Start would stay disabled
// (user, 2026-09-25) — to commit another way, Cancel and commit by hand.
function openTicketCommitDialog(ticketId, plan, branch) {
  const overlay = document.getElementById('ck-tcommit');
  const files = document.getElementById('ck-tcm-files');
  const status = document.getElementById('ck-tcm-status');
  const commitBtn = document.getElementById('ck-tcm-commit');
  const cancelBtn = document.getElementById('ck-tcm-cancel');
  document.getElementById('ck-tcm-intro').textContent =
    `A worktree only contains committed files, and ${ticketId} isn't fully committed. ` +
    `Commit it on the main checkout first, then create the "${branch}" worktree.`;
  const msg = document.getElementById('ck-tcm-msg');
  msg.textContent = 'Commit message: ';
  const code = document.createElement('code');
  code.textContent = plan.message || '';
  msg.appendChild(code);
  status.textContent = '';
  files.textContent = '';
  const group = (title, paths, mode) => {
    if (!paths || !paths.length) return;
    const g = document.createElement('div');
    g.className = 'ck-tcm-group';
    const h = document.createElement('div');
    h.className = 'ck-tcm-group-title';
    h.textContent = title;
    g.appendChild(h);
    for (const p of paths) {
      const row = document.createElement('label');
      row.className = 'ck-tcm-file' + (mode === 'list' ? ' muted' : '');
      if (mode !== 'list') {
        const cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.dataset.path = p;
        cb.checked = mode !== 'optional';
        cb.disabled = mode === 'required';
        row.appendChild(cb);
      }
      row.appendChild(document.createTextNode(p));
      g.appendChild(row);
    }
    files.appendChild(g);
  };
  group('Required — the ticket itself', plan.required, 'required');
  group('Recommended — canon’s ignore rules', plan.recommended, 'recommended');
  group('Optional — per-machine session logs', plan.optional, 'optional');
  const others = plan.other_dirty || [];
  const more = (plan.other_dirty_count || 0) - others.length;
  group(`Also uncommitted — not included${more > 0 ? ` (+${more} more)` : ''}`, others, 'list');
  overlay.classList.add('open');
  commitBtn.focus();
  return new Promise(resolve => {
    const done = (result) => {
      overlay.classList.remove('open');
      commitBtn.onclick = cancelBtn.onclick = null;
      overlay.onkeydown = null;
      resolve(result);
    };
    const setBusy = (busy) => { commitBtn.disabled = cancelBtn.disabled = busy; };
    commitBtn.onclick = async () => {
      const paths = [...files.querySelectorAll('input[type=checkbox]')].filter(cb => cb.checked).map(cb => cb.dataset.path);
      setBusy(true);
      setButtonBusy(commitBtn, 'Committing…');
      status.textContent = '';
      try {
        const r = await fetch('/api/ticket-commit/' + encodeURIComponent(ticketId), {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ paths }),
        });
        const d = await r.json().catch(() => ({}));
        if (!r.ok || !d.ok) {
          status.textContent = 'Commit failed: ' + (d && d.error ? d.error : `HTTP ${r.status}`);
          setButtonBusy(commitBtn, null, 'Commit & create worktree');
          setBusy(false);
          return;
        }
        showToast(`✓ Committed ${d.commit} — ${d.message}`, 'warn');
        setButtonBusy(commitBtn, null, 'Commit & create worktree');
        setBusy(false);
        done('committed');
      } catch (err) {
        status.textContent = 'Commit failed: ' + err;
        setButtonBusy(commitBtn, null, 'Commit & create worktree');
        setBusy(false);
      }
    };
    cancelBtn.onclick = () => done('cancel');
    overlay.onkeydown = (e) => { if (e.key === 'Escape' && !cancelBtn.disabled) done('cancel'); };
  });
}

// t-cd06 amendment: an in_progress ticket's FIRST worktree pick (no
// .cockpit-cwd yet) silently locks in a directory its prior conversation
// turns never saw, and a worktree checkout only carries committed history —
// warn once, here, before that choice takes effect. A fresh OPEN ticket has
// no prior conversation state to lose, and a ticket that's already locked
// can't be redirected anyway (the daemon ignores the requested cwd), so
// neither case needs the confirm.
async function selectCockpitWorktree(t, cwd) {
  if (t.status === 'in_progress') {
    // Fail SAFE, not open: fetchWorktreeLock defaults to unlocked/unknown-dirty
    // on any error, so a fetch failure still warns rather than silently
    // skipping the confirm at exactly the moment it can't be verified.
    const lock = await fetchWorktreeLock(t.id);
    const labelOf = cockpitState.worktreeLabel;
    const wtLabel = cwd === '' ? 'the Main checkout' : labelOf(cwd);
    const risk = lock.main_dirty === true
      ? 'The main checkout has uncommitted changes that will NOT carry over — a worktree only has committed history.'
      : lock.main_dirty === false
        ? 'A worktree only has this repo\'s committed history — any future uncommitted work in the main checkout will not be shared with it.'
        : 'A worktree only has this repo\'s committed history — uncommitted work does not carry over between checkouts.';
    if (lock.locked) {
      // t-9203: while locked, the daemon reuses the locked cwd and IGNORES the
      // picker, so a different pick must clear the lock first. t-ccd6: one
      // confirm does both — it names the lock, then unlocks and selects.
      // cockpitState.worktreeCwd was set to the effective locked cwd on render,
      // so any different pick is a real switch.
      if (cwd !== cockpitState.worktreeCwd) {
        if (!await appDialog({
          title: `Switch this ticket to ${wtLabel}?`,
          body: `This ticket is locked to:\n\n  ${lock.cwd ? `${labelOf(lock.cwd)} (${lock.cwd})` : 'a worktree'}\n\n`
            + `Switching clears that lock and the saved session, so the next Start begins a fresh session in ${wtLabel} — it does not resume the current conversation there. `
            + `A currently-running session keeps its directory until it ends.`
            + (cwd !== '' ? `\n\n${risk}` : ''),
          okLabel: 'Switch'
        })) return;
        const unlockErr = await unlockTicketWorktree(t.id);
        if (unlockErr) { await appDialog({ title: 'Could not switch', body: unlockErr, okOnly: true }); return; }
        cockpitState.worktreeCwd = null;
        await renderCockpitWorktree(t);
      }
    } else if (cwd !== '') {
      if (!await appDialog({ title: `Use ${wtLabel} for this ticket?`, body: `${risk}\n\nThis also locks this ticket to that worktree for every future Resume.`, okLabel: 'Continue' })) return;
    }
  }
  cockpitState.worktreeCwd = cwd;
  cockpitState.ghPick = false;   // t-718b: a local place replaces a GitHub pick
  document.querySelectorAll('#ck-worktree .ck-worktree-row').forEach(row => {
    // t-3e58: compare by normalized key, not raw ===. The create-response path
    // and the rendered data-cwd can differ in format on Windows (\ vs /, case,
    // trailing sep), so an exact match misses and the new row never highlights.
    // t-718b: a GitHub row has no folder (no data-cwd); it must never match Main's '' and light up with it.
    row.classList.toggle('selected', !row.dataset.github && cockpitPathKey(row.dataset.cwd) === cockpitPathKey(cwd));
  });
  const uncommittedBox = document.getElementById('ck-worktree-uncommitted');   // t-165f
  if (uncommittedBox) uncommittedBox.hidden = cwd === '';
  updateWorktreeNote();
  maybeMountCockpitTerminal(t);
}

// Subtle reminder of which worktree the session actually runs in, since the
// radio selection alone is easy to miss when scanning back to this rail.
function updateWorktreeNote() {
  const note = document.getElementById('ck-worktree-note');
  if (!note) return;
  const selectedLabel = document.querySelector('#ck-worktree .ck-worktree-row.selected .ck-worktree-label');
  note.textContent = selectedLabel ? `Working in: ${selectedLabel.textContent}` : '';
}

// t-7590: normalize a filesystem path for comparison across the daemon
// (EvalSymlinks output, native separators) and the board's own `git worktree
// list` — Windows mixes `\` and `/` and is case-insensitive, so compare on a
// lowercased, forward-slashed, trailing-slash-stripped key.
export function cockpitPathKey(p) {
  if (!p) return '';
  return String(p).replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase();
}

// t-1da3: forward-slash a real path VALUE (not a comparison key — no
// lowercasing/trailing-slash-stripping, both wrong for something that will
// actually be sent as a path). Worktree cwd values are already forward-slash
// by construction (git worktree list --porcelain's own output format,
// the board's worktree list); state.gitRoot (Main checkout) is the one source that isn't
// — the board reports it with native OS separators on Windows. The
// daemon's cwdPrefillRe (main.go, t-7590) deliberately assumes every cwd it
// receives is already forward-slashed; this is what keeps that true.
export function cockpitForwardSlash(p) {
  return p ? String(p).replace(/\\/g, '/') : p;
}

// t-7590: after a real Start, set "Working in:" from the cwd the DAEMON actually
// resolved (echoed by /session/start), not the optimistic pre-Start selection.
// If the resolved cwd doesn't match the worktree row the user picked, show a
// loud mismatch warning instead of silently claiming the wrong tree — the whole
// point of the ticket (a locked/stale .cockpit-cwd or an empty request can send
// the session somewhere other than the selection).
export function applyActualWorkingCwd(cwd, requested) {
  const note = document.getElementById('ck-worktree-note');
  if (!note) return;
  cockpitState.actualCwd = cwd || '';
  const mainKey = cockpitPathKey(cockpitState.worktreeMainPath || '');
  const actualKey = cockpitPathKey(cwd);
  // Resolve a human label: match a rendered row by its data-cwd, else fall back
  // to the path's basename; main resolves to the main-checkout row label.
  let label = '';
  const rows = document.querySelectorAll('#ck-worktree .ck-worktree-row');
  for (const row of rows) {
    const rowKey = cockpitPathKey(row.dataset.cwd || (row.dataset.cwd === '' ? cockpitState.worktreeMainPath : ''));
    if ((row.dataset.cwd === '' && actualKey === mainKey) || (row.dataset.cwd && rowKey === actualKey)) {
      const lbl = row.querySelector('.ck-worktree-label');
      if (lbl) label = lbl.textContent;
      break;
    }
  }
  if (!label) label = (actualKey === mainKey) ? 'Main checkout' : (String(cwd).replace(/[\\/]+$/, '').split(/[\\/]/).pop() || cwd);

  // Expected = the currently-selected row's cwd (worktreeCwd: '' means main).
  const selKey = cockpitState.worktreeCwd === '' ? mainKey : cockpitPathKey(cockpitState.worktreeCwd);
  // t-eed3: the daemon echoes `requested` = the RESOLVED (EvalSymlinks'd) form of
  // what the board asked for; JS can't resolve symlinks, so compare the actual
  // cwd against it too. Warn only when the actual differs from BOTH the selected
  // worktree AND the daemon-resolved requested — a symlink-only difference (same
  // real dir, e.g. /tmp vs /private/tmp) then matches `requested` and is
  // suppressed, while a genuine wrong-tree run still warns. Absent `requested`
  // (older daemon, or a direct caller) falls back to selKey — exact prior behavior.
  const reqKey = (requested == null) ? selKey : cockpitPathKey(requested);
  if (actualKey && selKey && actualKey !== selKey && actualKey !== reqKey) {
    note.innerHTML = `Working in: <strong>${esc(label)}</strong>`
      + `<div class="ck-worktree-warn">⚠ The session is running in <code>${esc(cwd)}</code>, `
      + `not the worktree you selected. Kill it, then Unlock and pick the worktree again to redirect.</div>`;
  } else {
    note.textContent = `Working in: ${label}`;
  }
}

// The ticket id/title prefix is already shown in the ck-ticket-card above —
// drop it here. HANDOFF.md's own line breaks are just ~80-col source
// wrapping for editing, not semantic paragraphs — collapse them, then split
// into real sentences so this doesn't render as one dense wrapped blob.
export function formatStateAsParagraphs(bullet, t) {
  const withoutPrefix = bullet.replace(/^-\s+(\*\*[^*]*\*\*\s*)?(\([^)]*\)\s*)?[—-]\s*/, '');
  const flat = withoutPrefix.replace(/\s+/g, ' ').trim();
  const sentences = flat.split(/(?<=[.:])\s+(?=[A-Z0-9`$<])/g).filter(Boolean);
  return sentences.map(s => `<p>${md(s, t.id)}</p>`).join('');
}

// t-cd06: a fresh OPEN start gates the terminal behind an explicit WORKTREE
// row pick (cockpitState.worktreeCwd === null means nothing picked yet) — the
// terminal is where the daemon's own Start control lives, so not mounting it
// yet is what "Start sprint stays disabled" means in practice. A Resume
// mounts immediately: the daemon reuses its persisted cwd for an in_progress
// ticket regardless of what the board sends.
export async function maybeMountCockpitTerminal(t) {
  const iframe = activeIframe();
  if (t.scratch) { hideGithubPanel(); await mountCockpitTerminal(t, ''); return; }   // t-47f1: always the main checkout
  // t-718b: a GitHub pick, or a ticket already out on GitHub, never mounts the terminal: the rail shows the GitHub panel.
  if (cockpitState.ghPick || ghOut(t)) {
    if (iframe) iframe.style.visibility = 'hidden';
    setTermMessage('');
    await showGithubPanel(t, cockpitState);
    return;
  }
  hideGithubPanel();
  if (cockpitState.worktreeCwd === null) {
    iframe.style.visibility = 'hidden';
    setTermMessage(cockpitState.wtPrefPending
      ? `Select a worktree above to continue. You chose "${cockpitState.wtPrefPending}" when creating this ticket — click + New to create it, or pick Main checkout. Start sprint is disabled until a row is selected.`
      : 'Select a worktree above to continue — Start sprint is disabled until a row is selected.');
    return;
  }
  // t-2a1c: gate on the EFFECTIVE run cwd, not just the selected row. For a
  // locked in_progress ticket the daemon reuses .cockpit-cwd and ignores the
  // picker (t-cd06), then refuses to start unless .tickets/<id> is physically
  // present there (handleStart). Mirror that here so a doomed Start button
  // never appears: if the effective cwd can't see the ticket, don't mount.
  const lock = cockpitState.worktreeLock || { locked: false, cwd: null };
  const isLocked = !!(lock.locked && lock.cwd && t.status === 'in_progress');
  let effectiveCwd = cockpitState.worktreeCwd;
  if (isLocked) {
    const mainPath = cockpitState.worktreeMainPath;
    // t-f15b: cockpitPathKey compare (raw === silently fails on Windows — see
    // renderCockpitWorktree's identical fix above for the full why).
    effectiveCwd = (mainPath && cockpitPathKey(lock.cwd) === cockpitPathKey(mainPath)) ? '' : lock.cwd;
  }
  const presentByCwd = cockpitState.worktreePresentByCwd || {};
  if (presentByCwd[effectiveCwd] === false) {
    iframe.style.visibility = 'hidden';
    setTermMessage(isLocked
      ? "This ticket is locked to a worktree that doesn't contain it, so a Start here would fail — Start sprint is disabled. Click \u201CUnlock worktree\u201D above to run in the Main checkout, or commit .tickets/ into that worktree."
      : missingTicketMessage(t.id, effectiveCwd, cockpitState.worktreeMainBranch));
    return;
  }
  // t-e5ff: fallback for an older backend that doesn't report ticket_present —
  // the project-level check-ignore signal still blocks a gitignored .tickets/.
  const visByCwd = cockpitState.worktreeVisibleByCwd || {};
  if (visByCwd[cockpitState.worktreeCwd] === false) {
    iframe.style.visibility = 'hidden';
    setTermMessage(".tickets/ is gitignored, so this worktree can't see the ticket — Start sprint is disabled here. Use the Main checkout, or track .tickets/ in git.");
    return;
  }
  await mountCockpitTerminal(t, cockpitState.worktreeCwd);
}

export async function mountCockpitTerminal(t, cwd) {
  const iframe = activeIframe();
  setTermMessage('Starting the cockpit daemon…');
  iframe.style.visibility = 'hidden';
  let addr = null, err = '';
  try {
    const r = await fetch('/api/cockpit', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
    const d = await r.json();
    if (d && d.running && d.addr) {
      addr = d.addr;
      // t-74d6: the board detects a version-drifted daemon (running exec-mtime
      // vs on-disk binary); relay it to the cockpit page for the stale banner.
      cockpitState.buildInfo = { stale: !!d.stale, running_build: d.running_build || null, latest_build: d.latest_build || null };
    } else err = (d && d.error) || 'daemon unavailable';
  } catch { err = 'request failed'; }
  if (!addr) {
    setTermMessage('Could not start the cockpit daemon (' + err + '). Run canon update to fetch it, then retry.');
    iframe.style.visibility = 'hidden';
    return;
  }
  cockpitState.addr = addr;
  // Never autostart: the terminal always loads idle with Start sprint pulsing,
  // for both a fresh OPEN ticket and a Resume — a launch should always be a
  // deliberate click, not something that fires the moment the panel opens.
  let url = `http://${addr}/cockpit?ticket=${encodeURIComponent(t.id)}&embed=1&autostart=0`;
  // t-fc91: a shared daemon (t-391a) resolves an empty cwd to ITS launch project,
  // not this board's — so the Main checkout ('') must name this board's own project
  // root, else a second project's ticket resolves against the wrong project ("ticket
  // not found") and would spawn in the wrong directory. Worktrees pass their own path.
  let effectiveCwd = cwd || state.gitRoot;
  if (!effectiveCwd) {
    // t-0a73: state.gitRoot can be stale/empty here — e.g. loadData()'s catch
    // branch silently substitutes MOCK.git (no `root` field) on ANY transient
    // fetch failure, live-reproduced right after a fresh daemon/board restart.
    // Never trust a cached value for an operation this consequential (spawning
    // a real agent) — verify fresh, right at the point of use, before falling
    // back to the dangerous empty-string shortcut.
    try {
      const gr = await fetch('/api/git');
      const gd = await gr.json();
      if (gd && gd.root) {
        effectiveCwd = cockpitForwardSlash(gd.root);
        state.gitRoot = effectiveCwd; // benefits any later call in this session too
      }
    } catch { /* fall through to the fail-safe below */ }
  }
  if (!effectiveCwd) {
    // Fail safe, not fail open: sending '' here would resolve against the
    // shared daemon's arbitrary launch-time project (t-fc91), not this one —
    // silently reintroducing the exact bug this check exists to prevent.
    setTermMessage("Could not verify this project's root — check your connection and try again.");
    iframe.style.visibility = 'hidden';
    return;
  }
  // t-29fb: a locked ticket's cwd is daemon-native (.cockpit-cwd, backslashes on Windows) and the daemon's cwdPrefillRe
  // drops a backslash path to "" (then runs from its launch folder: "ticket not found") — send the forward-slashed form.
  url += `&cwd=${encodeURIComponent(cockpitForwardSlash(effectiveCwd))}`;
  // t-74d6: once the cockpit page loads, relay the daemon build status so it can
  // render (or hide) the stale banner. Sent on load so the listener is ready.
  const bi = cockpitState.buildInfo || { stale: false, running_build: null, latest_build: null };
  iframe.onload = () => { try { iframe.contentWindow.postMessage({ source: 'canon-cockpit', type: 'daemon-build', info: bi }, 'http://' + addr); } catch (e) {} };
  iframe.src = url;
  iframe.style.visibility = 'visible';
  setTermMessage('');
}

// t-1543: this file's load-time code; board-main.js runs it after every module has loaded.
export function initWorktree() {
  // Accordion: each Acceptance/Test Plan section collapses independently.
  document.querySelectorAll('.ck-accordion-header[data-accordion]').forEach(header => {
    header.addEventListener('click', () => {
      document.getElementById(header.dataset.accordion).classList.toggle('collapsed');
    });
  });

  document.getElementById('ck-details').addEventListener('click', openCockpitDetails);
  document.getElementById('ck-back').addEventListener('click', closeCockpit);
  document.getElementById('ck-rail-toggle').addEventListener('click', () => {
    const cockpit = document.getElementById('cockpit');
    const rail = document.querySelector('#cockpit .ck-rail');
    const collapsing = !cockpit.classList.contains('rail-collapsed');
    // An inline width from a manual resize always beats the collapsed-state
    // CSS rule (inline wins over any class selector) — stash it and restore
    // on expand, or the rail would silently ignore the 44px collapse width.
    if (collapsing) {
      if (rail.style.width) rail.dataset.customWidth = rail.style.width;
      rail.style.width = '';
    } else if (rail.dataset.customWidth) {
      rail.style.width = rail.dataset.customWidth;
    }
    cockpit.classList.toggle('rail-collapsed');
  });

  (function makeRailResizable() {
    const rail = document.querySelector('#cockpit .ck-rail');
    const resizeEl = document.getElementById('ck-rail-resize');
    if (!rail || !resizeEl) return;
    const MIN_W = 220, MAX_W = 520;
    let resizing = false, startX = 0, startWidth = 0;
    resizeEl.addEventListener('pointerdown', e => {
      if (document.getElementById('cockpit').classList.contains('rail-collapsed')) return;
      resizing = true;
      startX = e.clientX;
      startWidth = rail.getBoundingClientRect().width;
      rail.style.transition = 'none'; // no lag trailing the pointer mid-drag
      resizeEl.classList.add('resizing');
      document.body.style.userSelect = 'none';
      resizeEl.setPointerCapture(e.pointerId);
    });
    resizeEl.addEventListener('pointermove', e => {
      if (!resizing) return;
      const next = Math.min(MAX_W, Math.max(MIN_W, startWidth + (e.clientX - startX)));
      rail.style.width = next + 'px';
    });
    const stopResize = e => {
      if (!resizing) return;
      resizing = false;
      rail.style.transition = '';
      resizeEl.classList.remove('resizing');
      document.body.style.userSelect = '';
      try { resizeEl.releasePointerCapture(e.pointerId); } catch {}
    };
    resizeEl.addEventListener('pointerup', stopResize);
    resizeEl.addEventListener('pointercancel', stopResize);
  })();
  document.getElementById('ck-preview-label').addEventListener('click', () => {
    document.getElementById('ck-preview').classList.remove('collapsed');
    // t-82f4: persist onto the active tab so switching away and back restores
    // this expanded state instead of always reopening collapsed.
    if (cockpitState) cockpitState.previewCollapsed = false;
    requestPreview();
  });
  document.getElementById('ck-preview-collapse').addEventListener('click', () => {
    document.getElementById('ck-preview').classList.add('collapsed');
    if (cockpitState) cockpitState.previewCollapsed = true;
  });
  document.addEventListener('keydown', e => {
    // t-6254: Esc closes the ticket viewer popup first; the cockpit stays
    if (e.key === 'Escape' && document.getElementById('cockpit-overlay').classList.contains('open') && !document.getElementById('modal-overlay').classList.contains('open')) closeCockpit();
  });
}
