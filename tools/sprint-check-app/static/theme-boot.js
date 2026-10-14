// t-2758, t-3735: set the saved theme before the first paint. The pages' code is ES modules, which run only after the
// document is parsed, so a light-theme user saw a dark first frame. This is the one classic, blocking script each page
// loads (in <head>, after its stylesheets); it only sets data-theme and the theme's variables, defines nothing, and
// never throws: anything it cannot read means Dark (the board: the OS). data-page says which page. The shell keeps
// { mode, light, dark } (or an older 'dark'/'light') under 'canon-theme' and marks dark as data-theme="dark". The board
// marks dark by having no attribute; inside a Cockpit tab it follows the shell's saved choice (same origin, so the same
// localStorage), which is current on every reload, unlike the ?theme its src was opened with (break-it: a reloaded or
// late-loading board kept an old theme); then ?theme, then its own 'sprint-check-theme' ('light' or 'dark' only), then
// the OS. t-4fa5: a third-party theme's variables come from 'canon-theme-vars', which cockpit-theme.js writes from
// theme-data.js; they are applied only for the theme the saved choice picks, only on the shell and an embedded board,
// and only names and colour values that pass the checks below (anything else in it is skipped).
(function () {
  var html = document.documentElement, dark = true, page = 'board', vars = null;
  function osDark() { try { return matchMedia('(prefers-color-scheme: dark)').matches; } catch (e) { return true; } }
  // the shell's saved choice -> { dark: true/false/null (nothing readable), id: the theme id for that mode or null }
  function shellChoice() {
    var raw = localStorage.getItem('canon-theme'), mode = raw, c = null, d;
    if (raw && raw !== 'dark' && raw !== 'light') { try { c = JSON.parse(raw); mode = c && typeof c === 'object' ? c.mode : null; } catch (e) { mode = null; } }
    d = mode === 'light' ? false : mode === 'dark' ? true : mode === 'system' ? osDark() : null;
    return { dark: d, id: d === null || !c || typeof c !== 'object' ? null : c[d ? 'dark' : 'light'] };
  }
  // the cached variables for theme `id` (in mode `mode`) on page `p`, checked: version 1; a third-party id (Canon has no
  // cache: its CSS owns it) whose entry is of that mode; at most 120 names, each a theme variable (THEME_NAME in
  // theme-data.js, kept equal by tests/sprint-check-theme.js) with a hex or rgb()/rgba() value that is not transparent
  // (break-it: a cached transparent --text or a layout variable could blank the page until the module ran)
  var NAME = /^--(th-[a-z0-9-]+|bg|panel|panel-border|surface|surface-[a-z]+|border|border-[a-z]+|modal-border|text|text-[a-z]+|accent|accent-dim|glow-tint|card-stat|card-shadow|scrim|amber|badge-fg|col-[a-z-]+|st-[a-z]+|scenario-[a-z]+)$/;
  function cached(id, mode, p) {
    if (typeof id !== 'string' || !/^[a-z0-9-]{1,40}$/.test(id) || id.indexOf('canon-') === 0) return null;
    var raw = localStorage.getItem('canon-theme-vars');
    if (!raw || raw.length > 65536) return null;
    var c = JSON.parse(raw), t, m, out = [], k, n = 0;
    if (!c || c.v !== 1 || !c.themes || typeof c.themes !== 'object') return null;
    t = Object.prototype.hasOwnProperty.call(c.themes, id) ? c.themes[id] : null;
    if (!t || typeof t !== 'object' || t.mode !== mode) return null;
    m = Object.prototype.hasOwnProperty.call(t, p) ? t[p] : null;
    if (!m || typeof m !== 'object' || Array.isArray(m)) return null;
    for (k in m) {
      if (!Object.prototype.hasOwnProperty.call(m, k) || ++n > 120) break;
      if (NAME.test(k) && typeof m[k] === 'string' && !/^rgba?\([^,]+,[^,]+,[^,]+,\s*0*\.?0*\s*\)$/.test(m[k]) &&
          /^(#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|rgba?\(\s*[0-9.]+\s*,\s*[0-9.]+\s*,\s*[0-9.]+\s*(,\s*[0-9.]+\s*)?\))$/.test(m[k])) out.push([k, m[k]]);
    }
    return out.length ? out : null;
  }
  try {
    page = (document.currentScript && document.currentScript.getAttribute('data-page')) || 'board';
    if (page === 'shell') {
      var s = shellChoice(); dark = s.dark === null ? true : s.dark;
      try { vars = cached(s.id, dark ? 'dark' : 'light', 'shell'); } catch (e) { vars = null; }
    } else {
      var embedded = window.parent !== window, fromShell = embedded ? shellChoice() : { dark: null, id: null };
      var q = new URLSearchParams(location.search).get('theme'), st = localStorage.getItem('sprint-check-theme');
      dark = fromShell.dark !== null ? fromShell.dark : q ? q !== 'light' : st === 'light' ? false : st === 'dark' ? true : osDark();
      if (embedded && fromShell.dark !== null) { try { vars = cached(fromShell.id, dark ? 'dark' : 'light', 'board'); } catch (e) { vars = null; } }
    }
  } catch (e) { dark = true; vars = null; }
  if (page === 'shell') html.setAttribute('data-theme', dark ? 'dark' : 'light');
  else if (dark) html.removeAttribute('data-theme');
  else html.setAttribute('data-theme', 'light');
  if (vars) { for (var i = 0; i < vars.length; i++) { try { html.style.setProperty(vars[i][0], vars[i][1]); } catch (e) {} } }
})();
