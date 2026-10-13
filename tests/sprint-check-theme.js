// sprint-check-theme (t-2758, t-3735): the theme is set before the first paint, and the shell's saved choice reads safely.
// 1. static/theme-boot.js, run as the browser runs it (a classic script) against stubs: precedence for both pages, and
//    anything unreadable (missing, corrupt, a throwing localStorage or matchMedia) means Dark, never an error.
// 2. cockpit-theme.js readChoice: an old 'dark'/'light' migrates; unknown modes, wrong types and foreign theme ids fall
//    back to the default; a valid choice survives.
// 3. The swatches the cards show are Canon's real values from cockpit-shell.css (one owner: the CSS).
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const STATIC = path.join(__dirname, '..', 'tools', 'sprint-check-app', 'static');
const BOOT = fs.readFileSync(path.join(STATIC, 'theme-boot.js'), 'utf8');

// boot({ page, stored, search, osDark, storageThrows, mediaThrows }) -> data-theme after the script ran (null = none)
function boot({ page, stored = {}, search = '', osDark = true, storageThrows = false, mediaThrows = false, preset = null, embedded = false }) {
  const attrs = {};
  if (preset !== null) attrs['data-theme'] = preset;
  const html = {
    setAttribute: (k, v) => { attrs[k] = String(v); },
    removeAttribute: (k) => { delete attrs[k]; },
  };
  const ctx = {
    document: { documentElement: html, currentScript: page ? { getAttribute: (k) => (k === 'data-page' ? page : null) } : null },
    localStorage: { getItem: (k) => { if (storageThrows) throw new Error('blocked'); return k in stored ? stored[k] : null; } },
    matchMedia: () => { if (mediaThrows) throw new Error('no media'); return { matches: osDark }; },
    location: { search },
    URLSearchParams,
  };
  ctx.window = {}; ctx.window.parent = embedded ? {} : ctx.window;   // a board in a Cockpit tab has another window as its parent
  vm.runInNewContext(BOOT, ctx);
  return 'data-theme' in attrs ? attrs['data-theme'] : null;
}

// ── 1a. shell ───────────────────────────────────────────────────────────────
const S = (v) => ({ 'canon-theme': v });
const J = (o) => JSON.stringify(o);
assert.strictEqual(boot({ page: 'shell' }), 'dark', 'shell: nothing saved is dark');
assert.strictEqual(boot({ page: 'shell', stored: S('light') }), 'light', 'shell: an old saved "light" still reads');
assert.strictEqual(boot({ page: 'shell', stored: S('dark'), preset: 'light' }), 'dark', 'shell: an old saved "dark" reads');
assert.strictEqual(boot({ page: 'shell', stored: S(J({ mode: 'light' })) }), 'light', 'shell: { mode: light }');
assert.strictEqual(boot({ page: 'shell', stored: S(J({ mode: 'dark' })) }), 'dark', 'shell: { mode: dark }');
assert.strictEqual(boot({ page: 'shell', stored: S(J({ mode: 'system' })), osDark: false }), 'light', 'shell: system follows a light OS');
assert.strictEqual(boot({ page: 'shell', stored: S(J({ mode: 'system' })), osDark: true }), 'dark', 'shell: system follows a dark OS');
for (const bad of ['{', 'null', '[]', '"light"', '42', J({ mode: 'sepia' }), J({ mode: 7 }), J({})]) {
  assert.strictEqual(boot({ page: 'shell', stored: S(bad) }), 'dark', `shell: unreadable ${bad} is dark`);
}
assert.strictEqual(boot({ page: 'shell', storageThrows: true }), 'dark', 'shell: a throwing localStorage is dark');
assert.strictEqual(boot({ page: 'shell', stored: S(J({ mode: 'system' })), mediaThrows: true }), 'dark', 'shell: a throwing matchMedia is dark');

// ── 1b. board (dark = no attribute) ────────────────────────────────────────
const B = (v) => ({ 'sprint-check-theme': v });
assert.strictEqual(boot({ page: 'board', osDark: false }), 'light', 'board: nothing saved follows a light OS');
assert.strictEqual(boot({ page: 'board', osDark: true, preset: 'light' }), null, 'board: nothing saved follows a dark OS (no attribute)');
assert.strictEqual(boot({ page: 'board', stored: B('light'), osDark: true }), 'light', 'board: its own saved choice beats the OS');
assert.strictEqual(boot({ page: 'board', stored: B('dark'), osDark: false }), null, 'board: saved dark beats a light OS');
assert.strictEqual(boot({ page: 'board', stored: B('dark'), search: '?project=p&theme=light' }), 'light', 'board: the shell-passed ?theme beats the saved choice');
assert.strictEqual(boot({ page: 'board', stored: B('light'), search: '?theme=dark' }), null, 'board: ?theme=dark wins too');
assert.strictEqual(boot({ page: 'board', storageThrows: true, preset: 'light' }), null, 'board: a throwing localStorage is dark');
assert.strictEqual(boot({ page: null, stored: B('light') }), 'light', 'no data-page is the board');
// an unreadable saved board value is not "light": it falls back to the OS (break-it: any other value meant light)
for (const bad of ['garbage', 'Light', ' light', '{"mode":"light"}']) {
  assert.strictEqual(boot({ page: 'board', stored: B(bad), osDark: true, preset: 'light' }), null, `board: unreadable ${bad} follows a dark OS`);
  assert.strictEqual(boot({ page: 'board', stored: B(bad), osDark: false }), 'light', `board: unreadable ${bad} follows a light OS`);
}
// a board in a Cockpit tab follows the shell's saved choice, which is current on a reload, over the ?theme it was opened with
const SB = (shell, board) => ({ 'canon-theme': shell, 'sprint-check-theme': board });
assert.strictEqual(boot({ page: 'board', embedded: true, stored: SB(J({ mode: 'light' }), 'dark'), search: '?project=p&theme=dark' }), 'light', 'embedded board: the shell\'s light beats ?theme=dark');
assert.strictEqual(boot({ page: 'board', embedded: true, stored: SB(J({ mode: 'dark' }), 'light'), search: '?theme=light', preset: 'light' }), null, 'embedded board: the shell\'s dark beats ?theme=light');
assert.strictEqual(boot({ page: 'board', embedded: true, stored: SB(J({ mode: 'system' }), null), search: '?theme=dark', osDark: false }), 'light', 'embedded board: the shell\'s System follows the OS');
assert.strictEqual(boot({ page: 'board', embedded: true, stored: SB('{bad', null), search: '?theme=light' }), 'light', 'embedded board: an unreadable shell choice falls back to ?theme');
assert.strictEqual(boot({ page: 'board', embedded: false, stored: SB(J({ mode: 'light' }), 'dark'), preset: 'light' }), null, 'standalone board: ignores the shell\'s choice');

// ── 2 + 3. the shell module ────────────────────────────────────────────────
(async () => {
  // the shell's modules read browser globals when they load: install the same lenient stubs the board tests use
  require('./board-script').loadBoard();
  globalThis.addEventListener = () => {};   // cockpit-end.js registers its relay listener when it loads (t-3c9a)
  const { readChoice, THEMES } = await import(path.join(STATIC, 'cockpit-theme.js'));
  const D = { mode: 'dark', light: 'canon-light', dark: 'canon-dark' };
  assert.deepStrictEqual(readChoice(null), D, 'nothing saved is the default');
  assert.deepStrictEqual(readChoice('light'), { ...D, mode: 'light' }, 'old "light" migrates');
  assert.deepStrictEqual(readChoice('dark'), D, 'old "dark" migrates');
  assert.deepStrictEqual(readChoice(J({ mode: 'system', light: 'canon-light', dark: 'canon-dark' })), { ...D, mode: 'system' }, 'a valid choice survives');
  assert.deepStrictEqual(readChoice(J({ mode: 'light', light: 'canon-dark', dark: 'nope' })), { ...D, mode: 'light' }, 'a theme of the wrong mode or an unknown id falls back');
  for (const bad of ['{', '[]', 'null', '7', J({ mode: 'sepia' }), J({ mode: ['light'] })]) assert.deepStrictEqual(readChoice(bad), D, `unreadable ${bad} is the default`);

  const css = fs.readFileSync(path.join(STATIC, 'cockpit-shell.css'), 'utf8');
  const block = (mode) => { const m = css.match(new RegExp(`html\\[data-theme="${mode}"\\]\\{(--bg:[^}]*)\\}`)); assert.ok(m, `cockpit-shell.css has the ${mode} block`); return m[1]; };
  const value = (decls, name) => { const m = decls.match(new RegExp(`${name}:([^;]+)`)); assert.ok(m, `${name} defined`); return m[1].trim(); };
  for (const t of THEMES) {
    const decls = block(t.mode);
    const want = ['--bg', '--panel', '--accent', '--col-done', '--col-discarded'].map(n => value(decls, n));
    assert.deepStrictEqual(t.swatch, want, `${t.name} swatch equals cockpit-shell.css`);
  }
  assert.deepStrictEqual(THEMES.map(t => t.mode).sort(), ['dark', 'light'], 'slice A ships one Canon theme per mode');
  console.log('sprint-check-theme: ok (theme-boot precedence + fallback for shell and board; readChoice migration; swatches equal cockpit-shell.css)');
})().catch(e => { console.error('FAIL:', e.message); process.exit(1); });
