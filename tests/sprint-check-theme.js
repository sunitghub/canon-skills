// sprint-check-theme (t-2758, t-3735): the theme is set before the first paint, and the shell's saved choice reads safely.
// 1. static/theme-boot.js, run as the browser runs it (a classic script) against stubs: precedence for both pages, and
//    anything unreadable (missing, corrupt, a throwing localStorage or matchMedia) means Dark, never an error.
// 2. cockpit-theme.js readChoice: an old 'dark'/'light' migrates; unknown modes, wrong types and foreign theme ids fall
//    back to the default; a valid choice survives.
// 3. Canon's entries in theme-data.js match tokens.css (their swatches and contrast use them; the CSS owns Canon).
// 4. (t-4fa5) contrast: the WCAG helper, every built-in at AA; derive() sets every variable the CSS needs; no colour in
//    the CSS ignores the theme; theme-boot.js applies a valid first-paint cache and skips anything else in it.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const STATIC = path.join(__dirname, '..', 'tools', 'sprint-check-app', 'static');
const BOOT = fs.readFileSync(path.join(STATIC, 'theme-boot.js'), 'utf8');

// boot({ page, stored, search, osDark, storageThrows, mediaThrows }) -> data-theme after the script ran (null = none)
function bootFull({ page, stored = {}, search = '', osDark = true, storageThrows = false, mediaThrows = false, preset = null, embedded = false }) {
  const attrs = {}, vars = {};
  if (preset !== null) attrs['data-theme'] = preset;
  const html = {
    setAttribute: (k, v) => { attrs[k] = String(v); },
    removeAttribute: (k) => { delete attrs[k]; },
    style: { setProperty: (k, v) => { vars[k] = v; } },
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
  return { theme: 'data-theme' in attrs ? attrs['data-theme'] : null, vars };
}
const boot = (o) => bootFull(o).theme;

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
  const { readChoice, THEMES, contrast, derive, ink, cacheFor, CACHE_V } = await import(path.join(STATIC, 'theme-data.js'));
  const D = { mode: 'dark', light: 'canon-light', dark: 'canon-dark' };
  assert.deepStrictEqual(readChoice(null), D, 'nothing saved is the default');
  assert.deepStrictEqual(readChoice('light'), { ...D, mode: 'light' }, 'old "light" migrates');
  assert.deepStrictEqual(readChoice('dark'), D, 'old "dark" migrates');
  assert.deepStrictEqual(readChoice(J({ mode: 'system', light: 'canon-light', dark: 'canon-dark' })), { ...D, mode: 'system' }, 'a valid choice survives');
  assert.deepStrictEqual(readChoice(J({ mode: 'light', light: 'canon-dark', dark: 'nope' })), { ...D, mode: 'light' }, 'a theme of the wrong mode or an unknown id falls back');
  assert.deepStrictEqual(readChoice(J({ mode: 'dark', light: 'catppuccin-latte', dark: 'nord' })), { mode: 'dark', light: 'catppuccin-latte', dark: 'nord' }, 'a third-party choice survives');
  assert.deepStrictEqual(readChoice(J({ mode: 'dark', light: 'nord', dark: 'catppuccin-latte' })), D, 'third-party themes of the wrong mode fall back');
  for (const bad of ['{', '[]', 'null', '7', J({ mode: 'sepia' }), J({ mode: ['light'] })]) assert.deepStrictEqual(readChoice(bad), D, `unreadable ${bad} is the default`);

  const css = fs.readFileSync(path.join(STATIC, 'tokens.css'), 'utf8');
  const block = (mode) => { const m = css.match(new RegExp(`${mode === 'dark' ? ':root' : 'html\\[data-theme="light"\\]'}\\s*\\{(\\s*(?:/\\*[^*]*\\*/\\s*)?(?:/\\*[^*]*\\*/\\s*)?--bg:[^}]*)\\}`)); assert.ok(m, `tokens.css has the ${mode} block`); return m[1]; };
  const value = (decls, name) => { const m = decls.match(new RegExp(`${name}:([^;]+)`)); assert.ok(m, `${name} defined`); return m[1].trim(); };
  const norm = (h) => (h.length === 4 ? '#' + [...h.slice(1)].map(x => x + x).join('') : h).toLowerCase();
  for (const t of THEMES.filter(t => t.css)) {
    const decls = block(t.mode);
    for (const [slot, v] of [['bg', '--bg'], ['surface', '--surface'], ['accent', '--accent'], ['ok', '--col-done'], ['bad', '--col-discarded']]) {
      assert.strictEqual(norm(t.c[slot]), norm(value(decls, v)), `${t.name} ${slot} equals tokens.css ${v}`);
    }
  }
  assert.deepStrictEqual(THEMES.map(t => t.id).sort(), ['canon-dark', 'canon-light', 'catppuccin-latte', 'catppuccin-mocha', 'dracula', 'gruvbox-dark', 'nord', 'tokyo-night'], 'the eight built-ins');

  // ── 4a. contrast ──
  const near = (a, b, m) => assert.ok(Math.abs(a - b) < 0.01, `${m}: ${a} vs ${b}`);
  near(contrast('#000000', '#ffffff'), 21, 'black on white');
  near(contrast('#ffffff', '#ffffff'), 1, 'white on white');
  near(contrast('#777777', '#ffffff'), 4.48, '#777 on white (WebAIM)');
  near(contrast('#0000ff', '#ffffff'), 8.59, 'blue on white (WebAIM)');
  for (const t of THEMES) {
    const c = t.c;
    for (const [a, b, floor, what] of [[c.text, c.bg, 4.5, 'text/bg'], [c.muted, c.surface, 4.5, 'muted/surface'], [c.accent, c.bg, 3, 'accent/bg'], [ink(c, c.accent), c.accent, 3, 'on-accent']]) {
      assert.ok(contrast(a, b) >= floor, `${t.name} ${what} ${contrast(a, b).toFixed(2)} < ${floor}`);
    }
  }

  // ── 4b. derive() sets every variable the CSS needs ──
  const statics = fs.readdirSync(STATIC);
  const read = (re) => statics.filter(f => re.test(f)).map(f => [f, fs.readFileSync(path.join(STATIC, f), 'utf8')]);
  // t-e523: buttons.css is linked by both pages, so it counts as each page's CSS
  const shellCss = read(/^(cockpit-.*|buttons)\.css$/), boardCss = read(/^(board-.*|buttons)\.css$/);
  const blockNames = (txt, re) => { const out = new Set(); for (const m of txt.matchAll(re)) for (const v of m[1].matchAll(/(--[a-z0-9-]+)\s*:/g)) out.add(v[1]); return out; };
  // the shell reads these palette names; the board reads every other palette name in tokens.css (the scales are not colours)
  const shellNeed = new Set(['--bg', '--panel', '--border', '--border-hover', '--border-muted', '--text', '--text-body', '--text-muted', '--text-dim', '--accent', '--accent-dim',
    '--col-done', '--col-progress', '--col-discarded', '--amber', '--card-stat', '--scrim', '--st-need', '--st-work', '--st-done', '--st-idle']);
  // Canon's fallbacks for --th-* names the CSS reads as var(--th-x, var(--x)); a theme sets the --th-* one, never these
  const FALLBACK_ONLY = /^--(ok|ok-ink|ok-soft|bad-ink|bad-soft|warn-ink|warn-soft|warn-line|on-ok|on-ok-dim|on-accent|title|type-[a-z]+)$/;
  const SHELL_ONLY = new Set(['--panel', '--amber', '--card-stat', '--scrim']);
  const boardNeed = blockNames(css, /(?::root|html\[data-theme="light"\])\s*\{([^}]*)\}/g);
  for (const n of [...boardNeed]) if (SHELL_ONLY.has(n) || /^--(radius|fs|sp|shadow|mono|sidebar-w|header-h)/.test(n) || FALLBACK_ONLY.test(n)) boardNeed.delete(n);
  const thUsed = (files) => { const out = new Set(); for (const [, t] of files) for (const m of t.matchAll(/var\((--th-[a-z0-9-]+)/g)) out.add(m[1]); return out; };
  for (const n of thUsed(shellCss)) shellNeed.add(n);
  for (const n of thUsed(boardCss)) boardNeed.add(n);
  assert.ok(shellNeed.size > 20 && boardNeed.size > 40, `parsed the variables (${shellNeed.size}, ${boardNeed.size})`);
  // and the other way: every --th-* derive() sets is read by the CSS (no dead variable in the cache; review, eval)
  const thRead = new Set([...thUsed(shellCss), ...thUsed(boardCss)]);
  for (const n of Object.keys({ ...derive(THEMES.find(t => !t.css)).shell, ...derive(THEMES.find(t => !t.css)).board })) {
    if (n.startsWith('--th-')) assert.ok(thRead.has(n), `derive() sets ${n}, which no CSS reads`);
  }
  for (const t of THEMES.filter(t => !t.css)) {
    const d = derive(t);
    for (const n of shellNeed) assert.ok(n in d.shell, `${t.name}: derive() sets the shell's ${n}`);
    for (const n of boardNeed) assert.ok(n in d.board, `${t.name}: derive() sets the board's ${n}`);
    for (const p of ['shell', 'board']) assert.ok(Object.keys(d[p]).length <= 120, `${t.name}: ${p} map fits theme-boot's 120-name cap`);
  }

  // ── 4c. no colour in the CSS ignores the theme ──
  // A literal colour is allowed only as the fallback of var(--x, …) where derive() sets --x, inside Canon's own theme
  // blocks, in a shadow or a black overlay, or on this list (identity and the terminal frame, t-2ba3).
  const ALLOWED = [['board-base.css', '#1A1A1F'], ['board-cockpit.css', 'var(--panel2, #0d131c)']];
  const setByDerive = new Set([...Object.keys(derive(THEMES.find(t => !t.css)).shell), ...Object.keys(derive(THEMES.find(t => !t.css)).board)]);
  const COLOR = /#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)/g;
  function scan(file, text) {
    const bad = [];
    let t = text.replace(/\/\*[\s\S]*?\*\//g, m => m.replace(/[^\n]/g, ' '));
    // Canon's theme blocks are the CSS-owned palette
    t = t.replace(/(:root|html\[data-theme="(?:dark|light)"\])\s*\{[^}]*\}/g, m => (/--[a-z-]+\s*:/.test(m) && !/[.#][a-z]/i.test(m.split('{')[0].replace(/html\[data-theme="(dark|light)"\]|:root/, '')) ? m.replace(/[^\n]/g, ' ') : m));
    const lines = t.split('\n');
    for (const m of t.matchAll(COLOR)) {
      const before = t.slice(0, m.index), lineNo = before.split('\n').length, line = lines[lineNo - 1];
      const fb = before.match(/var\((--[a-z0-9-]+)\s*,\s*$/);
      if (fb && setByDerive.has(fb[1])) continue;
      // the declaration this colour belongs to, even when it spans lines (a multi-line box-shadow)
      const decl = before.slice(Math.max(before.lastIndexOf(';'), before.lastIndexOf('{'), before.lastIndexOf('}')) + 1);
      if (/^\s*(box-shadow|text-shadow)\s*:/.test(decl) || /^rgba\(\s*0\s*,\s*0\s*,\s*0\s*,/.test(m[0])) continue;
      if (ALLOWED.some(([f, lit]) => f === file && line.includes(lit))) continue;
      bad.push(`${file}:${lineNo} ${m[0]}`);
    }
    return bad;
  }
  const found = [...shellCss, ...boardCss].flatMap(([f, t]) => scan(f, t));
  assert.deepStrictEqual(found, [], 'every CSS colour follows the theme:\n' + found.join('\n'));
  // the scan must reject a literal in a plain rule, a light-only rule and a per-element variable definition
  for (const planted of ['.x { color: #123456; }', 'html[data-theme="light"] .x { color: #123456; }', '.col-open { --card-glow: rgba(1,2,3,.4); }', '.x { color: var(--nope, #123456); }']) {
    assert.strictEqual(scan('planted.css', planted).length, 1, `the scan rejects: ${planted}`);
  }

  // t-be64: a colour literal belongs in tokens.css. Every other file has a budget (today's count); it may only shrink,
  // and a file not listed has none. Lower the number in the change that moves a file onto tokens.
  const LITERAL_BUDGET = { 'board-base.css': 13, 'board-cockpit.css': 23, 'board-dialog.css': 2, 'board-dialogs.css': 27, 'board-github.css': 7,
    'board-logbook.css': 15, 'board-modal.css': 28, 'board-tags.css': 3, 'buttons.css': 2, 'cockpit-admin.css': 6,
    'cockpit-projects.css': 3, 'cockpit-shell.css': 8, 'cockpit-skill-eval.css': 2 };
  const literalCount = (text) => (text.replace(/\/\*[\s\S]*?\*\//g, '').match(COLOR) || []).length;
  const over = statics.filter(f => f.endsWith('.css') && f !== 'tokens.css')
    .map(f => [f, literalCount(fs.readFileSync(path.join(STATIC, f), 'utf8'))]).filter(([f, n]) => n > (LITERAL_BUDGET[f] || 0)).map(([f, n]) => `${f}: ${n} > ${LITERAL_BUDGET[f] || 0}`);
  assert.deepStrictEqual(over, [], 'a colour literal outside tokens.css (add a token, or lower nothing):\n' + over.join('\n'));
  assert.strictEqual(literalCount('.x { color: #123456; border-color: rgba(1,2,3,.4); } /* #fff */'), 2, 'the literal counter sees both forms and skips comments');

  // ── 4d. theme-boot.js applies a valid cache and skips the rest ──
  const nord = THEMES.find(t => t.id === 'nord'), latte = THEMES.find(t => t.id === 'catppuccin-latte');
  const choice = { mode: 'dark', light: 'catppuccin-latte', dark: 'nord' };
  const good = J(cacheFor(choice));
  const CV = (shell, vars) => ({ 'canon-theme': shell, 'canon-theme-vars': vars });
  let r = bootFull({ page: 'shell', stored: CV(J(choice), good) });
  assert.strictEqual(r.theme, 'dark'); assert.strictEqual(r.vars['--bg'], nord.c.bg, 'shell: the cached theme paints first');
  assert.ok(!('--card-shadow' in r.vars), 'shell: a non-colour value is skipped');
  r = bootFull({ page: 'board', embedded: true, stored: CV(J(choice), good) });
  assert.strictEqual(r.vars['--surface'], nord.c.surface, 'embedded board: its board map paints first');
  r = bootFull({ page: 'board', embedded: false, stored: CV(J(choice), good) });
  assert.deepStrictEqual(r.vars, {}, 'standalone board: never a cached third-party theme');
  r = bootFull({ page: 'shell', stored: CV(J({ ...choice, mode: 'system' }), good), osDark: false });
  assert.strictEqual(r.theme, 'light'); assert.strictEqual(r.vars['--bg'], latte.c.bg, 'System on a light OS paints the light pick');
  r = bootFull({ page: 'shell', stored: CV(J({ mode: 'dark', light: 'canon-light', dark: 'canon-dark' }), good) });
  assert.deepStrictEqual(r.vars, {}, 'a Canon choice applies no cached variables');
  const hostile = (mut) => { const c = JSON.parse(good); mut(c); return J(c); };
  for (const [what, cache] of [
    ['old version', hostile(c => { c.v = CACHE_V + 1; })],
    ['no entry for the id', hostile(c => { delete c.themes.nord; })],
    ['corrupt JSON', '{"v":1,'],
    ['array', '[]'], ['null', 'null'], ['huge', 'x'.repeat(70000)],
    ['map is an array', hostile(c => { c.themes.nord.shell = ['--bg']; })],
  ]) assert.deepStrictEqual(bootFull({ page: 'shell', stored: CV(J(choice), cache) }).vars, {}, `ignored: ${what}`);
  for (const [what, k, v] of [['url()', '--bg', 'url(https://x/y)'], ['expression', '--bg', 'expression(alert(1))'], ['breakout', '--bg', 'red;} body{display:none'], ['bad name', '--Bg;x', '#000'], ['number', '--bg', 7], ['named colour', '--bg', 'red']]) {
    const c = hostile(x => { x.themes.nord.shell = { [k]: v, '--text': '#eceff4' }; });
    const out = bootFull({ page: 'shell', stored: CV(J(choice), c) }).vars;
    assert.ok(!(k in out) && out['--text'] === '#eceff4', `skipped ${what}, kept the valid entry`);
  }
  // break-it (t-4fa5): no layout variable, no transparent colour, no Canon id, no entry of the other mode
  for (const [what, k, v] of [['layout --side-w', '--side-w', '#000000'], ['layout --header-h', '--header-h', '#000000'], ['transparent', '--text', 'rgba(0,0,0,0)'], ['transparent 0.0', '--text', 'rgba(1,2,3, 0.0)'], ['transparent rgb() with alpha', '--text', 'rgb(1,2,3,0)'], ['transparent rgb() 0.0', '--text', 'rgb(1,2,3, 0.0)']]) {
    const c = hostile(x => { x.themes.nord.shell = { [k]: v, '--bg': '#2e3440' }; });
    const out = bootFull({ page: 'shell', stored: CV(J(choice), c) }).vars;
    assert.ok(!(k in out && out[k] === v) && out['--bg'] === '#2e3440', `skipped ${what}, kept the valid entry`);
  }
  const keepRed = hostile(x => { x.themes.nord.shell = { '--bg': 'rgb(255,0,0)', '--text': 'rgba(1,2,3,.5)' }; });
  assert.deepStrictEqual(bootFull({ page: 'shell', stored: CV(J(choice), keepRed) }).vars, { '--bg': 'rgb(255,0,0)', '--text': 'rgba(1,2,3,.5)' }, 'an opaque rgb() and a half-transparent rgba() are kept');
  const asCanon = J({ v: CACHE_V, themes: { 'canon-dark': { mode: 'dark', shell: { '--bg': '#ffffff' } } } });
  assert.deepStrictEqual(bootFull({ page: 'shell', stored: CV(J({ mode: 'dark', light: 'canon-light', dark: 'canon-dark' }), asCanon) }).vars, {}, 'a Canon id never takes a cache');
  const wrongMode = hostile(x => { x.themes.nord.mode = 'light'; });
  assert.deepStrictEqual(bootFull({ page: 'shell', stored: CV(J(choice), wrongMode) }).vars, {}, 'an entry of the other mode is ignored');
  // THEME_NAME: one pattern in theme-data.js and theme-boot.js; every derive() name matches; no layout name does
  const { THEME_NAME, setVars } = await import(path.join(STATIC, 'theme-data.js'));
  const bootName = BOOT.match(/var NAME = (\/.*\/);/);
  assert.ok(bootName && bootName[1] === String(THEME_NAME), 'theme-boot.js carries the same THEME_NAME as theme-data.js');
  for (const t of THEMES.filter(t => !t.css)) for (const p of ['shell', 'board']) for (const n of Object.keys(derive(t)[p])) assert.ok(THEME_NAME.test(n), `THEME_NAME covers ${n}`);
  for (const n of ['--side-w', '--sidebar-w', '--header-h', '--radius', '--radius-sm', '--strip-h', '--strip-pad', '--edge', '--mono', '--r', '--ck-preview-w', '--drag-x', '--type-dot', '--card-glow', '--status-color']) assert.ok(!THEME_NAME.test(n), `THEME_NAME rejects ${n}`);
  // setVars leaves the page's own inline variables alone (the sidebar width)
  const props = new Map([['--side-w', '380px'], ['--bg', '#000000']]);
  const el = { style: { [Symbol.iterator]: () => [...props.keys()][Symbol.iterator](), removeProperty: k => props.delete(k), setProperty: (k, v) => props.set(k, v) } };
  setVars(el, null);
  assert.deepStrictEqual([...props], [['--side-w', '380px']], 'setVars removes theme variables only');
  const many = hostile(x => { const m = {}; for (let i = 0; i < 500; i++) m['--v' + i] = '#000000'; x.themes.nord.shell = m; });
  assert.ok(Object.keys(bootFull({ page: 'shell', stored: CV(J(choice), many) }).vars).length <= 120, 'at most 120 names');
  assert.strictEqual(bootFull({ page: 'shell', stored: CV(J(choice), good), storageThrows: true }).theme, 'dark', 'throwing storage: still dark, no throw');
  const proto = '{"v":1,"themes":{"nord":{"shell":{"__proto__":{"--bg":"#000000"}}}}}';
  assert.deepStrictEqual(bootFull({ page: 'shell', stored: CV(J(choice), proto) }).vars, {}, '__proto__ keys are not followed');

  // t-f889: user themes. readChoice keeps a well-formed user id it cannot resolve yet; themeFor shows Canon of that mode
  // once the list has loaded without it (the pick stays saved), and null before (the boot paint stays)
  const TD = await import(path.join(STATIC, 'theme-data.js'));
  const uc = TD.readChoice(J({ mode: 'dark', light: 'user-paper', dark: 'user-ink' }));
  assert.deepStrictEqual(uc, { mode: 'dark', light: 'user-paper', dark: 'user-ink' }, 'readChoice keeps user ids');
  for (const bad of ['user-', 'user-UP', 'user-a_b', 'user-' + 'a'.repeat(31), 'User-x', 'user-x<b>', 'nord-x']) {
    assert.strictEqual(TD.readChoice(J({ mode: 'dark', light: 'canon-light', dark: bad })).dark, 'canon-dark', `readChoice drops ${bad}`);
  }
  assert.strictEqual(TD.themeFor(uc, 'dark'), null, 'a user pick before the list loads: null (keep the boot paint)');
  const example = JSON.parse(fs.readFileSync(path.join(STATIC, '..', 'theme-seed', 'example.json'), 'utf8'));
  const inkT = { mode: 'dark', ...example };
  const light = { name: 'Paper', mode: 'light', colors: { ...example.colors, bg: '#ffffff', surface: '#fafafa', text: '#eeeeee', muted: '#dddddd' } };
  global.fetch = async () => ({ json: async () => ({ dir: '/x', themes: [
    { id: 'user-ink', file: 'ink.json', ...inkT },
    { id: 'user-paper', file: 'paper.json', ...light },
    { id: 'user-forged', file: 'other.json', ...inkT },          // id does not match its file: refused by the page
    { id: 'user-css', file: 'css.json', ...inkT, colors: { ...inkT.colors, bg: 'red;x:url(y)' } },
  ], rejected: [{ file: 'a.json', reason: 'not valid JSON' }, { file: 5, reason: 'x' }] }) });
  const st = await TD.loadUserThemes();
  assert.deepStrictEqual(st.themes.map(t => t.id), ['user-ink', 'user-paper'], 'the page re-checks every entry');
  assert.deepStrictEqual(st.rejected.map(r => r.file), ['other.json', 'css.json', 'a.json'], 'refused entries are listed, malformed ones dropped');
  assert.strictEqual(TD.themeFor(uc, 'dark').id, 'user-ink', 'a loaded user theme resolves');
  assert.strictEqual(TD.themeFor({ ...uc, dark: 'user-paper' }, 'dark').id, 'canon-dark', 'a user theme of the other mode shows Canon');
  assert.strictEqual(TD.themeFor({ ...uc, dark: 'user-gone' }, 'dark').id, 'canon-dark', 'a missing user theme shows Canon');
  assert.ok(TD.cacheFor(uc).themes['user-ink'], 'the cache carries a user theme');
  assert.ok(!TD.cacheFor({ mode: 'dark', light: 'canon-light', dark: 'user-paper' }).themes['user-paper'], 'not one of the wrong mode');
  // the cached user theme paints on the first frame (boot takes a user- id like any third-party one)
  assert.ok(Object.keys(bootFull({ page: 'shell', stored: CV(J(uc), J(TD.cacheFor(uc))) }).vars).length > 20, 'boot paints a cached user theme');
  // Low contrast: the example meets the floor; every built-in does too; a pale text fails with its ratio
  assert.strictEqual(TD.lowContrast(TD.themeById('user-ink')), null, 'example.json meets the contrast floor');
  for (const t of THEMES) assert.strictEqual(TD.lowContrast(t), null, `${t.id} meets the floor`);
  const low = TD.lowContrast(TD.themeById('user-paper'));
  assert.ok(low && low.what === 'text on background' && low.ratio < 4.5, 'pale text on white is Low contrast');
  assert.ok(Object.values(TD.themeById('user-ink').c).every(v => /^#[0-9a-f]{6}$/.test(v)), 'colours normalised to #rrggbb');
  delete global.fetch;

  console.log('sprint-check-theme: ok (theme-boot precedence, fallback and cache for shell and board; readChoice migration; Canon equals tokens.css; AA per built-in; derive completeness; no unthemed CSS colour; user themes: page re-check, fallback, cache, Low contrast)');
})().catch(e => { console.error('FAIL:', e.message); process.exit(1); });
