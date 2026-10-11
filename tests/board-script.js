// board-script (t-c58e, t-1543) — the board's ES modules, for Node unit tests that load the REAL code out of
// tools/sprint-check-app/: every <script type="module" src="/static/<name>.js"> that app.html names, plus each module
// it imports (in import order), so a test does not care which module holds a function. Throws when the page names no
// board module, so a test can never pass on an empty load.
const fs = require('fs');
const path = require('path');

const APP_HTML = path.join(__dirname, '..', 'tools', 'sprint-check-app', 'app.html');

// boardScripts(appHtml) -> [{ name, file, source }]: each entry module, then the modules it imports, depth first.
function boardScripts(appHtml = APP_HTML) {
  const dir = path.join(path.dirname(appHtml), 'static');
  const html = fs.readFileSync(appHtml, 'utf8');
  const out = [], seen = new Set();
  const visit = (name) => {
    if (seen.has(name)) return;
    seen.add(name);
    const file = path.join(dir, name);
    const source = fs.readFileSync(file, 'utf8');
    out.push({ name, file, source });
    for (const m of source.matchAll(/^import [^;]*? from '\.\/([a-z0-9][a-z0-9-]*\.js)';$/gm)) visit(m[1]);
  };
  for (const m of html.matchAll(/<script type="module" src="\/static\/([a-z0-9][a-z0-9-]*\.js)"><\/script>/g)) visit(m[1]);
  if (!out.length) throw new Error('board-script: no board <script type="module"> found in ' + appHtml);
  return out;
}

// loadBoard(appHtml) -> one object holding every export of the board's modules (entry modules excluded: importing
// one runs the board's init code). Lenient DOM stubs go on globalThis first, since a module's top-level initializers
// read location and friends. Needs a Node that can require() an ES module (22.12+).
function loadBoard(appHtml = APP_HTML) {
  const noop = new Proxy({}, { get: () => () => noop, set: () => true });
  const stubs = {
    document: { getElementById: () => noop, querySelector: () => noop, querySelectorAll: () => [], addEventListener: () => {}, body: noop, documentElement: noop, createElement: () => noop },
    navigator: { platform: '' }, location: { href: '', search: '', origin: '' },
    localStorage: { getItem: () => null, setItem: () => {}, removeItem: () => {} },
    fetch: () => Promise.resolve({ ok: false, json: () => Promise.resolve({}) }),
  };
  for (const [k, v] of Object.entries(stubs)) Object.defineProperty(globalThis, k, { value: v, configurable: true, writable: true });
  Object.defineProperty(globalThis, 'window', { value: globalThis, configurable: true, writable: true });
  const entries = new Set([...fs.readFileSync(appHtml, 'utf8').matchAll(/<script type="module" src="\/static\/([a-z0-9-]+\.js)">/g)].map(m => m[1]));
  const board = {};
  for (const s of boardScripts(appHtml)) if (!entries.has(s.name)) Object.assign(board, require(s.file));
  return board;
}

module.exports = { APP_HTML, boardScripts, loadBoard };
