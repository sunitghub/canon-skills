// t-718b: the GitHub workflow on the board. Every action is one route from t-d271, each running one tkt command
// (send-issue, github-status, import-results, merge-pr --check / --yes, take-back); this module adds no logic of its
// own beyond choosing which button a card shows. A ticket with runs: github (and its github: link, no merged: line) is
// out on GitHub: it shows in In progress (board-helpers.js effectiveStatus) with a GitHub chip and one stage button instead of Start.
import { state } from './board-core.js';
import { closeTab, cockpitState, openTerminalPane } from './board-cockpit.js';
import { esc, escAttr, isWindowsBrowser } from './board-helpers.js';
import { render, showToast } from './board-render.js';
import { loadData, SHELL_TAB } from './board-core.js';
import { resetPanelDrag, resetPanelResize } from './board-panels.js';

const POLL_MS = 120000;          // github-status per card out on GitHub; the server caches each for 30 s
const MERGE_POLL_MS = 2000;
const STALE_DAYS = 3;          // t-6f51: a send with no PR and no issue activity for this long reads as stale in the picker
const MERGE_LOST_POLLS = 5;   // failed polls in a row before the merge dialog stops waiting
const statusById = new Map();    // id -> {ok, status?, output, pending?}
const mergeById = new Map();     // id -> {status, output, exit_code, elapsed} while a merge job is followed
let pollTimer = null;

// github: is only the issue link (sync-issues and import-issue write it too); runs: github says a cloud session has it.
export function ghOut(t) { return !!(t && t.runs === 'github' && t.github && !t.merged); }

function ghParts(t) {
  const m = /^([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)#([0-9]+)$/.exec(String(t.github || ''));
  return m ? { repo: m[1], issue: m[2] } : null;
}
const ghApi = (id, what) => `/api/ticket/${encodeURIComponent(id)}/github/${what}`;
async function getJSON(url) { const r = await fetch(url); if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); }
async function postJSON(url, body) {
  const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

// ── Card: chip and the one stage button ─────────────────────────────────────────────────────────────────────────────
function stageOf(t) {
  const s = statusById.get(t.id);
  if (mergeById.get(t.id)?.status === 'running') return { stage: 'merging' };
  if (!s || s.pending) return { stage: 'unknown' };   // its first status is still on the way: no "can't check" flash
  if (!s.ok || !s.status) return { stage: 'error', output: s.output };
  return s.status;
}
// A PR number from github-status goes into a link and a label: digits only, else none.
const prOf = st => (/^[0-9]+$/.test(String(st.pr ?? '')) ? Number(st.pr) : 0);
function lastLine(text) {
  const lines = String(text || '').split(/\r?\n|\r/).map(l => l.trim()).filter(Boolean);
  return lines.length ? lines[lines.length - 1] : '';
}
function mmss(sec) { sec = Math.max(0, Math.round(sec || 0)); return `${Math.floor(sec / 60)}m${String(sec % 60).padStart(2, '0')}s`; }

export function ghChipHTML(t) {
  if (!ghOut(t)) return '';
  const p = ghParts(t), st = stageOf(t), n = p ? `GitHub #${p.issue}` : 'GitHub';
  let text = n, title = String(t.github);
  if (st.stage === 'sent') text += ' · sent';
  else if (st.stage === 'pr-open') text += prOf(st) ? ` · PR #${prOf(st)}` : ' · PR open';
  else if (st.stage === 'branch') { text += ' · branch, no PR'; title = `${st.branch} is on GitHub with no PR`; }
  else if (st.stage === 'results-ready') text += ' · results ready';
  else if (st.stage === 'results-in') text += ' · results in';
  else if (st.stage === 'merging') { const m = mergeById.get(t.id); text += ` · merging… ${mmss(m.elapsed)}`; title = lastLine(m.output) || title; }
  else if (st.stage === 'error') { text += " · can't check"; title = st.output || title; }
  return `<span class="card-gh-chip" data-id="${esc(t.id)}" title="${escAttr(title)}">${esc(text)}</span>`
    + (st.stage === 'merging' ? '' : `<button class="card-gh-takeback" type="button" data-id="${esc(t.id)}" title="Bring this ticket back to work on it here">take back</button>`);
}

export function ghButtonHTML(t) {
  if (!ghOut(t)) return '';
  const st = stageOf(t);
  const btn = (action, label, title) =>
    `<button class="card-start card-gh-btn" type="button" data-id="${esc(t.id)}" data-gh-action="${action}" title="${escAttr(title)}">${esc(label)}</button>`;
  // t-c259: imported, not closed, PR open: the close finishes here, in a worktree at the PR head.
  // t-6623: once that worktree exists the card offers Finish (tkt land --finish), which removes it after the close.
  if (st.landed) return btn('finish', 'Finish', `Remove the worktree at ${st.landed} once sprint complete has closed the ticket there (tkt land --finish)`);
  // t-d0a5: PR open but nothing came back (the cloud session stopped before its close): close it here, the same tkt land.
  if (st.land && st.close_here) return btn('close-here', 'Close here', 'The cloud session stopped before its close: make a worktree at the PR head and close the ticket there (tkt land)');
  if (st.land) return btn('land', 'Continue here', 'Make a worktree at the PR head and continue the ticket there (tkt land)');
  if (st.stage === 'results-ready') return btn('import', 'Import results', 'Bring the cloud session\'s results back into this ticket');
  if (st.stage === 'results-in' || st.stage === 'merging') return btn('merge', 'Check & merge', 'Check the PR and merge it after your confirmation');
  // t-9955: "↗" goes to GitHub and changes nothing; Create PR is the one that makes something.
  if (st.stage === 'pr-open' && prOf(st)) return btn('pr', 'PR ↗', `PR #${prOf(st)} on GitHub`);
  if (st.stage === 'branch') return btn('open-pr', 'Create PR', `The session pushed ${st.branch} without a PR: create one`);
  const p = ghParts(t);
  return btn('issue', 'Issue ↗', p ? `Issue #${p.issue} on GitHub` : 'The issue on GitHub');
}

export function bindGithubCardButtons(root) {
  root.querySelectorAll('.card-gh-btn').forEach(b => b.addEventListener('click', e => {
    e.stopPropagation();
    const t = state.tickets.find(x => x.id === b.dataset.id);
    if (t) ghAction(t, b.dataset.ghAction);
  }));
  root.querySelectorAll('.card-gh-takeback').forEach(b => b.addEventListener('click', e => {
    e.stopPropagation();
    const t = state.tickets.find(x => x.id === b.dataset.id);
    if (t) takeBack(t);
  }));
}

function openUrl(url) { window.open(url, '_blank', 'noopener'); }

async function ghAction(t, action) {
  const p = ghParts(t), st = stageOf(t), pr = prOf(st);
  if (action === 'issue' && p) return openUrl(`https://github.com/${p.repo}/issues/${p.issue}`);
  if (action === 'pr' && p && pr) return openUrl(`https://github.com/${p.repo}/pull/${pr}`);
  if (action === 'import') return importResults(t, pr);
  if (action === 'merge') return checkAndMerge(t, pr);
  if (action === 'open-pr' && p) return openPr(t, p, st);
  if (action === 'land') return continueHere(t, pr);
  if (action === 'close-here') return closeHere(t, pr);
  if (action === 'finish') return finishHere(t);
}

// ── Continue here (t-c259, renamed t-6623): a cloud PR whose gates did not pass on its head is closed on this machine ──────────────
async function continueHere(t, pr, fix = false) {
  const head = pr ? `PR #${pr}'s` : 'the PR\'s';
  const ask = openDialog({
    title: fix ? `Fix ${t.id} here?` : `Continue ${t.id} here?`,
    body: `Creates a worktree on land/${t.id} at ${head} head and starts the ticket there.${fix ? ' Fix what failed, commit it there, and run sprint complete again.' : ' Run the evaluator and sprint complete in that worktree.'} Then Finish on the card removes the worktree. Nothing is pushed or merged.`,
    ok: 'Create worktree', cancel: 'Cancel',
  });
  if (!(await ask).ok) return;
  return landRun(t, { ...(pr ? { pr } : {}), ...(fix ? { fix: true } : {}) }, 'Preparing', 'Worktree ready');
}

// t-d0a5: the card cannot tell a stopped cloud session from one still working, so the confirm says when to use it.
async function closeHere(t, pr) {
  const head = pr ? `PR #${pr}'s` : 'the PR\'s';
  const ask = openDialog({
    title: `Close ${t.id} here?`,
    body: `Use this only once the cloud session has stopped: nothing came back from it (no results to import). Creates a worktree on land/${t.id} at ${head} head and starts the ticket there; run the close in that worktree, then Finish on the card removes it. Nothing is pushed or merged.`,
    ok: 'Create worktree', cancel: 'Cancel',
  });
  if (!(await ask).ok) return;
  return landRun(t, pr ? { pr } : {}, 'Preparing', 'Worktree ready');
}

async function finishHere(t) {
  const st = stageOf(t);
  const ask = openDialog({
    title: `Finish ${t.id}?`,
    body: `Removes the worktree at ${st.landed} and its land/${t.id} branch (the branch stays if it holds commits the PR does not). It needs sprint complete to have closed the ticket there with a passing verdict. Nothing is pushed or merged.`,
    ok: 'Finish', cancel: 'Cancel',
  });
  if (!(await ask).ok) return;
  return landRun(t, { finish: true }, 'Finishing', 'Closed here');
}

async function landRun(t, body, doing, done) {
  const run = openDialog({ title: `${doing} ${t.id}…`, pre: 'Running tkt land…', cancel: 'Close', escape: false });
  let res;
  try { res = await postJSON(ghApi(t.id, 'land'), body); }
  catch (e) { res = { ok: false, output: String(e.message || e) }; }
  updateDialog({ title: res.ok ? done : 'Nothing was changed', body: '', pre: res.output || '', escape: true }, run.gen);
  statusById.delete(t.id);
  await loadData();
}

// ── Create PR (t-24b1, label t-9955): a session pushed its branch and stopped short of a PR ─────────────────────────────────────────
async function openPr(t, p, st) {
  const ask = openDialog({
    title: `Create a PR for ${t.id}?`,
    body: `Opens a pull request on ${p.repo} from ${st.branch} into its default branch, with "Fixes #${p.issue}", so Import results and Check & merge can find it.`,
    ok: 'Create PR', cancel: 'Cancel',
  });
  if (!(await ask).ok) return;
  const run = openDialog({ title: `Creating a PR for ${t.id}…`, pre: 'Running tkt open-pr…', cancel: 'Close', escape: false });
  let res;
  try { res = await postJSON(ghApi(t.id, 'open-pr'), {}); }
  catch (e) { res = { ok: false, output: String(e.message || e) }; }
  updateDialog({ title: res.ok ? 'PR created' : 'No PR created', body: res.ok ? '' : 'Nothing was created on GitHub.', pre: res.output || '', escape: true }, run.gen);
  statusById.delete(t.id);
  await pollGithub(true);
}

// ── Status polling ──────────────────────────────────────────────────────────────────────────────────────────────────
async function fetchStatus(t) {
  try {
    const res = await getJSON(ghApi(t.id, 'status'));
    statusById.set(t.id, res);
  } catch (e) {
    statusById.set(t.id, { ok: false, output: String(e.message || e) });
  }
}
export async function pollGithub(force) {
  if (document.hidden && !force) return;   // nothing changes on screen while the page is hidden
  const out = (state.tickets || []).filter(ghOut);
  if (!out.length) return;
  await Promise.all(out.map(fetchStatus));
  render();
}
// A card that just appeared out on GitHub gets its stage at once, not at the next 2-minute tick.
export function ensureGithubStatus() {
  const missing = (state.tickets || []).filter(t => ghOut(t) && !statusById.has(t.id));
  if (!missing.length) return;
  missing.forEach(t => statusById.set(t.id, { pending: true }));
  Promise.all(missing.map(fetchStatus)).then(render);
}

// ── The dialog (#gh-dialog): a title, text or output, an optional checkbox, up to two buttons ───────────────────────
function dialog() {
  return {
    el: document.getElementById('gh-dialog'),
    title: document.getElementById('gh-dialog-title'),
    body: document.getElementById('gh-dialog-body'),
    pre: document.getElementById('gh-dialog-pre'),
    table: document.getElementById('gh-dialog-table'),
    check: document.getElementById('gh-dialog-check'),
    checkLabel: document.getElementById('gh-dialog-check-label'),
    ok: document.getElementById('gh-dialog-ok'),
    cancel: document.getElementById('gh-dialog-cancel'),
    box: document.getElementById('gh-dialog-box'),
  };
}
let dlgClose = null;
let dlgGen = 0;          // which openDialog() the dialog shows: a late answer for an older one must not fill it
let dlgEscape = true;    // t-e523: while a step runs, Escape does nothing; only the dialog's own buttons close it
let dlgFollow = true;    // the log follows new output until the user scrolls up, and again once they scroll back down
let dlgReturn = null;    // where focus goes back to when the dialog closes
// Returns a promise of the choice; .gen is this dialog's number for updateDialog.
export function openDialog({ title, body = '', pre = '', check = '', ok = '', cancel = 'Close', escape = true }) {
  const d = dialog();
  if (!d.el.classList.contains('open')) { dlgReturn = document.activeElement; resetPanelDrag(d.box); resetPanelResize(d.box); }
  const gen = ++dlgGen;
  dlgEscape = escape;
  dlgFollow = true;
  d.title.textContent = title;
  d.body.textContent = body;
  d.pre.textContent = oneProgressLine(pre); d.pre.hidden = !pre; d.pre.scrollTop = d.pre.scrollHeight;
  d.table.replaceChildren(); d.table.hidden = true;   // a table belongs to one dialog: the next one starts without it
  d.check.checked = false; d.checkLabel.hidden = !check;
  d.checkLabel.querySelector('span').textContent = check;
  d.ok.textContent = ok; d.ok.hidden = !ok; d.ok.disabled = false;
  setCancel(d, cancel);
  d.el.classList.add('open');
  const done = new Promise(resolve => {
    dlgClose = v => {
      d.el.classList.remove('open'); dlgClose = null; resolve(v);
      const back = dlgReturn; dlgReturn = null;
      if (back && back.isConnected && typeof back.focus === 'function') back.focus();
    };
    d.ok.onclick = () => dlgClose && dlgClose({ ok: true, checked: d.check.checked, issues: [...d.table.querySelectorAll('input[type=checkbox]:checked')].map(b => +b.dataset.issue) });
    d.cancel.onclick = () => dlgClose && dlgClose({ ok: false });
  });
  (d.ok.hidden ? d.cancel : d.ok).focus();
  done.gen = gen;
  return done;
}
// Changes the dialog only while it still shows dialog number gen (any when gen is omitted and one is open).
function updateDialog(fields, gen) {
  if (!dlgClose || (gen !== undefined && gen !== dlgGen)) return;
  const d = dialog();
  if ('title' in fields) d.title.textContent = fields.title;
  if ('body' in fields) d.body.textContent = fields.body;
  if ('pre' in fields) { d.pre.textContent = oneProgressLine(fields.pre); d.pre.hidden = !fields.pre; if (dlgFollow) d.pre.scrollTop = d.pre.scrollHeight; }
  if ('ok' in fields) {
    d.ok.textContent = fields.ok; d.ok.hidden = !fields.ok;
    if (fields.ok) d.ok.focus(); else if (document.activeElement === d.ok || !d.el.contains(document.activeElement)) d.cancel.focus();
  }
  if ('table' in fields) { d.table.replaceChildren(...(fields.table ? [fields.table] : [])); d.table.hidden = !fields.table; }
  if ('okLabel' in fields) d.ok.textContent = fields.okLabel;   // a new label only: focus stays where the user is (a Space on a checkbox must not land on Create)
  if ('okDisabled' in fields) d.ok.disabled = fields.okDisabled;
  if ('cancel' in fields) setCancel(d, fields.cancel);
  if ('escape' in fields) dlgEscape = fields.escape;
}
// Stop ends a running step and is then the dialog's main action (fills red on hover); Close and Cancel only close it
// (red outline on hover). buttons.css, t-e523.
function setCancel(d, label) {
  d.cancel.textContent = label;
  d.cancel.classList.toggle('b-danger-main', label === 'Stop');
  d.cancel.classList.toggle('b-close', label !== 'Stop');
}
// merge-pr prints "running …" once, then again with the time every few seconds; the dialog shows only the newest of a
// run of them (t-e523).
const PROGRESS = /^merge-pr: running .*…/;
function oneProgressLine(text) {
  const lines = String(text).split('\n');
  return lines.filter((l, i) => !(PROGRESS.test(l) && PROGRESS.test(lines[i + 1] || ''))).join('\n');
}

// ── Import results ──────────────────────────────────────────────────────────────────────────────────────────────────
async function importResults(t, pr) {
  const shown = openDialog({ title: `Importing results for ${t.id}…`, pre: 'Running tkt import-results…', cancel: 'Close', escape: false });
  let res;
  try { res = await postJSON(ghApi(t.id, 'import'), pr ? { pr } : {}); }
  catch (e) { res = { ok: false, output: String(e.message || e) }; }
  const noVerdict = /no eval-report\.md|graded-head: none|NOT match graded-head/.test(res.output || '');
  const fixCmd = ((res.output || '').match(/next: (tkt land [\w-]+ --pr \d+ --fix)/) || [])[1] || '';   // t-75f5: a cloud-closed ticket with a mismatched head: `land` needs --fix
  updateDialog({
    title: res.ok ? `Results are back in .tickets/${t.id}/` : (noVerdict ? 'Imported, but the cloud sprint did not close' : 'Import failed'),
    body: res.ok ? 'Next: Check & merge on the card.'
      : fixCmd ? `The cloud closed this ticket, but the PR\'s head is not the commit its evaluator graded, so Check & merge is not offered. Close it again on this machine: run ${fixCmd} in a terminal (it makes a worktree at the PR\'s head to grade and close in; docs/setup.md › Claude cloud sessions).`
      : noVerdict ? 'There is no passing evaluator verdict on the PR\'s head, so there is nothing to merge yet. Finish the close on this machine: tkt land (Continue here on the card, once the results include an eval-report) makes a worktree at the PR\'s head to run the evaluator and sprint complete in, then Check & merge (docs/setup.md › Claude cloud sessions).'
      : 'Nothing was changed.',
    pre: res.output || '', escape: true,
  }, shown.gen);
  statusById.delete(t.id);
  await loadData();
}

// ── Check & merge ───────────────────────────────────────────────────────────────────────────────────────────────────
// t-a463: the one line that says WHY, shown above the log (a long log tail buries it). Prefers the line that names the refusal.
function refusalReason(out) {
  const lines = String(out || '').split('\n').map(s => s.trim()).filter(Boolean);
  const hit = lines.find(s => /is a draft|GitHub refused|gh could not merge|failed on .* \+ PR|cannot merge cleanly|not open|blocked by|comes from a fork|not the commit the evaluator graded/.test(s)) || lines[0] || '';
  return hit.replace(/^merge-pr:\s*/, '');
}
// t-41ff: merge-pr's "Local <branch>:" line and the indented lines under it (the files that stopped the update, the next step).
function localMainNote(out) {
  const lines = String(out || '').split('\n');
  const i = lines.findIndex(s => /^Local [^:]+: /.test(s));
  if (i < 0) return '';
  const rest = [];
  for (const s of lines.slice(i + 1)) { if (!/^ {2}\S/.test(s)) break; rest.push(s.trim()); }
  return [lines[i], ...rest].join(' ');
}
const isDraftRefusal = out => /is a draft; GitHub will not merge it|is a draft: run gh pr ready/.test(out || '');
// A cloud PR is always opened as a draft and GitHub will not merge one: the dialog's button marks it ready (the click is the consent; tkt
// pr-ready re-checks that it is this ticket's own open same-repo draft; gh pr ready --undo reverses it), then runs Check & merge again.
async function markReady(t, pr) {
  const shown = openDialog({ title: `Marking ${t.id}'s PR ready…`, body: 'Running tkt pr-ready.', cancel: 'Close', escape: false });
  let res;
  try { res = await postJSON(ghApi(t.id, 'ready'), pr ? { pr } : {}); }
  catch (e) { res = { ok: false, output: String(e.message || e) }; }
  if (!res.ok) { updateDialog({ title: 'Could not mark it ready', body: 'Nothing was changed.', pre: res.output || '', escape: true }, shown.gen); return; }
  updateDialog({ title: 'Marked ready', body: 'Checking it again…', pre: res.output || '', escape: false }, shown.gen);
  await checkAndMerge(t, pr);
}

async function checkAndMerge(t, pr) {
  const prQ = pr ? `?pr=${encodeURIComponent(pr)}` : '';
  const prB = pr ? { pr } : {};
  if (mergeById.get(t.id)?.status === 'running') return followMerge(t, prB, true);
  const open = openDialog({ title: `Check & merge${pr ? ` PR #${pr}` : ''}`, body: 'Running the checks that run none of the PR\'s code…', pre: '', ok: '', cancel: 'Cancel', escape: false });
  let chk;
  try { chk = await getJSON(ghApi(t.id, 'merge-check') + prQ); }
  catch (e) { chk = { ok: false, output: String(e.message || e) }; }
  if (!chk.ok) {
    const reason = refusalReason(chk.output), draft = isDraftRefusal(chk.output);
    // t-ca00: merge-pr names the conflicting files; the way out is the worktree fix the suite-failure case already offers.
    const conflict = /mergeable: CONFLICTING/.test(chk.output || '');   // only a real conflict: BEHIND, UNKNOWN or UNSTABLE refusals keep only Close
    const files = ((chk.output || '').match(/conflicts in: (.+)/) || [])[1];
    updateDialog({ body: `${(reason || 'Not mergeable here').replace(/[.:\s]+$/, '')}.${conflict && files ? ` Conflicts in: ${files.trim()}.` : ''} Nothing was run or changed.`, pre: chk.output || '', ok: draft ? 'Mark ready' : conflict ? 'Fix here' : '', cancel: 'Close', escape: true }, open.gen);
    if (draft) { const v = await open; if (v && v.ok) await markReady(t, pr); }
    else if (conflict) { const v = await open; if (v && v.ok) await continueHere(t, pr, true); }
    return;
  }
  updateDialog({
    body: 'Running the tests runs the PR\'s code on this machine. Nothing from the PR runs before you press the button.',
    pre: chk.output || '', ok: 'Run tests & merge', cancel: 'Cancel', escape: true,
  }, open.gen);
  const choice = await open;
  if (!choice || !choice.ok) return;
  try { await postJSON(ghApi(t.id, 'merge'), prB); }
  catch (e) { showToast(`Could not start the merge: ${e.message || e}`, 'block'); return; }
  return followMerge(t, prB, true);
}

async function followMerge(t, prB, show) {
  let gen, finished = false, shown = null;
  const mirrors = (statusById.get(t.id)?.status?.mirrors || []).filter(m => typeof m === 'string' && m);
  if (show) {
    shown = openDialog({ title: `Checking & merging ${t.id}`, body: 'Running the tests on the base branch + PR…', pre: '', ok: '', cancel: 'Stop', escape: false });
    gen = shown.gen;
    shown.then(v => { if (v && !v.ok && !finished) stopMerge(t); });
  }
  for (let lost = 0; ;) {
    let st;
    try { st = await getJSON(ghApi(t.id, 'merge')); } catch { st = null; }
    if (!st && ++lost >= MERGE_LOST_POLLS) {
      finished = true;
      if (gen !== undefined) { updateDialog({ title: 'Lost contact', body: 'The board stopped hearing about this merge. It may still be running: check the ticket in a few minutes.', cancel: 'Close', escape: true }, gen); }
      return;
    }
    if (st) {
      lost = 0;
      mergeById.set(t.id, st);
      if (gen !== undefined) updateDialog({ body: st.status === 'running' ? `Running… ${mmss(st.elapsed)}` : '', pre: st.output || '' }, gen);
      render();
      if (st.status !== 'running') break;
    }
    await new Promise(r => setTimeout(r, MERGE_POLL_MS));
  }
  finished = true;
  const st = mergeById.get(t.id);
  mergeById.delete(t.id);
  const merged = st && st.exit_code === 0 && /Merged PR #/.test(st.output || '');
  // t-24b1: merge-pr fast-forwards local main itself (its last line says how); the canon.mirror remotes are offered here,
  // named, and pushed only on this click.
  const offer = merged && mirrors.length ? `Push main to ${mirrors.join(', ')}` : '';
  // t-6623: merge-pr says "<cmd> failed on <base> + PR #N" when the suite fails here: the PR can be fixed in a worktree.
  const suiteFailed = !merged && /failed on .* \+ PR #\d+/.test(st?.output || '');
  const draftRefused = !merged && isDraftRefusal(st?.output);   // t-a463
  const local = merged ? localMainNote(st.output) : '';
  if (gen !== undefined) updateDialog({
    title: merged ? 'Merged' : 'Not merged',
    body: merged ? `The PR is merged and the issue closed by its Fixes line.${local ? ` ${local}` : ''}${offer ? ` Also push main to ${mirrors.join(', ')} (git config canon.mirror)?` : ''}` : `${(refusalReason(st?.output) || 'Not merged').replace(/[.:\s]+$/, '')}. Nothing changed on GitHub. See the output.`,
    pre: st?.output || '', ok: offer || (draftRefused ? 'Mark ready' : suiteFailed ? 'Fix here' : ''), cancel: 'Close', escape: true,
  }, gen);
  if (offer && shown) shown.then(v => { if (v && v.ok) pushMain(mirrors); });
  else if (draftRefused && shown) shown.then(v => { if (v && v.ok) markReady(t, prB.pr); });
  else if (suiteFailed && shown) shown.then(v => { if (v && v.ok) continueHere(t, prB.pr, true); });
  statusById.delete(t.id);
  await loadData();
}

async function pushMain(mirrors) {
  const run = openDialog({ title: `Pushing main to ${mirrors.join(', ')}…`, pre: 'Running tkt push-main…', cancel: 'Close', escape: false });
  let res;
  try { res = await postJSON('/api/github/push-main', {}); }
  catch (e) { res = { ok: false, output: String(e.message || e) }; }
  updateDialog({ title: res.ok ? 'Pushed' : 'Not every mirror was pushed', body: res.ok ? '' : 'Nothing was forced. See the output.', pre: res.output || '', escape: true }, run.gen);
}

async function stopMerge(t) {
  try { await postJSON(ghApi(t.id, 'merge-stop'), {}); } catch {}
}

// ── Take back ───────────────────────────────────────────────────────────────────────────────────────────────────────
async function takeBack(t) {
  const p = ghParts(t);
  const v = await openDialog({
    title: `Take ${t.id} back from GitHub?`,
    body: `It returns to Open so you can start it here. Stop its cloud session first. The cloud branch and any PR stay on GitHub.`,
    check: p ? `Also close issue #${p.issue} with a comment` : '',
    ok: 'Take back', cancel: 'Cancel',
  });
  if (!v || !v.ok) return;
  let res;
  try { res = await postJSON(ghApi(t.id, 'take-back'), { close_issue: !!v.checked }); }
  catch (e) { res = { ok: false, output: String(e.message || e) }; }
  if (!res.ok) { await openDialog({ title: 'Could not take it back', body: 'Nothing was changed.', pre: res.output || '' }); return; }
  statusById.delete(t.id);
  showToast(`${t.id} is back on this machine`, 'ok');
  await loadData();
}

// ── Readiness (t-24b1): the picker's GitHub row reads t-90a3's doctor, the one source of the checks ─────────────────
const DOCTOR_RETRY_MS = 30000;
let doctor = { state: 'unknown' };   // unknown | pending | ready | bad | failed; ready and bad carry n (not bad) of m checks
let doctorAt = 0;
let place = null;   // { tab, onPick } of the picker that drew the row, so the answer can replace just that row
function ensureDoctor() {
  if (doctor.state === 'ready' || doctor.state === 'pending') return;
  if ((doctor.state === 'bad' || doctor.state === 'failed') && Date.now() - doctorAt < DOCTOR_RETRY_MS) return;
  doctor = { state: 'pending' }; doctorAt = Date.now();
  getJSON('/api/github/doctor').then(res => {
    const checks = res && res.ok && res.doctor && Array.isArray(res.doctor.checks) ? res.doctor.checks : null;
    const n = checks ? checks.filter(c => c && c.status !== 'bad').length : 0, m = checks ? checks.length : 0;
    doctor = { state: !m ? 'failed' : n === m ? 'ready' : 'bad', n, m };   // no checks at all: the read failed
  }, () => { doctor = { state: 'failed', n: 0, m: 0 }; }).then(() => { swapPlaceRow(); paintSyncButton(); });
  paintSyncButton();
}
// t-9641: GitHub Sync is greyed out until the checks pass (no GitHub origin included); the tooltip says where to fix
// it. The doctor runs once per board load (ensureDoctor at init), and again when the picker asks or the board gets focus
// or becomes visible again (t-f053), each only after the retry window: never on a timer.
let syncTitle = '';
function paintSyncButton() {
  const b = document.getElementById('btn-gh-sync');
  if (!b) return;
  if (!syncTitle) syncTitle = b.title;
  const ready = doctor.state === 'ready';
  b.disabled = !ready;
  b.title = ready ? syncTitle
    : doctor.state === 'unknown' || doctor.state === 'pending' ? 'Checking GitHub…'
    : 'Set up GitHub first: Cockpit › Factory › GitHub';
}
// The answer replaces only the "checking…" row, never the whole picker: a redraw could land after a GitHub pick and
// rebuild the send panel mid-send.
function swapPlaceRow() {
  const el = document.getElementById('ck-gh-place');
  if (!el || !el.classList.contains('ck-gh-checking') || !place) return;
  el.outerHTML = githubPlaceRowHTML(place.tab);
  bindPlaceRow();
}
function openFactoryGithub() {
  if (window.parent === window) { showToast('GitHub is not set up for this project: run tkt github-doctor in a terminal'); return; }
  window.parent.postMessage({ source: 'canon-board', type: 'open-factory-github', tab: SHELL_TAB }, location.origin);
}
function bindPlaceRow() {
  const el = document.getElementById('ck-gh-place');
  if (!el || !place) return;
  if (el.classList.contains('ck-gh-setup')) {
    el.addEventListener('click', openFactoryGithub);
    el.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openFactoryGithub(); } });
  } else if (el.dataset.github) {
    const onPick = place.onPick;
    el.addEventListener('click', () => onPick(el));
  }
}
// The picker calls this once its rows are in the page; onPick(row) is what picking the GitHub place does there.
export function bindGithubPickerRows(box, tab, onPick) {
  place = { tab, onPick };
  box.querySelectorAll('.ck-gh-takeback').forEach(b => b.addEventListener('click', e => {
    e.stopPropagation();
    const t = state.tickets.find(x => x.id === b.dataset.id);
    if (t) takeBack(t);   // t-6f51: the card's own dialog; nothing else takes a ticket back
  }));
  bindPlaceRow();
  swapPlaceRow();   // an answer that landed while the picker was still building its rows
}
function githubPlaceRowHTML(tab) {
  ensureDoctor();
  if (doctor.state === 'unknown' || doctor.state === 'pending') {
    return `<div class="ck-worktree-held-row ck-gh-checking" id="ck-gh-place"><span class="ck-worktree-held-branch">GitHub · checking…</span><span class="ck-worktree-held-why">reading the GitHub checks</span></div>`;
  }
  if (doctor.state === 'bad' || doctor.state === 'failed') {
    const what = doctor.state === 'bad' ? `set up first (${doctor.n} of ${doctor.m} ready)` : 'set up first (the checks could not run)';
    return `<div class="ck-worktree-held-row ck-gh-setup" id="ck-gh-place" role="button" tabindex="0" title="Opens Factory › GitHub, which lists what to fix"><span class="ck-worktree-held-branch">GitHub · ${what}</span><span class="ck-worktree-held-why">open Factory › GitHub</span></div>`;
  }
  return `<div class="ck-worktree-row ck-gh-row${tab.ghPick ? ' selected' : ''}" id="ck-gh-place" data-github="new" title="Sends this ticket as an issue to your repo; a cloud agent works it and opens a PR">
      <div class="ck-worktree-radio"></div>
      <div class="ck-worktree-labels"><div class="ck-worktree-label">GitHub · new issue</div><div class="ck-worktree-sub">A Cloud Agent works it</div></div>
    </div>`;
}

// ── The worktree picker's GitHub rows, and the panel shown instead of the terminal ──────────────────────────────────
// t-ced8: a ticket can go to a cloud session while it is open, or in progress with nothing working on it (planned here, then handed
// over): a live session for it (a row in the daemon's list) means someone is working it. `tkt send-issue` makes the same call and
// owns the other checks (unpushed commits, a live session it can see, a closed ticket), so the Terminal and this row agree.
function githubCanSend(t) {
  if (!t || t.scratch || ghOut(t)) return false;
  if (t.status === 'open') return true;
  return t.status === 'in_progress' && !t.working && !(state.cockpitRows && state.cockpitRows.get(t.id));   // t.working: an agent outside the Cockpit (t-187e)
}
export function githubPickerRowsHTML(t, tab) {
  if (!githubCanSend(t)) return '';
  // A closed or cancelled ticket is not busy in the cloud: one closed by hand never gets merged: (t-093a). ghOut() stays
  // true for it, because a closed, imported ticket still needs its Check & merge button.
  const busy = (state.tickets || []).filter(x => ghOut(x) && x.status !== 'closed' && x.status !== 'cancelled');
  // t-6f51: the busy rows fold into one line, as "N worktrees unavailable" does; the place row to send another stays outside.
  const fold = busy.length ? `<details class="ck-worktree-held ck-gh-busy-fold"><summary>${busy.length} ticket${busy.length === 1 ? '' : 's'} on GitHub</summary>`
    + busy.map(x => {
      const p = ghParts(x), idle = staleDays(x);
      const why = idle ? `no activity for ${idle} days: ${esc(x.id)}` : `cloud · busy: ${esc(x.id)}`;
      return `<div class="ck-worktree-held-row ck-gh-busy${idle ? ' ck-gh-stale' : ''}" data-id="${escAttr(x.id)}"><span class="ck-worktree-held-branch">GitHub${p ? ` #${esc(p.issue)}` : ''}</span><span class="ck-worktree-held-why">${why}</span>`
        + (idle ? `<button type="button" class="ck-gh-takeback" data-id="${escAttr(x.id)}" title="Bring this ticket back to work on it here">Take back</button>` : '') + `</div>`;
    }).join('') + `</details>` : '';
  return fold + githubPlaceRowHTML(tab);
}
// t-6f51: whole days of silence on a send that has no PR (stage sent: no results branch, no session branch either), 0 when it is not stale.
// issue_updated is github-status's one added field: the issue's updatedAt, which a comment moves too.
function staleDays(t) {
  const st = statusById.get(t.id)?.status;
  if (!st || st.stage !== 'sent' || prOf(st) || !st.issue_updated) return 0;
  const at = Date.parse(st.issue_updated);
  const days = Number.isFinite(at) ? Math.floor((Date.now() - at) / 86400000) : 0;
  return days >= STALE_DAYS ? days : 0;
}

// t-8627: a preview answer that arrives after a later call (or a hide) must not write: each call takes a number, and only the latest may.
let ghPanelGen = 0;

export function hideGithubPanel() {
  ghPanelGen++;
  const panel = document.getElementById('ck-gh-panel');
  if (panel) { panel.hidden = true; panel.innerHTML = ''; }
}

export async function showGithubPanel(t, tab) {
  const panel = document.getElementById('ck-gh-panel');
  if (!panel) return;
  const sent = tab && tab.ghSent && tab.ghSent.id === t.id;
  // t-8627: a panel already sending this ticket (loading, or a form with a preview) stays as it is; a failed preview still
  // reloads. openCockpit mounts once more when its rail render ends, and a GitHub pick and a failed send made before that lost
  // their reason to the second render.
  if (!sent && !ghOut(t) && !panel.hidden && panel.querySelector('[data-gh-send]')?.dataset.ghSend === t.id) return;
  // t-32f9: so does a panel whose Commit and push form is open (a failed preview offers it, and would otherwise reload under it).
  if (!sent && !ghOut(t) && !panel.hidden && panel.querySelector('#ck-gh-cp')?.dataset.open === t.id) return;
  const gen = ++ghPanelGen;
  panel.hidden = false;
  if (sent) return showSent(panel, t, tab);   // kept across tab switches until dismissed
  if (ghOut(t)) {
    const p = ghParts(t);
    panel.innerHTML = `<div class="ck-gh-box"><h3>${esc(t.id)} is out on GitHub${p ? ` as issue #${esc(p.issue)}` : ''}</h3>
      <p>A cloud agent works it there; this ticket does not run here until you take it back. Its card shows the next step.</p></div>`;
    return;
  }
  panel.innerHTML = `<div class="ck-gh-box" data-gh-send="${esc(t.id)}"><h3>Send ${esc(t.id)} to GitHub</h3><p>Loading the preview…</p></div>`;
  let pv;
  try { pv = await getJSON(ghApi(t.id, 'send-preview')); }
  catch (e) { pv = { ok: false, output: String(e.message || e) }; }
  if (gen !== ghPanelGen) return;   // a later call (the Sent panel, a tab switch) or a hide owns the panel now
  if (tab && (tab !== cockpitState || !tab.ghPick)) return;   // another tab, or another place, was picked meanwhile
  const isPublic = /\(PUBLIC\)/.test(pv.output || '');
  // t-093a: send-issue's warnings (no criteria, no plan) are a note above the preview, in the CLI's own words; they don't block.
  const WARN = /^send-issue: warning: /;
  const outLines = String(pv.output || '').split(/\r?\n/);
  const warns = outLines.filter(l => WARN.test(l)).map(l => l.replace(WARN, ''));
  const preview = outLines.filter(l => !WARN.test(l)).join('\n');
  // t-32f9: unpushed commits refuse the send and uncommitted files only warn; either way the cloud would not see them, so offer
  // to commit and push from here (tkt commit-push, after a confirm that names the files and the branch).
  const localChanges = warns.some(w => /have uncommitted or untracked changes/.test(w));
  const cpOffer = /are on no branch of origin/.test(pv.output || '') || localChanges;
  // t-6f51: a changed tracked file is something the cloud would miss, so Create issue waits for Commit and push (or an explicit
  // opt-out); untracked files only get a note. The kinds come from the same list the Commit and push form shows; unreadable = tracked.
  let kinds = { tracked: 0, untracked: 0 };
  if (localChanges) {
    let cp;
    try { cp = await getJSON(ghApi(t.id, 'commit-push-preview')); }
    catch (e) { cp = { ok: false }; }
    if (gen !== ghPanelGen) return;
    if (tab && (tab !== cockpitState || !tab.ghPick)) return;
    const files = cp.ok ? String(cp.output || '').split(/\r?\n/).map(l => /^file: (..) (.+)$/.exec(l)).filter(Boolean) : null;
    kinds = files ? { tracked: files.filter(m => m[1] !== '??').length, untracked: files.filter(m => m[1] === '??').length } : { tracked: 1, untracked: 0 };
  }
  const needPush = pv.ok && kinds.tracked > 0;
  panel.innerHTML = `<div class="ck-gh-box"${pv.ok ? ` data-gh-send="${esc(t.id)}"` : ''}>
      <h3>Send ${esc(t.id)} to GitHub</h3>
      <p>${pv.ok ? 'The issue, exactly as it will be created. Nothing is sent until you press Create issue.' : 'The preview failed, so nothing can be sent yet:'}</p>
      ${warns.length ? `<div class="ck-gh-note" id="ck-gh-note" role="note">${warns.map(w => `<p>${esc(w)}</p>`).join('')}</div>` : ''}
      ${localChanges ? `<h4 class="ck-gh-step" id="ck-gh-step1">Step 1: Commit and push — the cloud only sees what is on GitHub</h4>` : ''}
      ${localChanges && !kinds.tracked && kinds.untracked ? `<p id="ck-gh-untracked">${kinds.untracked} new file${kinds.untracked === 1 ? ' is' : 's are'} not tracked, so the cloud will not see ${kinds.untracked === 1 ? 'it' : 'them'}. You can still create the issue.</p>` : ''}
      ${cpOffer ? `<div class="ck-gh-cp" id="ck-gh-cp"><div class="ck-gh-actions"><button type="button" id="ck-gh-cp-open">Commit and push…</button></div></div>` : ''}
      <pre class="ck-gh-pre" id="ck-gh-preview">${esc(preview)}</pre>
      ${needPush ? `<label class="ck-gh-public"><input type="checkbox" id="ck-gh-skip"> Send without these changes (the cloud will not see them)</label>` : ''}
      ${isPublic ? `<label class="ck-gh-public"><input type="checkbox" id="ck-gh-public"> This repository is public: anyone could read the ticket's notes. Send anyway.</label>` : ''}
      ${localChanges ? `<h4 class="ck-gh-step" id="ck-gh-step2">Step 2: Create issue</h4>` : ''}
      <div class="ck-gh-actions"><button type="button" class="ck-gh-create" id="ck-gh-create"${pv.ok && !needPush ? '' : ' disabled'}>Create issue</button><span class="ck-gh-status" id="ck-gh-status" role="status"></span></div>
    </div>`;
  if (cpOffer) wireCommitPush(t, tab, gen);
  const create = document.getElementById('ck-gh-create');
  const skip = document.getElementById('ck-gh-skip');
  const canCreate = () => pv.ok && (!needPush || skip.checked);
  skip?.addEventListener('change', () => { create.disabled = !canCreate(); });
  create?.addEventListener('click', async () => {
    const pub = document.getElementById('ck-gh-public');
    if (pub && !pub.checked) { document.getElementById('ck-gh-status').textContent = 'Tick the public-repository box first.'; return; }
    // Held before the await: a tab switch replaces the panel, and a late failure must not write into the next one.
    const statusEl = document.getElementById('ck-gh-status'), previewEl = document.getElementById('ck-gh-preview');
    create.disabled = true; create.textContent = 'Sending…';
    let res;
    try { res = await postJSON(ghApi(t.id, 'send'), pub ? { public: true } : {}); }
    catch (e) { res = { ok: false, output: String(e.message || e) }; }
    if (!res.ok) {
      create.disabled = !canCreate(); create.textContent = 'Create issue';
      statusEl.textContent = 'Not sent; nothing changed.';
      previewEl.textContent = res.output || '';
      return;
    }
    const n = (/issues\/([0-9]+)/.exec(res.output || '') || [])[1] || '';
    const url = (/(https:\/\/github\.com\/\S+\/issues\/[0-9]+)/.exec(res.output || '') || [])[1] || '';
    // The start line is the one send-issue prints after "type:" (t-093a): the CLI owns its text, the board only shows it.
    const outL = String(res.output || '').split(/\r?\n/);
    const at = outL.findIndex(l => /type:\s*$/.test(l));
    const line = at >= 0 ? (outL[at + 1] || '').trim() : '';
    // t-0da2: the same prompt as a terminal command, on the line send-issue prints after the prompt; the board never runs it.
    const cmd = (outL.find(l => l.startsWith('From a terminal: ')) || '').slice('From a terminal: '.length).trim();
    if (tab) tab.ghSent = { id: t.id, n, url, line, cmd };
    if (!tab || tab === cockpitState) showSent(panel, t, tab || { ghSent: { id: t.id, n, url, line, cmd } });
    statusById.delete(t.id);
    await loadData();
  });
}

// t-32f9: the Send panel's Commit and push. The list is tkt commit-push --dry-run's, untracked files unticked (one may be a secret);
// nothing runs until the confirm, which names every file and the branch. Then the send preview runs again.
function wireCommitPush(t, tab, gen) {
  const open = document.getElementById('ck-gh-cp-open');
  open?.addEventListener('click', () => showCommitPush(t, tab, gen));
}
async function showCommitPush(t, tab, gen) {
  const box = document.getElementById('ck-gh-cp');
  if (!box) return;
  box.dataset.open = t.id;
  box.innerHTML = '<p>Reading the changes…</p>';
  let pv;
  try { pv = await getJSON(ghApi(t.id, 'commit-push-preview')); }
  catch (e) { pv = { ok: false, output: String(e.message || e) }; }
  if (gen !== ghPanelGen) return;
  if (!pv.ok) { box.innerHTML = `<p>Could not read the changes:</p><pre class="ck-gh-pre">${esc(pv.output || '')}</pre>`; return; }
  const lines = String(pv.output || '').split(/\r?\n/);
  const branch = (lines.find(l => l.startsWith('branch: ')) || '').slice('branch: '.length);
  const name = branch.split(' ')[0];
  const files = lines.map(l => /^file: (..) (.+)$/.exec(l)).filter(Boolean).map(m => ({ path: m[2], untracked: m[1] === '??' }));
  box.innerHTML = `<p>Branch: <code>${esc(branch)}</code></p>
      ${files.length ? `<ul class="ck-gh-cp-files" id="ck-gh-cp-files">${files.map((f, i) => `<li><label><input type="checkbox" data-i="${i}"${f.untracked ? '' : ' checked'}> <code>${esc(f.path)}</code> <span class="ck-gh-cp-st">${f.untracked ? 'new, not tracked' : 'changed'}</span></label></li>`).join('')}</ul>` : '<p>No uncommitted files: only the commits already here are pushed.</p>'}
      ${files.length ? `<label class="ck-gh-cp-msg">Commit message <input type="text" id="ck-gh-cp-msg" maxlength="200" value="${escAttr(`chore: ${t.id} work for the cloud session`)}"></label>` : ''}
      <div class="ck-gh-actions"><button type="button" class="ck-gh-create" id="ck-gh-cp-go">Commit and push</button><button type="button" id="ck-gh-cp-cancel">Cancel</button><span class="ck-gh-status" id="ck-gh-cp-status" role="status"></span></div>
      <pre class="ck-gh-pre" id="ck-gh-cp-out" hidden></pre>`;
  document.getElementById('ck-gh-cp-cancel').addEventListener('click', () => {
    delete box.dataset.open;
    box.innerHTML = '<div class="ck-gh-actions"><button type="button" id="ck-gh-cp-open">Commit and push…</button></div>';
    wireCommitPush(t, tab, gen);
  });
  document.getElementById('ck-gh-cp-go').addEventListener('click', async () => {
    const status = document.getElementById('ck-gh-cp-status');
    const chosen = [...box.querySelectorAll('#ck-gh-cp-files input[type=checkbox]:checked')].map(b => files[+b.dataset.i].path);
    const msg = (document.getElementById('ck-gh-cp-msg')?.value || '').trim();
    if (chosen.length && !msg) { status.textContent = 'Write a commit message first.'; return; }
    const choice = await openDialog({
      title: `Commit and push ${t.id}?`,
      body: chosen.length ? `Commits ${chosen.length} file(s) on ${name}, then pushes ${name} to origin. Never forced.` : `Pushes ${name} to origin. Never forced.`,
      pre: chosen.length ? `${chosen.join('\n')}\n\nmessage: ${msg}` : '',
      ok: 'Commit and push', cancel: 'Cancel', escape: true,
    });
    if (!choice || !choice.ok || gen !== ghPanelGen) return;
    status.textContent = 'Committing and pushing…';
    let res;
    try { res = await postJSON(ghApi(t.id, 'commit-push'), chosen.length ? { files: chosen, message: msg } : {}); }
    catch (e) { res = { ok: false, output: String(e.message || e) }; }
    if (gen !== ghPanelGen) return;
    if (!res.ok) {
      status.textContent = 'Not pushed; see why below.';
      const outEl = document.getElementById('ck-gh-cp-out');
      if (outEl) { outEl.textContent = res.output || ''; outEl.hidden = false; }
      return;
    }
    showToast(`Pushed ${name} to origin.`);
    hideGithubPanel();
    showGithubPanel(t, tab);   // the send preview runs again on what origin has now
  });
}

function showSent(panel, t, tab) {
  const { n, url, line, cmd } = tab.ghSent;
  panel.innerHTML = `<div class="ck-gh-box ck-gh-sent" id="ck-gh-sent">
      <h3>Sent ${esc(t.id)} as issue #${esc(n)}</h3>
      ${line ? `<p>Start a Claude cloud session on the canon environment and type:</p><pre class="ck-gh-pre ck-gh-prompt" id="ck-gh-prompt">${esc(line)}</pre>${cmd ? `<p>Or paste this in a terminal window in this project (a real terminal; it is refused inside a Claude session):</p><pre class="ck-gh-pre ck-gh-prompt" id="ck-gh-cmd">${esc(cmd)}</pre>` : ''}` : `<p>Start a Claude cloud session on the canon environment and point it at issue #${esc(n)}.</p>`}
      <p>The card is in In progress and shows the next step.</p>
      <p class="ck-gh-prereq" id="ck-gh-prereq">First time on this repository? The cloud session needs the Claude GitHub App installed on it and the canon environment (Factory › GitHub › Cloud environment). After you change the environment's setup script, start a new session: an open one keeps the old script.</p>
      <div class="ck-gh-actions">${cmd ? `<button type="button" class="ck-gh-create" id="ck-gh-to-cloud" title="Open the Terminal with the command typed (you press Enter)">To Claude Cloud</button><button type="button" id="ck-gh-copy-cmd">Copy command</button>` : ''}${line ? `<button type="button" id="ck-gh-copy">Copy prompt</button>` : ''}${url ? `<button type="button" id="ck-gh-open" title="Issue #${esc(n)} on GitHub">Issue ↗</button>` : ''}<button type="button" id="ck-gh-dismiss">Close tab</button><span class="ck-gh-status" id="ck-gh-status" role="status"></span></div>
    </div>`;
  const copyText = async (text) => {
    const s = document.getElementById('ck-gh-status');
    try { await navigator.clipboard.writeText(text); s.textContent = 'Copied.'; return true; }
    catch { s.textContent = `Copy was blocked: select "${text}" above.`; return false; }
  };
  document.getElementById('ck-gh-copy')?.addEventListener('click', () => copyText(line));
  document.getElementById('ck-gh-copy-cmd')?.addEventListener('click', () => copyText(cmd));
  // t-0aa7: To Claude Cloud opens the board's Terminal with `tkt send-issue <id> --launch` typed and not sent (the ticket is already sent:
  // tkt then starts the session on its issue and creates nothing). On Windows the Terminal cannot run it yet: copy the line instead.
  document.getElementById('ck-gh-to-cloud')?.addEventListener('click', async () => {
    if (!/^t-[a-z0-9]{4}$/.test(t.id)) return;
    const typed = `tkt send-issue ${t.id} --launch`;
    if (isWindowsBrowser()) {
      await copyText(typed);
      document.getElementById('ck-gh-status').textContent = 'Windows: paste this in PowerShell or Git Bash in the project folder and press Enter. The board\'s Terminal cannot start a cloud session on Windows yet.';
      return;
    }
    const copied = await copyText(typed);   // t-3d04: also copied, so it is ready to paste while the Terminal starts
    await openTerminalPane('below', { fresh: true, typeLine: typed });   // t-ccf5: under this tab, so the Sent panel stays on screen
    // opening the Terminal rebuilds this panel, which clears the status: say it after
    const status = document.getElementById('ck-gh-status');
    if (status) status.textContent = copied ? 'Copied. It is also typed in the Terminal: press Enter.' : 'Copy was blocked, but the command is typed in the Terminal: press Enter.';
  });
  document.getElementById('ck-gh-open')?.addEventListener('click', () => openUrl(url));
  // The work is in the cloud now, so the tab has nothing left to show: close it (closeTab never ends a session).
  document.getElementById('ck-gh-dismiss').addEventListener('click', () => {
    tab.ghSent = null; hideGithubPanel();
    if (tab.id) closeTab(tab.id);
  });
}

// ── GitHub Sync (t-90a3): the dry run first, then one sync on Create ──────────────────────────────────────────
const SYNC_WARNING = 'The label admits an issue; it does not vouch for it. An author can edit the text after it is labelled, and an issue template can apply the label. Read the issues before creating them.';
// The preview as a table: Idx, Issue, Reason and a checkbox per row. A waiting issue starts ticked; a skipped one is disabled and its
// Reason says why (and, for a ticket closed here, to close the issue on GitHub). Every cell is text: a title is GitHub's, not ours.
function syncRows(intake) {
  const waiting = (intake.waiting || []).map(w => ({ issue: w.issue, title: w.title, reason: `new: becomes a ${w.type} ticket (P${w.priority})`, pickable: true }));
  const skipped = (intake.skipped || []).map(s => ({ issue: s.issue, title: s.title || '', reason: s.reason, pickable: false }));
  return waiting.concat(skipped).sort((a, b) => b.issue - a.issue);
}
function syncTable(rows, onChange) {
  const t = document.createElement('table'); t.className = 'lb-table gh-sync-table';
  const head = t.createTHead().insertRow();
  for (const h of ['Idx', 'Issue', 'Reason', '']) { const th = document.createElement('th'); th.textContent = h; if (!h) th.setAttribute('aria-label', 'Create'); head.append(th); }
  const body = t.createTBody();
  rows.forEach((r, i) => {
    const tr = body.insertRow();
    tr.insertCell().textContent = String(i + 1);
    const issue = tr.insertCell(); const num = document.createElement('b'); num.textContent = '#' + r.issue;
    issue.append(num, ' ' + r.title);
    const why = tr.insertCell(); why.className = 'gh-sync-why'; why.textContent = r.reason;
    const box = document.createElement('input'); box.type = 'checkbox'; box.checked = r.pickable; box.disabled = !r.pickable; box.dataset.issue = String(r.issue);
    box.setAttribute('aria-label', `Create #${r.issue}`); box.addEventListener('change', onChange);
    tr.insertCell().append(box);
    if (!r.pickable) tr.className = 'gh-sync-skip';
  });
  return t;
}
async function syncFromGithub() {
  const shown = openDialog({ title: 'GitHub Sync', pre: 'Reading the issues labelled canon…', ok: 'Create tickets', cancel: 'Cancel', escape: false });
  updateDialog({ okDisabled: true }, shown.gen);
  let res;
  try { res = await getJSON('/api/github/intake'); }
  catch (e) { res = { ok: false, output: String(e.message || e) }; }
  const rows = res.ok && res.intake ? syncRows(res.intake) : [];
  if (!rows.length) {
    updateDialog({ body: res.ok ? 'Nothing to create.' : 'The preview failed; nothing was written.', pre: res.ok ? '' : (res.output || ''), ok: 'Create tickets', okDisabled: true, escape: true }, shown.gen);
  } else {
    const picked = () => [...document.querySelectorAll('#gh-dialog-table input[type=checkbox]:checked')].map(b => +b.dataset.issue);
    const refresh = () => { const n = picked().length; updateDialog({ body: n ? SYNC_WARNING : 'Nothing to create.', okLabel: `Create ${n} selected`, okDisabled: !n }, shown.gen); };
    updateDialog({ pre: '', table: syncTable(rows, refresh), escape: true }, shown.gen);
    refresh();
    // The keyboard starts on the first row you can tick, but only while this dialog is still the one shown: a late reply for a
    // closed one must not take focus from whatever the user has moved to.
    if (dlgGen === shown.gen) (document.querySelector('#gh-dialog-table input:not(:disabled)') || dialog().cancel).focus();
  }
  const choice = await shown;
  if (!choice.ok) return;
  const issues = choice.issues;
  const run = openDialog({ title: 'GitHub Sync', pre: 'Running tkt sync-issues…', cancel: 'Close', escape: false });
  try { res = await postJSON('/api/github/sync', { issues }); }
  catch (e) { res = { ok: false, output: String(e.message || e) }; }
  updateDialog({ body: res.ok ? '' : 'Sync failed.', pre: res.output || '', escape: true }, run.gen);
  await loadData();
}

// While the dialog is open: Escape closes it (unless a merge is running), and Tab stays among its controls.
function dialogKeys(e) {
  if (!dlgClose) return;
  const d = dialog();
  if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); if (dlgEscape) dlgClose({ ok: false }); return; }
  if (e.key !== 'Tab') return;
  const items = [...d.table.querySelectorAll('input[type=checkbox]'), d.check, d.ok, d.cancel].filter(x => x && !x.hidden && !x.disabled && x.offsetParent !== null);
  if (!items.length) return;
  const i = items.indexOf(document.activeElement);
  const next = e.shiftKey ? (i <= 0 ? items.length - 1 : i - 1) : (i === -1 || i === items.length - 1 ? 0 : i + 1);
  e.preventDefault(); items[next].focus();
}

export function initGithub() {
  document.addEventListener('keydown', dialogKeys, true);
  const pre = document.getElementById('gh-dialog-pre');
  pre.addEventListener('scroll', () => { dlgFollow = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 4; });
  document.getElementById('btn-gh-sync').addEventListener('click', syncFromGithub);
  ensureDoctor();   // t-9641: the Sync button's state
  if (!pollTimer) pollTimer = setInterval(() => pollGithub(false), POLL_MS);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) { pollGithub(false); ensureDoctor(); } });
  // t-f053: the Cockpit hides a board with its view container, which fires no visibilitychange in an iframe; it focuses the
  // frame when the board comes back, so a Check fixed in Factory re-enables Sync. ensureDoctor stays bounded by DOCTOR_RETRY_MS.
  window.addEventListener('focus', ensureDoctor);
}
