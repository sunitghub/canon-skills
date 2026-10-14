// t-2758: the shell's "◐ Theme" switcher (themes slice A). Mode decides when it is light or dark (System follows the OS);
// Theme lists only themes of that mode, and under System there is one pick for light and one for dark. The choice is
// saved as { mode, light, dark } under 'canon-theme' (an older 'dark'/'light' still reads). theme-boot.js applies it
// before the first paint; this module keeps it in step and tells every open board. The themes and their colours live
// in theme-data.js (t-4fa5): Canon Dark/Light are today's CSS, a third-party theme sets its derived variables on <html>.
import { esc, toast } from './cockpit-core.js';
import { THEMES, KEY, CACHE_KEY, MODES, readChoice, effectiveMode, themeById, themeFor, derive, cacheFor, setVars,
  loadUserThemes, userThemeList, lowContrast } from './theme-data.js';

const osDark = () => { try { return matchMedia('(prefers-color-scheme: dark)').matches; } catch (e) { return true; } };
let choice = readChoice(null);
const themeOf = (m) => themeFor(choice, m);
// t-f889: the last /api/themes result, for the "Your own" section ({ themes, rejected, dir, error }); null until loaded
let listed = null;

// draw theme t in mode m on the shell and every open project board (t-a55a); `theme` keeps its old meaning, so an
// older board still follows
function show(m, t) {
  document.documentElement.dataset.theme = m;
  setVars(document.documentElement, t.css ? null : derive(t).shell);
  document.querySelectorAll('.view iframe').forEach(f => {
    try { f.contentWindow.postMessage({ type: 'canon-theme', theme: m, themeId: t.id }, location.origin); } catch (e) {}
  });
}
// the saved choice; the button names the theme in use
let previewing = false, restoring = false;   // previewing: the id of the card being previewed, or false
function apply() {
  const m = effectiveMode(choice, osDark()), t = themeOf(m), btn = document.getElementById('theme-btn');
  if (!t) return; // a user theme before the list has loaded: keep what theme-boot.js painted
  previewing = false;
  show(m, t);
  if (btn) { btn.title = t.name; btn.setAttribute('aria-label', 'Theme: ' + t.name); }
}
// t-4fa5 (user): hovering or focusing a card shows its theme without saving anything; leaving puts the saved one back
function preview(id) {
  const t = themeById(id);
  // the card already showing: no new message (a board looks a user theme up on each one, t-f889)
  if (!t || previewing === id) return;
  previewing = id;
  show(t.mode, t);
}
function unpreview() { if (previewing) apply(); }
// the cache theme-boot.js paints from goes with every save, so it always matches the saved choice
function save() {
  try {
    localStorage.setItem(KEY, JSON.stringify(choice));
    localStorage.setItem(CACHE_KEY, JSON.stringify(cacheFor(choice)));
  } catch (e) {}
}

// the strip's colours are set by paint() with style.setProperty, never written into the markup (t-f889)
function card(t, forMode) {
  const low = t.user ? lowContrast(t) : null;
  const tag = low ? `<span class="thm-low" title="${esc(`${low.what}: ${low.ratio.toFixed(2)}:1 (needs ${low.min}:1)`)}">Low contrast</span>` : '';
  return `<button type="button" class="thm-card" data-id="${esc(t.id)}" data-for="${forMode}" aria-pressed="${choice[forMode] === t.id}"><span class="thm-strip"><i></i><i></i><i></i><i></i><i></i></span>${esc(t.name)}${tag}</button>`;
}
function group(m) { return `<div class="thm-cards">${[...THEMES, ...userThemeList()].filter(t => t.mode === m).map(t => card(t, m)).join('')}</div>`; }
function paint(pop) {
  pop.querySelectorAll('.thm-card').forEach(b => {
    const t = themeById(b.dataset.id);
    if (t) b.querySelectorAll('.thm-strip i').forEach((i, n) => i.style.setProperty('background', t.c[['bg', 'surface', 'accent', 'ok', 'bad'][n]]));
  });
}
// t-f889: where user themes come from, the files that were refused and why, and the button that opens the folder
function own() {
  if (!listed) return '';
  const bad = listed.rejected.map(r => `<li><b>${esc(r.file)}</b>: ${esc(r.reason)}</li>`).join('');
  const err = listed.error ? `<div class="thm-note">${esc(listed.error)}</div>` : '';
  return `<h4 class="thm-own">Your own</h4><div class="thm-note">Add a theme file to <code>${esc(listed.dir)}</code>; it appears above, under its mode.</div>${err}`
    + (bad ? `<ul class="thm-rejected" aria-label="Theme files not used">${bad}</ul>` : '')
    + `<button type="button" class="thm-open" data-open="1">Open themes folder</button>`;
}
// Everything below is a fixed string from this file or passes through esc() (t-d2e1), so innerHTML is safe here; user
// themes reach it only after validateTheme() (theme-data.js), and their colours only through paint().
function render() {
  const pop = document.getElementById('theme-pop');
  const seg = MODES.map(m => `<button type="button" data-mode="${m}" aria-pressed="${choice.mode === m}">${m[0].toUpperCase() + m.slice(1)}</button>`).join('');
  const themes = choice.mode === 'system'
    ? `<div class="thm-sub">When light</div>${group('light')}<div class="thm-sub">When dark</div>${group('dark')}`
    : group(choice.mode);
  pop.innerHTML = `<h4>Mode</h4><div class="thm-seg" role="group" aria-label="Mode">${seg}</div><h4>Theme</h4>${themes}${own()}`;
  paint(pop);
}
// re-read the folder: a file added, fixed or removed shows the next time the popover opens. Re-render only when the
// list changed, so a quick keyboard user does not lose focus to a rebuild for nothing.
function refresh() {
  return loadUserThemes().then(st => {
    const before = JSON.stringify(listed);
    listed = st;
    try { localStorage.setItem(CACHE_KEY, JSON.stringify(cacheFor(choice))); } catch (e) {}
    if (JSON.stringify(listed) === before) return;
    if (!previewing) apply();
    const pop = document.getElementById('theme-pop');
    if (pop && !pop.hidden) render();
  });
}
async function openFolder() {
  try {
    const r = await fetch('/api/themes/open', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
    const res = await r.json();
    if (!res.ok) { toast(res.error || "Couldn't open the themes folder"); return; }
    if (res.created) refresh();
  } catch (e) { toast("Couldn't reach the board"); }
}
function setOpen(open) {
  const pop = document.getElementById('theme-pop'), btn = document.getElementById('theme-btn');
  if (open) { render(); refresh(); } else unpreview();
  pop.hidden = !open;
  btn.setAttribute('aria-expanded', String(open));
}

export function initTheme() {
  try { choice = readChoice(localStorage.getItem(KEY)); } catch (e) { choice = readChoice(null); }
  // the first-paint cache is rewritten from this version's colours once the user themes have loaded (refresh), so an
  // update never paints from an old one and a user theme's entry is not dropped before its file has been read
  document.addEventListener('DOMContentLoaded', () => {
    const btn = document.getElementById('theme-btn'), pop = document.getElementById('theme-pop');
    apply();
    refresh();
    btn.addEventListener('click', () => setOpen(pop.hidden));
    pop.addEventListener('click', e => {
      if (e.target.closest('[data-open]')) { openFolder(); return; }
      const m = e.target.closest('[data-mode]');
      const c = e.target.closest('[data-id]');
      if (m) choice.mode = m.dataset.mode;
      else if (c) choice[c.dataset.for] = c.dataset.id;
      else return;
      // render() rebuilds the popover, which would drop keyboard focus to <body> (break-it): put it back on the same control
      const again = m ? `[data-mode="${CSS.escape(m.dataset.mode)}"]` : `[data-id="${CSS.escape(c.dataset.id)}"][data-for="${CSS.escape(c.dataset.for)}"]`;
      save(); apply(); render();
      // putting focus back is not a preview: the click applied the saved choice, and the re-render means the browser
      // no longer counts the pointer as inside the popover, so leaving would not undo a preview here (break-it)
      const el = pop.querySelector(again); if (el) { restoring = true; el.focus(); restoring = false; }
    });
    // preview: a card under the pointer or with keyboard focus; anywhere else in the popover, or leaving it, reverts.
    // Only a pointer that really moved counts: choosing System grows the popover upward, which slides a card under a
    // still pointer, and Chromium reports that as hovering it (the shell then previewed a light theme by itself).
    const over = e => { if (restoring) return; const c = e.target.closest('.thm-card'); if (c) preview(c.dataset.id); else unpreview(); };
    let at = '';
    pop.addEventListener('pointermove', e => { const xy = e.clientX + ',' + e.clientY; if (xy !== at) { at = xy; over(e); } });
    pop.addEventListener('focusin', over);
    // leaving with the pointer shows the theme in use again. Not the focused card: after a click under System that
    // card can be the other mode's pick, which is saved but not in use (break-it)
    pop.addEventListener('pointerleave', unpreview);
    // keyboard focus leaving the popover and its button closes it (Tab to Help left it open on top, break-it); a press
    // with no new focus target (WebKit does not focus a clicked button) is left to the pointerdown and blur handlers
    const leave = e => { if (!pop.hidden && e.relatedTarget && !pop.contains(e.relatedTarget) && !btn.contains(e.relatedTarget)) setOpen(false); };
    pop.addEventListener('focusout', leave); btn.addEventListener('focusout', leave);
    // a press outside closes it; pointerdown runs before a click inside re-renders the popover (which would detach
    // the clicked element and make it look outside)
    document.addEventListener('pointerdown', e => {
      if (!pop.hidden && !pop.contains(e.target) && !btn.contains(e.target)) setOpen(false);
    });
    // a press inside a board (an iframe) never reaches this document; the shell losing focus to it closes the popover
    // too, as the Agents menu does (t-3c9a)
    window.addEventListener('blur', () => { if (!pop.hidden) setOpen(false); });
    document.addEventListener('keydown', e => {
      if (e.key === 'Escape' && !pop.hidden) { setOpen(false); btn.focus(); }
    });
    // another Cockpit window changed the choice: follow it, so a stale copy here can never be written back (break-it)
    window.addEventListener('storage', e => {
      if (e.key !== KEY) return;
      choice = readChoice(e.newValue); apply(); if (!pop.hidden) render();
    });
    try { matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if (choice.mode === 'system') { apply(); if (!pop.hidden) render(); } }); } catch (e) {}
  });
}
