// t-718b: the GitHub workflow on the board. Every action is one route from t-d271, each running one tkt command
// (send-issue, github-status, import-results, merge-pr --check / --yes, take-back); this module adds no logic of its
// own beyond choosing which button a card shows. A ticket with runs: github (and its github: link, no merged: line) is
// out on GitHub: it shows in In progress (board-helpers.js effectiveStatus) with a GitHub chip and one stage button instead of Start.
import { state } from './board-core.js';
import { closeTab, cockpitState } from './board-cockpit.js';
import { esc, escAttr } from './board-helpers.js';
import { render, showToast } from './board-render.js';
import { loadData, SHELL_TAB } from './board-core.js';
import { renderCockpitWorktree } from './board-worktree.js';

const POLL_MS = 120000;          // github-status per card out on GitHub; the server caches each for 30 s
const MERGE_POLL_MS = 2000;
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
  if (st.stage === 'results-ready') return btn('import', 'Import results', 'Bring the cloud session\'s results back into this ticket');
  if (st.stage === 'results-in' || st.stage === 'merging') return btn('merge', 'Check & merge', 'Check the PR and merge it after your confirmation');
  if (st.stage === 'pr-open' && prOf(st)) return btn('pr', 'Open PR', `Open PR #${prOf(st)} on GitHub`);
  if (st.stage === 'branch') return btn('open-pr', 'Open PR', `The session pushed ${st.branch} without a PR: open one`);
  return btn('issue', 'Open issue', 'Open the issue on GitHub');
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
}

// ── Open PR (t-24b1): a session pushed its branch and stopped short of a PR ─────────────────────────────────────────
async function openPr(t, p, st) {
  const ask = openDialog({
    title: `Open a PR for ${t.id}?`,
    body: `Opens a pull request on ${p.repo} from ${st.branch} into its default branch, with "Fixes #${p.issue}", so Import results and Check & merge can find it.`,
    ok: 'Open PR', cancel: 'Cancel',
  });
  if (!(await ask).ok) return;
  const run = openDialog({ title: `Opening a PR for ${t.id}…`, pre: 'Running tkt open-pr…', cancel: 'Close' });
  let res;
  try { res = await postJSON(ghApi(t.id, 'open-pr'), {}); }
  catch (e) { res = { ok: false, output: String(e.message || e) }; }
  updateDialog({ title: res.ok ? 'PR opened' : 'No PR opened', body: res.ok ? '' : 'Nothing was created on GitHub.', pre: res.output || '' }, run.gen);
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
    check: document.getElementById('gh-dialog-check'),
    checkLabel: document.getElementById('gh-dialog-check-label'),
    ok: document.getElementById('gh-dialog-ok'),
    cancel: document.getElementById('gh-dialog-cancel'),
  };
}
let dlgClose = null;
let dlgGen = 0;          // which openDialog() the dialog shows: a late answer for an older one must not fill it
let dlgEscape = true;    // a running merge stops only on a click of Stop, never on Escape
let dlgReturn = null;    // where focus goes back to when the dialog closes
// Returns a promise of the choice; .gen is this dialog's number for updateDialog.
function openDialog({ title, body = '', pre = '', check = '', ok = '', cancel = 'Close', escape = true }) {
  const d = dialog();
  if (!d.el.classList.contains('open')) dlgReturn = document.activeElement;
  const gen = ++dlgGen;
  dlgEscape = escape;
  d.title.textContent = title;
  d.body.textContent = body;
  d.pre.textContent = pre; d.pre.hidden = !pre;
  d.check.checked = false; d.checkLabel.hidden = !check;
  d.checkLabel.querySelector('span').textContent = check;
  d.ok.textContent = ok; d.ok.hidden = !ok; d.ok.disabled = false;
  d.cancel.textContent = cancel;
  d.el.classList.add('open');
  const done = new Promise(resolve => {
    dlgClose = v => {
      d.el.classList.remove('open'); dlgClose = null; resolve(v);
      const back = dlgReturn; dlgReturn = null;
      if (back && back.isConnected && typeof back.focus === 'function') back.focus();
    };
    d.ok.onclick = () => dlgClose && dlgClose({ ok: true, checked: d.check.checked });
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
  if ('pre' in fields) { d.pre.textContent = fields.pre; d.pre.hidden = !fields.pre; d.pre.scrollTop = d.pre.scrollHeight; }
  if ('ok' in fields) {
    d.ok.textContent = fields.ok; d.ok.hidden = !fields.ok;
    if (fields.ok) d.ok.focus(); else if (document.activeElement === d.ok || !d.el.contains(document.activeElement)) d.cancel.focus();
  }
  if ('okDisabled' in fields) d.ok.disabled = fields.okDisabled;
  if ('cancel' in fields) d.cancel.textContent = fields.cancel;
}

// ── Import results ──────────────────────────────────────────────────────────────────────────────────────────────────
async function importResults(t, pr) {
  const shown = openDialog({ title: `Importing results for ${t.id}…`, pre: 'Running tkt import-results…', cancel: 'Close' });
  let res;
  try { res = await postJSON(ghApi(t.id, 'import'), pr ? { pr } : {}); }
  catch (e) { res = { ok: false, output: String(e.message || e) }; }
  const noVerdict = /no eval-report\.md|graded-head: none|NOT match graded-head/.test(res.output || '');
  updateDialog({
    title: res.ok ? `Results are back in .tickets/${t.id}/` : (noVerdict ? 'Imported, but the cloud sprint did not close' : 'Import failed'),
    body: res.ok ? 'Next: Check & merge on the card.'
      : noVerdict ? 'There is no passing evaluator verdict on the PR\'s head, so there is nothing to merge yet. Finish the close on this machine: check out the PR\'s branch, run the evaluator on its head and sprint complete, then Check & merge (docs/setup.md › Claude cloud sessions).'
      : 'Nothing was changed.',
    pre: res.output || '',
  }, shown.gen);
  statusById.delete(t.id);
  await loadData();
}

// ── Check & merge ───────────────────────────────────────────────────────────────────────────────────────────────────
async function checkAndMerge(t, pr) {
  const prQ = pr ? `?pr=${encodeURIComponent(pr)}` : '';
  const prB = pr ? { pr } : {};
  if (mergeById.get(t.id)?.status === 'running') return followMerge(t, prB, true);
  const open = openDialog({ title: `Check & merge${pr ? ` PR #${pr}` : ''}`, body: 'Running the checks that run none of the PR\'s code…', pre: '', ok: '', cancel: 'Cancel' });
  let chk;
  try { chk = await getJSON(ghApi(t.id, 'merge-check') + prQ); }
  catch (e) { chk = { ok: false, output: String(e.message || e) }; }
  if (!chk.ok) {
    updateDialog({ body: 'Not mergeable here. Nothing was run or changed.', pre: chk.output || '', cancel: 'Close' }, open.gen);
    return;
  }
  updateDialog({
    body: 'Running the tests runs the PR\'s code on this machine. Nothing from the PR runs before you press the button.',
    pre: chk.output || '', ok: 'Run tests & merge', cancel: 'Cancel',
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
      if (gen !== undefined) { updateDialog({ title: 'Lost contact', body: 'The board stopped hearing about this merge. It may still be running: check the ticket in a few minutes.', cancel: 'Close' }, gen); if (gen === dlgGen) dlgEscape = true; }
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
  if (gen !== undefined) updateDialog({
    title: merged ? 'Merged' : 'Not merged',
    body: merged ? `The PR is merged and the issue closed by its Fixes line.${offer ? ` Also push main to ${mirrors.join(', ')} (git config canon.mirror)?` : ''}` : 'Nothing changed on GitHub. See the output.',
    pre: st?.output || '', ok: offer, cancel: 'Close',
  }, gen);
  if (gen !== undefined && gen === dlgGen) dlgEscape = true;
  if (offer && shown) shown.then(v => { if (v && v.ok) pushMain(mirrors); });
  statusById.delete(t.id);
  await loadData();
}

async function pushMain(mirrors) {
  const run = openDialog({ title: `Pushing main to ${mirrors.join(', ')}…`, pre: 'Running tkt push-main…', cancel: 'Close' });
  let res;
  try { res = await postJSON('/api/github/push-main', {}); }
  catch (e) { res = { ok: false, output: String(e.message || e) }; }
  updateDialog({ title: res.ok ? 'Pushed' : 'Not every mirror was pushed', body: res.ok ? '' : 'Nothing was forced. See the output.', pre: res.output || '' }, run.gen);
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

// ── The worktree picker's GitHub rows, and the panel shown instead of the terminal ──────────────────────────────────
// ── Readiness (t-24b1): the picker's GitHub row reads t-90a3's doctor, the one source of the checks ─────────────────
const DOCTOR_RETRY_MS = 30000;
let doctor = { state: 'unknown' };   // unknown | pending | ready | bad; ready and bad carry n (not bad) of m checks
let doctorAt = 0;
let doctorFor = null;   // the ticket whose picker drew the "checking…" row
function ensureDoctor(t) {
  doctorFor = t;
  if (doctor.state === 'pending' || doctor.state === 'ready') return;
  if (doctor.state === 'bad' && Date.now() - doctorAt < DOCTOR_RETRY_MS) return;
  doctor = { state: 'pending' }; doctorAt = Date.now();
  getJSON('/api/github/doctor').then(res => {
    const checks = res && res.ok && res.doctor && Array.isArray(res.doctor.checks) ? res.doctor.checks : null;
    const n = checks ? checks.filter(c => c && c.status !== 'bad').length : 0, m = checks ? checks.length : 0;
    doctor = { state: checks && n === m ? 'ready' : 'bad', n, m };
  }, () => { doctor = { state: 'bad', n: 0, m: 0 }; }).then(() => {
    // The picker drew a "checking…" row for t: draw it again with the answer, if it still shows one.
    if (t && document.querySelector('.ck-gh-checking')) renderCockpitWorktree(t);
  });
}
function openAdminGithub() {
  if (window.parent === window) { showToast('GitHub is not set up for this project: run tkt github-doctor in a terminal'); return; }
  window.parent.postMessage({ source: 'canon-board', type: 'open-admin-github', tab: SHELL_TAB }, location.origin);
}
export function bindGithubPickerRows(box) {
  box.querySelectorAll('.ck-gh-setup').forEach(row => row.addEventListener('click', openAdminGithub));
  // The picker builds its rows before an await: an answer that landed in between found no row to redraw, so redraw now.
  if (doctorFor && (doctor.state === 'ready' || doctor.state === 'bad') && box.querySelector('.ck-gh-checking')) renderCockpitWorktree(doctorFor);
}
function githubPlaceRowHTML(t, tab) {
  ensureDoctor(t);
  if (doctor.state === 'unknown' || doctor.state === 'pending') {
    return `<div class="ck-worktree-held-row ck-gh-checking"><span class="ck-worktree-held-branch">GitHub · checking…</span><span class="ck-worktree-held-why">reading the GitHub checks</span></div>`;
  }
  if (doctor.state === 'bad') {
    return `<div class="ck-worktree-held-row ck-gh-setup" role="button" tabindex="0" title="Opens Admin › GitHub, which lists what to fix"><span class="ck-worktree-held-branch">GitHub · set up first (${doctor.n} of ${doctor.m} ready)</span><span class="ck-worktree-held-why">open Admin › GitHub</span></div>`;
  }
  return `<div class="ck-worktree-row ck-gh-row${tab.ghPick ? ' selected' : ''}" data-github="new" title="Sends this ticket as an issue to your repo; a Claude cloud session works it and opens a PR">
      <div class="ck-worktree-radio"></div>
      <div class="ck-worktree-labels"><div class="ck-worktree-label">GitHub · new issue</div><div class="ck-worktree-sub">a Claude cloud session works it</div></div>
    </div>`;
}

export function githubPickerRowsHTML(t, tab) {
  if (!t || t.scratch || t.status !== 'open' || ghOut(t)) return '';
  // A closed or cancelled ticket is not busy in the cloud: one closed by hand never gets merged: (t-093a). ghOut() stays
  // true for it, because a closed, imported ticket still needs its Check & merge button.
  const busy = (state.tickets || []).filter(x => ghOut(x) && x.status !== 'closed' && x.status !== 'cancelled');
  return busy.map(x => {
    const p = ghParts(x);
    return `<div class="ck-worktree-held-row ck-gh-busy"><span class="ck-worktree-held-branch">GitHub${p ? ` #${esc(p.issue)}` : ''}</span><span class="ck-worktree-held-why">cloud · busy: ${esc(x.id)}</span></div>`;
  }).join('') + githubPlaceRowHTML(t, tab);
}

export function hideGithubPanel() {
  const panel = document.getElementById('ck-gh-panel');
  if (panel) { panel.hidden = true; panel.innerHTML = ''; }
}

export async function showGithubPanel(t, tab) {
  const panel = document.getElementById('ck-gh-panel');
  if (!panel) return;
  panel.hidden = false;
  if (tab && tab.ghSent && tab.ghSent.id === t.id) return showSent(panel, t, tab);   // kept across tab switches until dismissed
  if (ghOut(t)) {
    const p = ghParts(t);
    panel.innerHTML = `<div class="ck-gh-box"><h3>${esc(t.id)} is out on GitHub${p ? ` as issue #${esc(p.issue)}` : ''}</h3>
      <p>A Claude cloud session works it there; this ticket does not run here until you take it back. Its card shows the next step.</p></div>`;
    return;
  }
  panel.innerHTML = `<div class="ck-gh-box"><h3>Send ${esc(t.id)} to GitHub</h3><p>Loading the preview…</p></div>`;
  let pv;
  try { pv = await getJSON(ghApi(t.id, 'send-preview')); }
  catch (e) { pv = { ok: false, output: String(e.message || e) }; }
  if (tab && (tab !== cockpitState || !tab.ghPick)) return;   // another tab, or another place, was picked meanwhile
  const isPublic = /\(PUBLIC\)/.test(pv.output || '');
  // t-093a: send-issue's warnings (no criteria, no plan) are a note above the preview, in the CLI's own words; they don't block.
  const WARN = /^send-issue: warning: /;
  const outLines = String(pv.output || '').split(/\r?\n/);
  const warns = outLines.filter(l => WARN.test(l)).map(l => l.replace(WARN, ''));
  const preview = outLines.filter(l => !WARN.test(l)).join('\n');
  panel.innerHTML = `<div class="ck-gh-box">
      <h3>Send ${esc(t.id)} to GitHub</h3>
      <p>${pv.ok ? 'The issue, exactly as it will be created. Nothing is sent until you press Create issue.' : 'The preview failed, so nothing can be sent yet:'}</p>
      ${warns.length ? `<div class="ck-gh-note" id="ck-gh-note" role="note">${warns.map(w => `<p>${esc(w)}</p>`).join('')}</div>` : ''}
      <pre class="ck-gh-pre" id="ck-gh-preview">${esc(preview)}</pre>
      ${isPublic ? `<label class="ck-gh-public"><input type="checkbox" id="ck-gh-public"> This repository is public: anyone could read the ticket's notes. Send anyway.</label>` : ''}
      <div class="ck-gh-actions"><button type="button" class="ck-gh-create" id="ck-gh-create"${pv.ok ? '' : ' disabled'}>Create issue</button><span class="ck-gh-status" id="ck-gh-status" role="status"></span></div>
    </div>`;
  const create = document.getElementById('ck-gh-create');
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
      create.disabled = false; create.textContent = 'Create issue';
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
    if (tab) tab.ghSent = { id: t.id, n, url, line };
    if (!tab || tab === cockpitState) showSent(panel, t, tab || { ghSent: { id: t.id, n, url, line } });
    statusById.delete(t.id);
    await loadData();
  });
}

function showSent(panel, t, tab) {
  const { n, url, line } = tab.ghSent;
  panel.innerHTML = `<div class="ck-gh-box ck-gh-sent" id="ck-gh-sent">
      <h3>Sent ${esc(t.id)} as issue #${esc(n)}</h3>
      ${line ? `<p>Start a Claude cloud session on the canon environment and type:</p><pre class="ck-gh-pre ck-gh-prompt" id="ck-gh-prompt">${esc(line)}</pre>` : `<p>Start a Claude cloud session on the canon environment and point it at issue #${esc(n)}.</p>`}
      <p>The card is in In progress and shows the next step.</p>
      <div class="ck-gh-actions">${line ? `<button type="button" class="ck-gh-create" id="ck-gh-copy">Copy prompt</button>` : ''}${url ? `<button type="button" id="ck-gh-open">Open issue</button>` : ''}<button type="button" id="ck-gh-dismiss">Close tab</button><span class="ck-gh-status" id="ck-gh-status" role="status"></span></div>
    </div>`;
  document.getElementById('ck-gh-copy')?.addEventListener('click', async () => {
    const s = document.getElementById('ck-gh-status');
    try { await navigator.clipboard.writeText(line); s.textContent = 'Copied.'; }
    catch { s.textContent = `Copy was blocked: select "${line}" above.`; }
  });
  document.getElementById('ck-gh-open')?.addEventListener('click', () => openUrl(url));
  // The work is in the cloud now, so the tab has nothing left to show: close it (closeTab never ends a session).
  document.getElementById('ck-gh-dismiss').addEventListener('click', () => {
    tab.ghSent = null; hideGithubPanel();
    if (tab.id) closeTab(tab.id);
  });
}

// ── Sync from GitHub (t-90a3): the dry run first, then one sync on Create ──────────────────────────────────────────
const SYNC_WARNING = 'The label admits an issue; it does not vouch for it. An author can edit the text after it is labelled, and an issue template can apply the label. Read the issues before creating them.';
async function syncFromGithub() {
  const shown = openDialog({ title: 'Sync from GitHub', pre: 'Running tkt sync-issues --dry-run…', ok: 'Create tickets', cancel: 'Cancel' });
  updateDialog({ okDisabled: true }, shown.gen);
  let res;
  try { res = await getJSON('/api/github/sync-preview'); }
  catch (e) { res = { ok: false, output: String(e.message || e) }; }
  const n = res.ok ? +((/dry run: (\d+) to create/.exec(res.output || '') || [])[1] || 0) : 0;
  updateDialog({
    body: res.ok ? (n ? SYNC_WARNING : 'Nothing to create.') : 'The preview failed; nothing was written.',
    pre: res.output || '', ok: `Create ${n} ticket${n === 1 ? '' : 's'}`, okDisabled: !n,
  }, shown.gen);
  if (!(await shown).ok) return;
  const run = openDialog({ title: 'Sync from GitHub', pre: 'Running tkt sync-issues…', cancel: 'Close' });
  try { res = await postJSON('/api/github/sync', {}); }
  catch (e) { res = { ok: false, output: String(e.message || e) }; }
  updateDialog({ body: res.ok ? '' : 'Sync failed.', pre: res.output || '' }, run.gen);
  await loadData();
}

// While the dialog is open: Escape closes it (unless a merge is running), and Tab stays among its controls.
function dialogKeys(e) {
  if (!dlgClose) return;
  const d = dialog();
  if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); if (dlgEscape) dlgClose({ ok: false }); return; }
  if (e.key !== 'Tab') return;
  const items = [d.check, d.ok, d.cancel].filter(x => x && !x.hidden && !x.disabled && x.offsetParent !== null);
  if (!items.length) return;
  const i = items.indexOf(document.activeElement);
  const next = e.shiftKey ? (i <= 0 ? items.length - 1 : i - 1) : (i === -1 || i === items.length - 1 ? 0 : i + 1);
  e.preventDefault(); items[next].focus();
}

export function initGithub() {
  document.addEventListener('keydown', dialogKeys, true);
  document.getElementById('btn-gh-sync').addEventListener('click', syncFromGithub);
  if (!pollTimer) pollTimer = setInterval(() => pollGithub(false), POLL_MS);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) pollGithub(false); });
}
