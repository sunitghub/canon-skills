// t-4fa5: the Cockpit's themes (slice B). Declares only: imported by the shell (cockpit-theme.js) and the board
// (board-ui.js). A theme is 12 colours; derive() turns them into the shell's and the board's variables. Canon Dark and
// Canon Light are owned by the CSS (cockpit-shell.css, board-base.css): their entries here only feed the cards and the
// contrast test, and nothing is derived for them. Every third-party value comes from that project's own palette
// (THEMES.md: sources, licences, and the slots that took another palette colour to pass contrast).
export const THEMES = [
  { id: 'canon-light', name: 'Canon Light', mode: 'light', css: true,
    c: { bg: '#e8e8f0', surface: '#ffffff', border: '#dcdce8', text: '#1a1a2e', body: '#424269', muted: '#52527a', accent: '#6c5cf7', ok: '#16a34a', warn: '#b45309', bad: '#dc2626', info: '#2563eb', term: '#ffffff' } },
  { id: 'canon-dark', name: 'Canon Dark', mode: 'dark', css: true,
    c: { bg: '#1b2330', surface: '#232d3c', border: '#313d50', text: '#e6ebf2', body: '#a7b0c0', muted: '#97a1b4', accent: '#7c6af7', ok: '#4ade80', warn: '#fbbf24', bad: '#f87171', info: '#60a5fa', term: '#0d131c' } },
  // Catppuccin (palette.json): Latte base/mantle/surface0/text/subtext1/subtext1/mauve/green/yellow/red/blue/base
  // (muted: subtext1, not subtext0, which reads 4.06 on mantle)
  { id: 'catppuccin-latte', name: 'Catppuccin Latte', mode: 'light',
    c: { bg: '#eff1f5', surface: '#e6e9ef', border: '#ccd0da', text: '#4c4f69', body: '#5c5f77', muted: '#5c5f77', accent: '#8839ef', ok: '#40a02b', warn: '#df8e1d', bad: '#d20f39', info: '#1e66f5', term: '#eff1f5' } },
  // Mocha base/surface0/surface1/text/subtext1/subtext0/mauve/green/yellow/red/blue/mantle
  { id: 'catppuccin-mocha', name: 'Catppuccin Mocha', mode: 'dark',
    c: { bg: '#1e1e2e', surface: '#313244', border: '#45475a', text: '#cdd6f4', body: '#bac2de', muted: '#a6adc8', accent: '#cba6f7', ok: '#a6e3a1', warn: '#f9e2af', bad: '#f38ba8', info: '#89b4fa', term: '#181825' } },
  // Tokyo Night (enkia README): night bg, storm bg, terminal black, terminal white, editor fg, markdown text, blue,
  // green(strings), yellow, red, cyan, night bg
  { id: 'tokyo-night', name: 'Tokyo Night', mode: 'dark',
    c: { bg: '#1a1b26', surface: '#24283b', border: '#414868', text: '#c0caf5', body: '#a9b1d6', muted: '#9aa5ce', accent: '#7aa2f7', ok: '#9ece6a', warn: '#e0af68', bad: '#f7768e', info: '#7dcfff', term: '#1a1b26' } },
  // Nord: nord0/nord1/nord3/nord6/nord5/nord4/nord8/nord14/nord13/nord11/nord9/nord0
  { id: 'nord', name: 'Nord', mode: 'dark',
    c: { bg: '#2e3440', surface: '#3b4252', border: '#4c566a', text: '#eceff4', body: '#e5e9f0', muted: '#d8dee9', accent: '#88c0d0', ok: '#a3be8c', warn: '#ebcb8b', bad: '#bf616a', info: '#81a1c1', term: '#2e3440' } },
  // Dracula (spec): Background/Background Light/Selection/Foreground/Foreground/Cyan/Purple/Green/Yellow/Red/Cyan/
  // Background Dark
  { id: 'dracula', name: 'Dracula', mode: 'dark',
    c: { bg: '#282a36', surface: '#343746', border: '#44475a', text: '#f8f8f2', body: '#f8f8f2', muted: '#8be9fd', accent: '#bd93f9', ok: '#50fa7b', warn: '#f1fa8c', bad: '#ff5555', info: '#8be9fd', term: '#21222c' } },
  // Gruvbox (gruvbox.vim): dark0/dark1/dark2/light1/light2/light3/bright_yellow/bright_green/bright_orange/bright_red/
  // bright_blue/dark0_hard (muted: light3, not light4, which reads 4.17 on dark1)
  { id: 'gruvbox-dark', name: 'Gruvbox Dark', mode: 'dark',
    c: { bg: '#282828', surface: '#3c3836', border: '#504945', text: '#ebdbb2', body: '#d5c4a1', muted: '#bdae93', accent: '#fabd2f', ok: '#b8bb26', warn: '#fe8019', bad: '#fb4934', info: '#83a598', term: '#1d2021' } },
];

const rgb = (h) => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
const hex = (a) => '#' + a.map(v => Math.round(v).toString(16).padStart(2, '0')).join('');
// WCAG 2.x relative luminance and contrast ratio
const lum = (h) => { const c = rgb(h).map(v => v / 255).map(v => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4))); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
export function contrast(a, b) { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); }
const mix = (a, b, t) => { const x = rgb(a), y = rgb(b); return hex(x.map((v, i) => v + (y[i] - v) * t)); };
const alpha = (h, a) => `rgba(${rgb(h).join(',')},${a})`;
// text on a fill: whichever of the theme's own text and bg reads better on it
export const ink = (c, fill) => (contrast(c.text, fill) >= contrast(c.bg, fill) ? c.text : c.bg);

// derive(theme) -> { shell, board }: the shell's and the board's variables. The `--th-*` names are set only here:
// the CSS reads them as var(--th-x, <Canon's colour>), so Canon, which never sets them, keeps its exact colours.
export function derive(t) {
  const c = t.c, dark = t.mode === 'dark';
  const shared = {
    '--bg': c.bg, '--border': c.border, '--border-hover': mix(c.border, c.muted, 0.3), '--border-muted': mix(c.surface, c.border, 0.5),
    '--text': c.text, '--text-body': c.body, '--text-muted': c.muted, '--text-dim': mix(c.muted, c.bg, 0.5),
    '--accent': c.accent, '--col-done': c.ok, '--col-progress': c.info, '--col-discarded': c.bad,
    '--st-need': c.bad, '--st-work': c.warn, '--st-done': c.info, '--st-idle': c.ok,
  };
  const th = {
    '--th-text': c.text, '--th-title': c.text,
    '--th-on-accent': ink(c, c.accent), '--th-on-bad': ink(c, c.bad), '--th-on-ok': ink(c, c.ok), '--th-on-warn': ink(c, c.warn),
    '--th-on-ok-dim': alpha(ink(c, c.ok), 0.65), '--th-on-warn-dim': alpha(ink(c, c.warn), 0.7),
    '--th-knob': dark ? c.text : c.surface, '--th-hover-soft': alpha(c.text, 0.05),
    '--th-accent': c.accent, '--th-accent-soft': alpha(c.accent, 0.12), '--th-accent-line': alpha(c.accent, 0.4),
    '--th-muted-fill': c.muted, '--th-muted-ink': ink(c, c.muted), '--th-info-soft': alpha(c.info, 0.1),
  };
  for (const k of ['ok', 'warn', 'bad']) {
    th[`--th-${k}`] = c[k];
    th[`--th-${k}-soft`] = alpha(c[k], dark ? 0.1 : 0.14);
    th[`--th-${k}-line`] = alpha(c[k], dark ? 0.35 : 0.6);
    th[`--th-${k}-ink`] = dark ? c[k] : mix(c[k], c.text, 0.45);
  }
  for (const [col, v] of [['open', c.muted], ['progress', c.info], ['done', c.ok], ['discarded', c.bad]]) {
    th[`--th-col-${col}-line`] = alpha(v, 0.45);
    th[`--th-col-${col}-glow`] = alpha(v, 0.45);
    th[`--th-col-${col}-status`] = alpha(v, 0.72);
  }
  const shell = { ...shared, ...th,
    '--panel': c.surface, '--accent-dim': alpha(c.accent, dark ? 0.14 : 0.1), '--amber': c.warn,
    '--card-stat': mix(c.accent, c.text, 0.4), '--scrim': dark ? 'rgba(0,0,0,.6)' : alpha(c.text, 0.35),
  };
  const board = { ...shared, ...th,
    '--st-ink': dark ? c.bg : c.surface,
    '--surface': c.surface, '--surface-raised': mix(c.surface, c.border, 0.5), '--surface-hover': c.border,
    '--modal-border': mix(c.border, c.muted, 0.2), '--panel-border': mix(c.surface, c.border, 0.7),
    '--accent-dim': alpha(c.accent, dark ? 0.12 : 0.1), '--glow-tint': alpha(c.accent, dark ? 0.09 : 0.05),
    '--card-shadow': dark ? 'inset 0 1px 0 rgba(255,255,255,.04), 0 2px 10px rgba(0,0,0,.35)' : 'inset 0 1px 0 rgba(255,255,255,.6), 0 1px 5px rgba(0,0,0,.08)',
    '--scenario-bg': mix(c.surface, c.accent, 0.06), '--scenario-border': mix(c.border, c.accent, 0.25), '--scenario-keyword': c.accent,
    '--col-open': c.muted, '--col-done-contrast': ink(c, c.ok), '--badge-fg': dark ? c.bg : c.surface,
  };
  return { shell, board };
}

// The saved choice: { mode, light, dark } under 'canon-theme' (an older 'dark'/'light' still reads). readChoice turns
// whatever is stored into a valid one; a theme of the wrong mode or an unknown id falls back to Canon's.
export const KEY = 'canon-theme', CACHE_KEY = 'canon-theme-vars', CACHE_V = 1;
export const MODES = ['system', 'light', 'dark'];
const DEFAULT = { mode: 'dark', light: 'canon-light', dark: 'canon-dark' };
export function readChoice(raw) {
  if (raw === 'dark' || raw === 'light') return { ...DEFAULT, mode: raw };
  let c = null;
  try { c = JSON.parse(raw); } catch (e) {}
  if (!c || typeof c !== 'object' || !MODES.includes(c.mode)) return { ...DEFAULT };
  const pick = (m) => (THEMES.some(t => t.id === c[m] && t.mode === m) ? c[m] : DEFAULT[m]);
  return { mode: c.mode, light: pick('light'), dark: pick('dark') };
}
export const effectiveMode = (choice, osDark) => (choice.mode === 'system' ? (osDark ? 'dark' : 'light') : choice.mode);
export const themeById = (id) => THEMES.find(t => t.id === id);
// What theme-boot.js re-applies before the first paint: the derived variables of the choice's third-party themes
// (both of them under System, so an OS change between visits still paints right). Canon needs none: its CSS owns it.
export function cacheFor(choice) {
  const themes = {};
  for (const m of ['light', 'dark']) { const t = themeById(choice[m]); if (t && !t.css) themes[t.id] = { mode: t.mode, ...derive(t) }; }
  return { v: CACHE_V, themes };
}
// The names a theme may set: derive()'s vocabulary and nothing else, so the page's own inline variables (the sidebar's
// --side-w) are never touched (break-it). theme-boot.js carries the same pattern; tests/sprint-check-theme.js keeps
// the two equal and checks every derive() name matches and no layout name does.
export const THEME_NAME = /^--(th-[a-z0-9-]+|bg|panel|panel-border|surface|surface-[a-z]+|border|border-[a-z]+|modal-border|text|text-[a-z]+|accent|accent-dim|glow-tint|card-stat|card-shadow|scrim|amber|badge-fg|col-[a-z-]+|st-[a-z]+|scenario-[a-z]+)$/;
// Set a derived map on an element's style, after removing the theme variables set before (switching back to Canon).
export function setVars(el, vars) {
  for (const p of [...el.style]) if (THEME_NAME.test(p)) el.style.removeProperty(p);
  if (vars) for (const [k, v] of Object.entries(vars)) el.style.setProperty(k, v);
}
