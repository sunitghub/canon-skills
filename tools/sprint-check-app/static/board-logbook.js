// t-c6bb: the Logbook — a read-only modal over this project's HANDOFF.md and LEARNINGS.md, opened from the header button (and, in a
// Cockpit tab, from the Projects card's Logbook row). Its only data is GET /api/logbook (the text of the two files); this module
// parses them. The files can come from a PR or a clone, so every piece of their text goes through esc()/md() before it is markup,
// and nothing here writes a file, runs a command or starts an agent. Declarations plus initLogbook(), run by board-main.js.
import { SHELL_TAB } from './board-core.js';
import { esc, escAttr } from './board-helpers.js';
import { safeMd } from './markdown.js';
import { initDialog } from './board-dialog.js';
import { openModal } from './board-modal.js';
import { findTicketById } from './board-render.js';
import { LOGBOOK_ICON } from './logbook-icon.js';
import { between, parseLearnings, parsePromoted, PROMOTED_CAP } from './learnings-parse.js';

const NOTES = {
  h: 'HANDOFF.md · updated by the sprint skill',
  l: 'LEARNINGS.md · written by tkt learn, reviewed by promote-learnings',
  p: hasFile => hasFile ? 'PROMOTED.md · written by promote-learnings, loaded by every session' : 'LEARNINGS.md · rows marked promoted by promote-learnings',
  d: 'DECISIONS.md · the project\'s durable choices',
};
// t-3942: what each tab is, under the tab bar (user: the tabs gave no hint). t-7f7c: Learnings names where a keeper goes for this kind of project.
const INTROS = {
  h: 'Where work stands between sessions: what is in progress, what is next, and gotchas found along the way. An agent reads it when a session starts and updates it as work moves.',
  l: dest => 'Lessons from closed sprints that wait for a fresh-eyes review (/promote-learnings). The review moves each keeper into ' + dest + ' and dismisses the rest; handled rows leave this list and stay in LEARNINGS.md.',
  p: hasFile => hasFile ? 'The rules agents load at the start of every session, from PROMOTED.md. Read-only here: promote-learnings adds them.'
    : 'Lessons a review moved into a standards or reference file. This project has no PROMOTED.md, so the list comes from the LEARNINGS.md rows marked promoted.',
  d: 'The project\'s durable choices, newest first, from DECISIONS.md. Read-only.',
};
const TABS = ['h', 'l', 'p', 'd'];
let tab = 'h';
let data = null;      // the last /api/logbook answer, or { fetchError }
let dlg = null;       // the base dialog (board-dialog.js): open/close, Esc, click outside, focus return, move and resize

// ## sections of HANDOFF.md between its markers, in file order (text before the first ## heading is not a section).
function parseHandoff(text) {
  const out = [];
  let cur = null;
  for (const line of between(text, '<!-- canon:handoff:BEGIN -->', '<!-- canon:handoff:END -->').split('\n')) {
    const m = /^##\s+(.+?)\s*$/.exec(line);
    if (m) { cur = { title: m[1], body: [] }; out.push(cur); } else if (cur) cur.body.push(line);
  }
  return out.map(s => ({ title: s.title, body: s.body.join('\n').trim() }));
}

// t-eecb: the lines canon itself wrote between the canon:recent markers ("- 11-05 09:47 · t-c662 · sprint completed"), in file order.
// Not a section of the handoff block (edits there are replaced), so it is parsed apart and shown read-only. None: [].
function parseRecent(text) {
  const A = '<!-- canon:recent:BEGIN -->', Z = '<!-- canon:recent:END -->';
  const a = text.indexOf(A), z = a < 0 ? -1 : text.indexOf(Z, a + A.length);
  if (a < 0 || z < 0) return [];   // both markers, or nothing: a stray BEGIN in prose must not turn the rest of the file into "activity"
  return text.slice(a + A.length, z).split('\n')
    .map(l => l.trim()).filter(l => l.startsWith('- ')).map(l => l.slice(2).trim())
    .filter(l => l && l !== 'No stage recorded yet.');   // what canon writes for a block with no events
}

const el = id => document.getElementById(id);

function fileState(f, name) {
  if (!f) return '<div class="lb-empty">' + esc(name) + ' was not in the answer.</div>';
  if (f.missing) return '<div class="lb-empty"><b>No ' + esc(name) + ' in this project</b>It appears here once the project has one.</div>';
  if (f.error) return '<div class="lb-empty lb-err" role="alert"><b>' + esc(name) + ' could not be read</b>' + esc(f.error) + '</div>';
  return '';
}

function renderHandoff() {
  const f = data.handoff;
  const st = fileState(f, 'HANDOFF.md');
  if (st) return st;
  const secs = parseHandoff(f.text);
  const recent = parseRecent(f.text);
  const recentHtml = recent.length ? '<section class="lb-sec lb-recent"><h3>Recent activity <span class="lb-gen">written by canon from the activity log</span></h3><div class="lb-md"><ul>'
    + recent.map(l => '<li>' + esc(l) + '</li>').join('') + '</ul></div></section>' : '';
  if (!secs.length) return recentHtml || '<div class="lb-empty">HANDOFF.md has no sections between its markers.</div>';
  return recentHtml + secs.map((s, i) => '<section class="lb-sec' + (i === 0 && /^current focus$/i.test(s.title) ? ' lb-focus' : '') + '"><h3>' + esc(s.title) + '</h3><div class="lb-md">'
    + (s.body ? safeMd(s.body) : '<p class="lb-none">Empty.</p>') + '</div></section>').join('');
}

const hasPromotedFile = () => !!(data.promoted && data.promoted.text !== undefined);
const rowsOf = f => (f && f.text ? parseLearnings(f.text) : []);

function learnRow(r, withStatus) {
  return '<tr><td class="lb-date">' + esc(r.date) + '</td><td>' + (r.id ? '<button type="button" class="lb-tk" data-t="' + escAttr(r.id) + '">' + esc(r.id) + '</button>' : '')
    + '</td><td class="lb-find">' + safeMd(r.finding) + '</td><td class="lb-stc"><span class="lb-st lb-st-' + r.kind + '"' + (r.raw ? ' title="' + escAttr(r.raw) + '"' : '') + '>' + esc(r.label) + '</span>'
    + (withStatus && r.target ? '<div class="lb-target" title="' + escAttr(r.target) + '">' + esc(r.target) + '</div>' : '') + '</td></tr>';
}
const learnTable = (rows, head) => '<div class="lb-status" id="lb-msg" role="status" aria-live="polite"></div><table class="lb-table"><thead><tr><th>Date</th><th>Ticket</th><th>Finding</th><th>' + head
  + '</th></tr></thead><tbody>' + rows.join('') + '</tbody></table>';

// t-7f7c: only the rows still waiting; promoted, dismissed and unknown rows are hidden (they stay in the files)
function renderLearnings() {
  const f = data.learnings;
  const st = fileState(f, 'LEARNINGS.md');
  if (st) return st;
  const rows = parseLearnings(f.text).filter(r => r.kind === 'un');
  if (!rows.length) return '<div class="lb-empty"><b>Nothing waiting for review</b>New lessons appear here when a sprint closes.</div>';
  return learnTable(rows.map(r => learnRow(r, false)), 'Status');
}

function renderPromoted() {
  if (hasPromotedFile()) {
    const { entries, lines } = parsePromoted(data.promoted.text);
    const cap = '<div class="lb-cap' + (lines > PROMOTED_CAP ? ' lb-cap-over' : '') + '" id="lb-cap">' + lines + ' of ' + PROMOTED_CAP + ' lines</div>';
    if (!entries.length) return cap + '<div class="lb-empty"><b>Nothing promoted yet</b>PROMOTED.md has no entries between its markers.</div>';
    return cap + '<ul class="lb-rules">' + entries.map(e => '<li><span class="lb-rule">' + safeMd(e.text) + '</span>'
      + (e.id ? ' <button type="button" class="lb-tk" data-t="' + escAttr(e.id) + '">' + esc(e.id) + '</button>' : '') + '</li>').join('') + '</ul>'
      + '<div class="lb-status" id="lb-msg" role="status" aria-live="polite"></div>';
  }
  const st = data.promoted && data.promoted.error ? fileState(data.promoted, 'PROMOTED.md') : '';
  if (st) return st;
  const rows = rowsOf(data.learnings).concat(rowsOf(data.learnings_archive)).filter(r => r.kind === 'pr' && r.target);
  if (!rows.length) return '<div class="lb-empty"><b>Nothing promoted yet</b>Rows appear here once a review marks them promoted.</div>';
  return learnTable(rows.map(r => learnRow(r, true)), 'Promoted to');
}

// newest first, by each entry's leading date. Two shapes: a table of dated rows, or dated
// `## 2026-10-22 — t-xxxx: title` sections each followed by prose; a file can hold both (canon's appends sections after its table),
// so rows and sections are one list. t-40f8: only the newest DECISIONS_SHOWN are rendered (canon's file has 500+); the rest stay in
// the file. A tie on the date keeps the block's own order of writing: a table whose first row is its newest (canon inserts rows under
// the header) puts its earlier row first; appended sections put the later one first. Blank lines around headings and tables are dropped so
// a block starts right under the one above.
const DECISIONS_SHOWN = 150;
const dateOf = t => (/(\d{4}-\d{2}-\d{2})/.exec(t) || [])[1] || '';
const newestFirst = items => items.map(x => ({ x, d: dateOf(x.key) })).sort((a, b) => (a.d < b.d ? 1 : a.d > b.d ? -1 : b.x.ord - a.x.ord)).map(o => o.x);
function decisionsMd(text) {
  const lines = text.split('\n');
  const isRow = l => l.trim().startsWith('|');
  const isSec = l => /^##\s/.test(l);
  const first = lines.findIndex(l => isRow(l) || isSec(l));
  if (first < 0) return { md: text, total: 0 };
  const items = [], after = [];
  let header = [], i = first;
  if (isRow(lines[first])) {
    header = lines.slice(first, first + 2);
    for (i = first + 2; i < lines.length && isRow(lines[i]); i++) items.push({ key: lines[i].split('|')[1] || '', text: lines[i], row: true });
    const rows = items.length, down = rows > 1 && dateOf(items[0].key) > dateOf(items[rows - 1].key);   // a newest-first table
    items.forEach((it, k) => { it.ord = down ? rows - k : k; });
  }
  for (; i < lines.length; i++) {
    if (isSec(lines[i])) items.push({ key: lines[i], text: lines[i], ord: items.length + 1 });
    else if (items.length && !items[items.length - 1].row) items[items.length - 1].text += '\n' + lines[i];
    else if (lines[i].trim()) after.push(lines[i]);   // prose between a table and the first section stays below
  }
  const shown = newestFirst(items).slice(0, DECISIONS_SHOWN);
  const out = lines.slice(0, first);
  shown.forEach((it, k) => {
    if (it.row) { if (k === 0 || !shown[k - 1].row) out.push('', ...header); out.push(it.text); }
    else out.push('', it.text.replace(/\s+$/, ''));
  });
  if (after.length) out.push('', ...after);
  return { md: out.join('\n').replace(/(^#{1,6}\s[^\n]*)\n\n+/gm, '$1\n').trim(), total: items.length };
}

function renderDecisions() {
  const f = data.decisions;
  const st = fileState(f, 'DECISIONS.md');
  if (st) return st;
  const { md, total } = decisionsMd(f.text);
  // a heading is a block: the line break after it would show as an empty line, so the next block starts right under it
  const html = safeMd(md).replace(/(<strong class="doc-heading-[123]">[^<\n]*<\/strong>)\n+/g, '$1');
  const note = total > DECISIONS_SHOWN ? '<p class="lb-cap" id="lb-dec-note">Showing the newest ' + DECISIONS_SHOWN + ' of ' + total + ' decisions. Older ones are in DECISIONS.md.</p>' : '';
  return note + '<div class="lb-md lb-decisions">' + html + '</div>';
}

function render() {
  for (const t of TABS) el('lb-tab-' + t).setAttribute('aria-selected', tab === t);
  const pf = !!(data && !data.fetchError && hasPromotedFile());
  el('lb-note').textContent = tab === 'p' ? NOTES.p(pf) : NOTES[tab];
  el('lb-intro').textContent = tab === 'l' ? INTROS.l(pf ? 'PROMOTED.md' : 'canon\'s standards and reference docs') : tab === 'p' ? INTROS.p(pf) : INTROS[tab];
  const body = el('lb-body');
  const count = el('lb-count');
  if (!data) { body.innerHTML = '<div class="lb-empty">Loading…</div>'; count.hidden = true; return; }
  if (data.fetchError) {
    body.innerHTML = '<div class="lb-empty lb-err" role="alert"><b>The Logbook could not be loaded</b>' + esc(data.fetchError) + '<div><button type="button" class="lb-chip" data-reload="1">Try again</button></div></div>';
    count.hidden = true;
    return;
  }
  const un = data.learnings && data.learnings.text ? parseLearnings(data.learnings.text).filter(r => r.kind === 'un').length : 0;
  count.textContent = un;
  count.hidden = !un;   // the badge is the number still to review: nothing to review, no badge
  count.title = un + ' unpromoted';
  body.innerHTML = { h: renderHandoff, l: renderLearnings, p: renderPromoted, d: renderDecisions }[tab]();
}

async function load() {
  data = null;
  render();
  try {
    const r = await fetch('/api/logbook');
    // a board started before this route existed answers 404 for it: say that, not just the number
    data = r.ok ? await r.json() : { fetchError: r.status === 404 ? 'This board is older than the Logbook. Restart it (canon) to load the new version.' : 'HTTP ' + r.status };
  } catch (e) {
    data = { fetchError: String((e && e.message) || e) };
  }
  render();
}

export function initLogbook() {
  const btn = el('btn-logbook');
  btn.insertAdjacentHTML('afterbegin', LOGBOOK_ICON);
  dlg = initDialog({
    overlayId: 'logbook-overlay', panelId: 'logbook-modal', closeId: 'lb-close', fallbackFocusId: 'btn-logbook',
    onOpen() { tab = 'h'; btn.setAttribute('aria-expanded', 'true'); load(); el('lb-close').focus(); },
    onClose() { btn.setAttribute('aria-expanded', 'false'); },
  });
  btn.addEventListener('click', dlg.open);
  for (const t of TABS) el('lb-tab-' + t).addEventListener('click', () => { tab = t; render(); });
  el('lb-body').addEventListener('click', e => {
    if (e.target.closest('[data-reload]')) { load(); return; }
    const tk = e.target.closest('[data-t]');
    if (!tk) return;
    const id = tk.dataset.t;
    if (findTicketById(id)) { dlg.close(); openModal(id); return; }
    const msg = el('lb-msg');
    if (msg) msg.textContent = id + ' is not on this board.';
  });
  // In a Cockpit tab the shell's Projects card can ask this board to open its Logbook; it repeats the request until it hears back.
  window.addEventListener('message', e => {
    if (e.origin !== location.origin || e.source !== window.parent) return;
    const d = e.data;
    if (!d || d.source !== 'canon-cockpit-shell' || d.type !== 'open-logbook') return;
    dlg.open();
    try { window.parent.postMessage({ source: 'canon-board', type: 'logbook-opened', tab: SHELL_TAB }, location.origin); } catch { /* no shell */ }
  });
}
