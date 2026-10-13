// t-2758, t-3735: set the saved theme before the first paint. The pages' code is ES modules, which run only after the
// document is parsed, so a light-theme user saw a dark first frame. This is the one classic, blocking script each page
// loads (in <head>, after its stylesheets); it only sets data-theme, defines nothing, and never throws: anything it
// cannot read means Dark (the board: the OS). data-page says which page. The shell keeps { mode, light, dark } (or an
// older 'dark'/'light') under 'canon-theme' and marks dark as data-theme="dark". The board marks dark by having no
// attribute; inside a Cockpit tab it follows the shell's saved choice (same origin, so the same localStorage), which is
// current on every reload, unlike the ?theme its src was opened with (break-it: a reloaded or late-loading board kept an
// old theme); then ?theme, then its own 'sprint-check-theme' ('light' or 'dark' only), then the OS.
(function () {
  var html = document.documentElement, dark = true, page = 'board';
  function osDark() { try { return matchMedia('(prefers-color-scheme: dark)').matches; } catch (e) { return true; } }
  // the shell's saved choice -> true (dark) / false (light) / null (nothing readable)
  function shellDark() {
    var raw = localStorage.getItem('canon-theme'), mode = raw;
    if (raw && raw !== 'dark' && raw !== 'light') { try { var c = JSON.parse(raw); mode = c && typeof c === 'object' ? c.mode : null; } catch (e) { mode = null; } }
    return mode === 'light' ? false : mode === 'dark' ? true : mode === 'system' ? osDark() : null;
  }
  try {
    page = (document.currentScript && document.currentScript.getAttribute('data-page')) || 'board';
    if (page === 'shell') {
      var d = shellDark(); dark = d === null ? true : d;
    } else {
      var embedded = window.parent !== window, fromShell = embedded ? shellDark() : null;
      var q = new URLSearchParams(location.search).get('theme'), s = localStorage.getItem('sprint-check-theme');
      dark = fromShell !== null ? fromShell : q ? q !== 'light' : s === 'light' ? false : s === 'dark' ? true : osDark();
    }
  } catch (e) { dark = true; }
  if (page === 'shell') html.setAttribute('data-theme', dark ? 'dark' : 'light');
  else if (dark) html.removeAttribute('data-theme');
  else html.setAttribute('data-theme', 'light');
})();
