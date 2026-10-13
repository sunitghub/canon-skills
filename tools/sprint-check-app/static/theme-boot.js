// t-2758, t-3735: set the saved theme before the first paint. The pages' code is ES modules, which run only after the
// document is parsed, so a light-theme user saw a dark first frame. This is the one classic, blocking script each page
// loads (in <head>, after its stylesheets); it only sets data-theme, defines nothing, and never throws: anything it
// cannot read means Dark. data-page says which page: the shell keeps { mode, light, dark } (or an older 'dark'/'light')
// under 'canon-theme' and marks dark as data-theme="dark"; the board takes ?theme, then 'sprint-check-theme', then the
// OS, and marks dark by having no attribute.
(function () {
  var html = document.documentElement, dark = true, page = 'board';
  function osDark() { try { return matchMedia('(prefers-color-scheme: dark)').matches; } catch (e) { return true; } }
  try {
    page = (document.currentScript && document.currentScript.getAttribute('data-page')) || 'board';
    if (page === 'shell') {
      var raw = localStorage.getItem('canon-theme'), mode = raw;
      if (raw && raw !== 'dark' && raw !== 'light') { var c = JSON.parse(raw); mode = c && typeof c === 'object' ? c.mode : null; }
      dark = mode === 'light' ? false : mode === 'system' ? osDark() : true;
    } else {
      var q = new URLSearchParams(location.search).get('theme'), s = localStorage.getItem('sprint-check-theme');
      dark = q ? q !== 'light' : s ? s === 'dark' : osDark();
    }
  } catch (e) { dark = true; }
  if (page === 'shell') html.setAttribute('data-theme', dark ? 'dark' : 'light');
  else if (dark) html.removeAttribute('data-theme');
  else html.setAttribute('data-theme', 'light');
})();
