// t-c6bb: the Logbook — a read-only modal over this project's HANDOFF.md and LEARNINGS.md, opened from the header button (and, in a
// Cockpit tab, from the Projects card's Logbook row). Its only data is GET /api/logbook (the text of the two files); this module
// parses them. The files can come from a PR or a clone, so every piece of their text goes through esc()/md() before it is markup,
// and nothing here writes a file, runs a command or starts an agent. Declarations plus initLogbook(), run by board-main.js.
import { SHELL_TAB } from './board-core.js';
import { esc, escAttr, md } from './board-helpers.js';
import { initDialog } from './board-dialog.js';
import { openModal } from './board-modal.js';
import { findTicketById } from './board-render.js';
import { LOGBOOK_ICON } from './logbook-icon.js';

const NOTES = {
  h: 'HANDOFF.md · updated by the sprint skill',
  l: 'LEARNINGS.md · written by tkt learn, reviewed by promote-learnings',
};
let tab = 'h';
let flt = 'all';
let data = null;      // the last /api/logbook answer, or { fetchError }
let dlg = null;       // the base dialog (board-dialog.js): open/close, Esc, click outside, focus return, move and resize

function between(text, begin, end) {
  const a = text.indexOf(begin);
  if (a < 0) return text;
  const from = a + begin.length;
  const b = text.indexOf(end, from);
  return b < 0 ? text.slice(from) : text.slice(from, b);
}

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

// A table row's cells: `\|` is a literal pipe, a bare `|` ends a cell.
function splitRow(line) {
  const cells = [];
  let cur = '';
  const s = line.trim().replace(/^\|/, '').replace(/\|$/, '');
  for (let i = 0; i < s.length; i++) {
    if (s[i] === '\\' && s[i + 1] === '|') { cur += '|'; i++; } else if (s[i] === '|') { cells.push(cur.trim()); cur = ''; } else cur += s[i];
  }
  cells.push(cur.trim());
  return cells;
}

function statusOf(raw) {
  const s = raw.replace(/`/g, '').trim();
  if (/^unpromoted/i.test(s)) return { kind: 'un', label: 'unpromoted', target: '' };
  if (/^promoted/i.test(s)) return { kind: 'pr', label: 'promoted', target: s.replace(/^promoted\s*(?:→|->)?\s*/i, '') };
  if (/^dismissed/i.test(s)) return { kind: 'dm', label: 'dismissed', target: '' };
  return { kind: 'ot', label: s || 'unknown', target: '' };
}

// Rows of the LEARNINGS.md table between its markers: | date | [t-id](path) | finding | status |
function parseLearnings(text) {
  const rows = [];
  for (const line of between(text, '<!-- canon:learnings:BEGIN -->', '<!-- canon:learnings:END -->').split('\n')) {
    if (!line.trim().startsWith('|')) continue;
    const c = splitRow(line);
    if (c.length < 4 || /^date$/i.test(c[0]) || /^-+$/.test(c[0].replace(/[:\s]/g, ''))) continue;
    const id = /\[?(t-[0-9a-z]+)\]?/i.exec(c[1]);
    rows.push({ date: c[0], id: id ? id[1] : '', finding: c[2], ...statusOf(c.slice(3).join(' | ')) });
  }
  return rows;
}

const el = id => document.getElementById(id);

// md() with images off. md() turns ![alt](url) into an <img> (its src and alt come from the file), and its later transforms (stripping
// <!-- --> comments, restoring code spans) can rebuild that syntax or put markup inside the tag, so a filter over its source or a
// regex over its output can be bypassed (`!<!-- c -->[x](url)`, a code span inside an alt). The result is the thing to check: parse it
// into an inert <template> (it loads and runs nothing) and replace every <img> by its alt text, so no request is made and none of
// the file's attributes survive. md() escapes everything else first, so no other element can come from the file's text.
const safeMd = text => {
  const t = document.createElement('template');
  t.innerHTML = md(text, '');
  t.content.querySelectorAll('img').forEach(i => i.replaceWith('[image: ' + (i.getAttribute('alt') || '') + ']'));
  return t.innerHTML;
};

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
  if (!secs.length) return '<div class="lb-empty">HANDOFF.md has no sections between its markers.</div>';
  return secs.map((s, i) => '<section class="lb-sec' + (i === 0 && /^current focus$/i.test(s.title) ? ' lb-focus' : '') + '"><h3>' + esc(s.title) + '</h3><div class="lb-md">'
    + (s.body ? safeMd(s.body) : '<p class="lb-none">Empty.</p>') + '</div></section>').join('');
}

function renderLearnings() {
  const f = data.learnings;
  const st = fileState(f, 'LEARNINGS.md');
  if (st) return st;
  const rows = parseLearnings(f.text);
  if (!rows.length) return '<div class="lb-empty">LEARNINGS.md has no rows yet.</div>';
  const n = k => rows.filter(r => r.kind === k).length;
  const chip = (k, label, count) => '<button type="button" class="lb-chip" data-f="' + k + '" aria-pressed="' + (flt === k) + '">' + label + ' ' + count + '</button>';
  const shown = rows.filter(r => flt === 'all' || r.kind === flt);
  return '<div class="lb-chips" role="group" aria-label="Filter by status">' + chip('all', 'All', rows.length) + chip('un', 'Unpromoted', n('un')) + chip('pr', 'Promoted', n('pr'))
    + (n('dm') ? chip('dm', 'Dismissed', n('dm')) : '') + '</div><div class="lb-status" id="lb-msg" role="status" aria-live="polite"></div>'
    + '<table class="lb-table"><thead><tr><th>Date</th><th>Ticket</th><th>Finding</th><th>Status</th></tr></thead><tbody>'
    + shown.map(r => '<tr><td class="lb-date">' + esc(r.date) + '</td><td>' + (r.id ? '<button type="button" class="lb-tk" data-t="' + escAttr(r.id) + '">' + esc(r.id) + '</button>' : '')
      + '</td><td class="lb-find">' + safeMd(r.finding) + '</td><td><span class="lb-st lb-st-' + r.kind + '">' + esc(r.label) + '</span>'
      + (r.target ? '<div class="lb-target">' + esc(r.target) + '</div>' : '') + '</td></tr>').join('') + '</tbody></table>';
}

function render() {
  el('lb-tab-h').setAttribute('aria-selected', tab === 'h');
  el('lb-tab-l').setAttribute('aria-selected', tab === 'l');
  el('lb-note').textContent = NOTES[tab];
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
  count.hidden = !(data.learnings && data.learnings.text);
  body.innerHTML = tab === 'h' ? renderHandoff() : renderLearnings();
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
    onOpen() { tab = 'h'; flt = 'all'; btn.setAttribute('aria-expanded', 'true'); load(); el('lb-close').focus(); },
    onClose() { btn.setAttribute('aria-expanded', 'false'); },
  });
  btn.addEventListener('click', dlg.open);
  el('lb-tab-h').addEventListener('click', () => { tab = 'h'; render(); });
  el('lb-tab-l').addEventListener('click', () => { tab = 'l'; render(); });
  el('lb-body').addEventListener('click', e => {
    const chip = e.target.closest('[data-f]');
    if (chip) { flt = chip.dataset.f; render(); return; }
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
