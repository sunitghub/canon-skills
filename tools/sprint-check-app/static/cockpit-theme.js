// t-2758: the shell's "◐ Theme" switcher (themes slice A). Mode decides when it is light or dark (System follows the OS);
// Theme lists only themes of that mode, and under System there is one pick for light and one for dark. The choice is
// saved as { mode, light, dark } under 'canon-theme' (an older 'dark'/'light' still reads). theme-boot.js applies it
// before the first paint; this module keeps it in step and tells every open board. Canon Dark/Light are today's CSS
// (cockpit-shell.css); the swatches below repeat its values and tests/sprint-check-theme.js keeps them equal.
import { esc } from './cockpit-core.js';

export const THEMES = [
  { id: 'canon-light', name: 'Canon Light', mode: 'light', swatch: ['#e8e8f0', '#fff', '#6c5cf7', '#16a34a', '#dc2626'] },
  { id: 'canon-dark', name: 'Canon Dark', mode: 'dark', swatch: ['#1b2330', '#232d3c', '#7c6af7', '#4ade80', '#f87171'] },
];
const KEY = 'canon-theme', MODES = ['system', 'light', 'dark'];
const DEFAULT = { mode: 'dark', light: 'canon-light', dark: 'canon-dark' };
const osDark = () => { try { return matchMedia('(prefers-color-scheme: dark)').matches; } catch (e) { return true; } };

// readChoice(raw) -> a valid { mode, light, dark } from whatever is stored; anything unreadable is the default.
export function readChoice(raw) {
  if (raw === 'dark' || raw === 'light') return { ...DEFAULT, mode: raw };
  let c = null;
  try { c = JSON.parse(raw); } catch (e) {}
  if (!c || typeof c !== 'object' || !MODES.includes(c.mode)) return { ...DEFAULT };
  const pick = (m) => (THEMES.some(t => t.id === c[m] && t.mode === m) ? c[m] : DEFAULT[m]);
  return { mode: c.mode, light: pick('light'), dark: pick('dark') };
}
export function effectiveMode(choice) { return choice.mode === 'system' ? (osDark() ? 'dark' : 'light') : choice.mode; }

let choice = { ...DEFAULT };
const themeOf = (m) => THEMES.find(t => t.id === choice[m]);

function apply() {
  const m = effectiveMode(choice), t = themeOf(m), btn = document.getElementById('theme-btn');
  document.documentElement.dataset.theme = m;
  if (btn) { btn.title = t.name; btn.setAttribute('aria-label', 'Theme: ' + t.name); }
  // every open project board follows (t-a55a); `theme` keeps its old meaning, so an older board still does
  document.querySelectorAll('.view iframe').forEach(f => {
    try { f.contentWindow.postMessage({ type: 'canon-theme', theme: m, themeId: t.id }, location.origin); } catch (e) {}
  });
}
function save() { try { localStorage.setItem(KEY, JSON.stringify(choice)); } catch (e) {} }

function card(t, forMode) {
  const sw = t.swatch.map(c => `<i style="background:${c}"></i>`).join('');
  return `<button type="button" class="thm-card" data-id="${esc(t.id)}" data-for="${forMode}" aria-pressed="${choice[forMode] === t.id}"><span class="thm-strip">${sw}</span>${esc(t.name)}</button>`;
}
function group(m) { return `<div class="thm-cards">${THEMES.filter(t => t.mode === m).map(t => card(t, m)).join('')}</div>`; }
// Everything below is a fixed string from this file or passes through esc() (t-d2e1), so innerHTML is safe here.
// Slice C's user themes need their own validation before they reach this (t-f889).
function render() {
  const pop = document.getElementById('theme-pop');
  const seg = MODES.map(m => `<button type="button" data-mode="${m}" aria-pressed="${choice.mode === m}">${m[0].toUpperCase() + m.slice(1)}</button>`).join('');
  const themes = choice.mode === 'system'
    ? `<div class="thm-sub">When light</div>${group('light')}<div class="thm-sub">When dark</div>${group('dark')}`
    : group(choice.mode);
  pop.innerHTML = `<h4>Mode</h4><div class="thm-seg" role="group" aria-label="Mode">${seg}</div><h4>Theme</h4>${themes}`;
}
function setOpen(open) {
  const pop = document.getElementById('theme-pop'), btn = document.getElementById('theme-btn');
  if (open) render();
  pop.hidden = !open;
  btn.setAttribute('aria-expanded', String(open));
}

export function initTheme() {
  try { choice = readChoice(localStorage.getItem(KEY)); } catch (e) { choice = { ...DEFAULT }; }
  document.addEventListener('DOMContentLoaded', () => {
    const btn = document.getElementById('theme-btn'), pop = document.getElementById('theme-pop');
    apply();
    btn.addEventListener('click', () => setOpen(pop.hidden));
    pop.addEventListener('click', e => {
      const m = e.target.closest('[data-mode]');
      const c = e.target.closest('[data-id]');
      if (m) choice.mode = m.dataset.mode;
      else if (c) choice[c.dataset.for] = c.dataset.id;
      else return;
      // render() rebuilds the popover, which would drop keyboard focus to <body> (break-it): put it back on the same control
      const again = m ? `[data-mode="${CSS.escape(m.dataset.mode)}"]` : `[data-id="${CSS.escape(c.dataset.id)}"][data-for="${CSS.escape(c.dataset.for)}"]`;
      save(); apply(); render();
      const el = pop.querySelector(again); if (el) el.focus();
    });
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
