// t-ccf5: a Terminal pane next to the tab you are on. `pane = {host, tab}`: `tab` is a Terminal session tab shown as a second pane,
// `host` is what it sits next to: '' for the Board, or another session tab's id. Layout is CSS classes and custom properties only:
// no element moves and no iframe is re-sourced, so a running session is never disturbed. Direction and ratio are kept per project in
// localStorage (a bad stored value is ignored); tab ids are per run and never stored.
//   host '' (the Board): the Cockpit overlay shrinks to one rectangle (below or beside the window) so the board stays live in the other.
//   host a session tab:  the overlay stays full; inside #ck-term the host's iframe and the Terminal's iframe are both shown.
import { state } from './board-core.js';
import { bindSplitHandle, clampRatio, validRatio } from './split-handle.js';

const MIN = { below: 220, beside: 280 };   // the smallest either pane gets, px (the shell split's numbers)
let pane = null;                            // {host, tab} or null
let dir = 'below', ratio = .5;              // ratio = the host's share of its container

const key = () => 'canon-ck-pane:' + ((state.git && state.git.root) || '');
function load() {
  let s = null; try { s = JSON.parse(localStorage.getItem(key()) || 'null'); } catch (e) {}
  if (s && typeof s === 'object') { dir = s.dir === 'beside' ? 'beside' : 'below'; ratio = validRatio(s.ratio); }
}
function save() { try { localStorage.setItem(key(), JSON.stringify({ dir, ratio })); } catch (e) {} }

export const paneTabId = () => (pane ? pane.tab : null);
export const paneHostId = () => (pane ? pane.host : null);
export function setPane(host, tab, d) { load(); pane = { host, tab }; dir = d === 'beside' ? 'beside' : 'below'; save(); }
export function clearPaneFor(id) { if (pane && (pane.tab === id || pane.host === id)) pane = null; }

// The rectangle the two panes share: the window for the Board, the terminal area (#ck-term) for a session tab.
function boxOf(host) {
  if (host === '') return { left: 0, top: 0, width: window.innerWidth, height: window.innerHeight };
  const r = document.getElementById('ck-term').getBoundingClientRect();
  return { left: r.left, top: r.top, width: r.width, height: r.height };
}
// Is there room for two panes of at least the minimum size in `d`? host '' = the Board, else a session tab.
export function paneRoom(host, d) {
  if (host !== '' && !document.getElementById('cockpit-overlay').classList.contains('open')) return false;
  const b = boxOf(host), total = d === 'beside' ? b.width : b.height;
  return total > 2 * (MIN[d] + 3) + (host === '' ? 120 : 0);   // beside the Board also needs the board itself to stay usable
}

// Which tab ids are on screen when `activeId` is the active tab (the overlay open or not)? One, or the pair.
export function shownIds(activeId, open) {
  if (open && pane && pane.host !== '' && (activeId === pane.host || activeId === pane.tab)) return new Set([pane.host, pane.tab]);
  return new Set([activeId]);
}

// Called whenever the active tab, the overlay or the window changes.
export function applyPane(activeId, open, tabs) {
  const ov = document.getElementById('cockpit-overlay'), h = document.getElementById('ck-pane-handle'), ck = document.getElementById('cockpit'), term = document.getElementById('ck-term');
  if (!ov || !h || !term) return;
  const both = !!(pane && tabs[pane.tab] && (pane.host === '' || tabs[pane.host]));
  if (pane && !both) pane = null;
  const board = !!pane && pane.host === '', sess = !!pane && pane.host !== '';
  const onBoard = !!(open && board && activeId === pane.tab && paneRoom('', dir));
  const onSess = !!(open && sess && (activeId === pane.host || activeId === pane.tab) && paneRoom(pane.host, dir));
  ov.classList.toggle('ck-pane-below', onBoard && dir === 'below');
  ov.classList.toggle('ck-pane-beside', onBoard && dir === 'beside');
  term.classList.toggle('ck-split-below', onSess && dir === 'below');
  term.classList.toggle('ck-split-beside', onSess && dir === 'beside');
  for (const [id, t] of Object.entries(tabs)) {
    if (t.iframeEl) {
      t.iframeEl.classList.toggle('ck-pane1', onSess && id === pane.host);
      t.iframeEl.classList.toggle('ck-pane2', onSess && id === pane.tab);
    }
  }
  const on = onBoard || onSess;
  h.hidden = !on;
  if (!on) { ov.style.removeProperty('--ckr'); term.style.removeProperty('--ckr'); return; }
  const b = boxOf(pane.host);
  ratio = clampRatio(ratio, dir === 'beside' ? b.width : b.height, MIN[dir]);
  (onBoard ? ov : term).style.setProperty('--ckr', ratio);
  // the handle sits on the seam, in window coordinates
  const px = dir === 'beside' ? b.left + ratio * b.width : b.top + ratio * b.height;
  Object.assign(h.style, dir === 'beside'
    ? { left: px - 3 + 'px', top: b.top + 'px', width: '6px', height: b.height + 'px' }
    : { left: b.left + 'px', top: px - 3 + 'px', width: b.width + 'px', height: '6px' });
  h.dataset.dir = dir;
  h.setAttribute('aria-orientation', dir === 'below' ? 'horizontal' : 'vertical');
  h.setAttribute('aria-valuenow', Math.round(ratio * 100));
  if (onBoard && dir === 'beside') ck.classList.add('rail-collapsed');   // beside the Board there is no room for the rail too; the < button (or w) still opens it
}

export const paneOn = () => { const h = document.getElementById('ck-pane-handle'); return !!h && !h.hidden; };

export function initPane(reapply) {
  const h = document.getElementById('ck-pane-handle');
  if (!h) return;
  bindSplitHandle(h, {
    active: paneOn, dir: () => (dir === 'below' ? 'v' : 'h'),
    box: () => boxOf(pane ? pane.host : ''), get: () => ratio,
    set: r => { const b = boxOf(pane ? pane.host : ''); ratio = clampRatio(r, dir === 'beside' ? b.width : b.height, MIN[dir]); reapply(); }, done: save,
  });
  window.addEventListener('resize', reapply);
}
