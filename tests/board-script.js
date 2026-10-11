// board-script (t-c58e) — the board's classic scripts, in page order, for Node unit tests that load the REAL code out
// of tools/sprint-check-app/app.html: inline <script> blocks and <script src="/static/<name>.js"> files alike, so a
// test does not care which of the two holds a function. Module scripts (the t-9b2d bridge) are skipped: vm runs them
// as classic code. Throws when the page names no board script, so a test can never pass on an empty load.
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const APP_HTML = path.join(__dirname, '..', 'tools', 'sprint-check-app', 'app.html');

// boardScripts(appHtml) -> [{ name, source }] in document order.
function boardScripts(appHtml = APP_HTML) {
  const html = fs.readFileSync(appHtml, 'utf8');
  const out = [];
  for (const m of html.matchAll(/<script>([\s\S]*?)<\/script>|<script src="\/static\/([a-z0-9][a-z0-9-]*\.js)"><\/script>/g)) {
    if (m[2]) out.push({ name: m[2], source: fs.readFileSync(path.join(path.dirname(appHtml), 'static', m[2]), 'utf8') });
    else out.push({ name: 'app.html#inline' + out.length, source: m[1] });
  }
  if (!out.length) throw new Error('board-script: no board <script> found in ' + appHtml);
  return out;
}

// loadBoard(appHtml) -> a vm context holding every top-level function of the board's scripts. Lenient DOM stubs:
// function declarations are hoisted per script, so a script's functions are bound even if one of its later
// top-level init statements touches the DOM and throws.
function loadBoard(appHtml = APP_HTML) {
  const noop = new Proxy({}, { get: () => () => noop, set: () => true });
  const sandbox = {
    document: { getElementById: () => noop, querySelector: () => noop, querySelectorAll: () => [], addEventListener: () => {}, body: noop, documentElement: noop, createElement: () => noop },
    navigator: { platform: '' }, location: { href: '', search: '' },
    localStorage: { getItem: () => null, setItem: () => {}, removeItem: () => {} },
    fetch: () => Promise.resolve({ ok: false, json: () => Promise.resolve({}) }),
    setTimeout: () => 0, clearTimeout: () => {}, setInterval: () => 0, clearInterval: () => {}, console,
  };
  sandbox.window = sandbox; sandbox.globalThis = sandbox;
  const ctx = vm.createContext(sandbox);
  for (const s of boardScripts(appHtml)) { try { vm.runInContext(s.source, ctx, { timeout: 5000, filename: s.name }); } catch (_) { /* hoisted fns still bound */ } }
  return ctx;
}

module.exports = { APP_HTML, boardScripts, loadBoard };
