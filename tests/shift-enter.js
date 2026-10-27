#!/usr/bin/env node
// shift-enter — unit coverage for Shift+Enter in the Cockpit's session terminal (t-6aaf). xterm.js sends the same \r for Shift+Enter
// as for Enter, so an agent cannot tell them apart; the daemon page turns an unmodified Shift+Enter into ESC+CR (a newline). Loads the
// REAL snippet between the canon:shift-enter markers out of the daemon's page and drives it with plain event objects (no browser),
// then checks the wiring in the page's source: one custom key handler, shared with the prefix keys, attached whether or not embedded.
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const page = fs.readFileSync(path.join(__dirname, '..', 'tools', 'canon-go', 'internal', 'daemon', 'web', 'cockpit.html'), 'utf8');
const a = page.indexOf('// canon:shift-enter:begin');
const b = page.indexOf('// canon:shift-enter:end');
if (a < 0 || b < 0) { console.log('FAIL: snippet markers not found in the daemon page'); process.exit(1); }
const ctx = {};
vm.createContext(ctx);
vm.runInContext(page.slice(a, b) + '\nthis.canonShiftEnter = canonShiftEnter;', ctx);
const f = ctx.canonShiftEnter;

let fails = 0;
function ok(name, cond, detail) {
  if (cond) console.log('  ok   ' + name);
  else { fails++; console.log('  FAIL ' + name + (detail !== undefined ? '  => ' + JSON.stringify(detail) : '')); }
}
const ev = (type, key, o = {}) => ({ type, key, shiftKey: !!o.shift, ctrlKey: !!o.ctrl, altKey: !!o.alt, metaKey: !!o.meta, isComposing: !!o.composing });

for (const agent of ['claude', 'pi', 'copilot']) {
  ok(agent + ': Shift+Enter keydown sends ESC+CR', f(ev('keydown', 'Enter', { shift: true }), '', agent) === '\x1b\r');
  ok(agent + ': its keypress and keyup are swallowed with nothing sent (xterm would send \\r for the keypress)',
    f(ev('keypress', 'Enter', { shift: true }), '', agent) === '' && f(ev('keyup', 'Enter', { shift: true }), '', agent) === '');
  ok(agent + ': plain Enter is left to xterm', ['keydown', 'keypress', 'keyup'].every(t => f(ev(t, 'Enter'), '', agent) === null));
}
for (const m of ['ctrl', 'alt', 'meta']) {
  ok('Shift+Enter with ' + m + ' held is left to xterm', f(ev('keydown', 'Enter', { shift: true, [m]: true }), '', 'claude') === null);
}
ok('Shift+Enter while composing text (IME) is left to xterm', f(ev('keydown', 'Enter', { shift: true, composing: true }), '', 'claude') === null);
ok('another key with Shift is left alone', f(ev('keydown', 'a', { shift: true }), '', 'claude') === null && f(ev('keydown', 'Tab', { shift: true }), '', 'claude') === null);
ok('the restricted Terminal (mode "term") keeps Enter as it is', f(ev('keydown', 'Enter', { shift: true }), 'term', 'claude') === null);
ok('an unknown or empty agent gets nothing special', f(ev('keydown', 'Enter', { shift: true }), '', 'codex') === null && f(ev('keydown', 'Enter', { shift: true }), '', undefined) === null && f(ev('keydown', 'Enter', { shift: true }), '', '') === null);

// The wiring, read from the page's source.
const attaches = page.match(/attachCustomKeyEventHandler\(/g) || [];
ok('the page attaches exactly one custom key handler (xterm keeps only the last)', attaches.length === 1, attaches.length);
const at = page.indexOf('attachCustomKeyEventHandler(');
const open = page.indexOf('{', at);
let depth = 0, end = open;
for (let i = open; i < page.length; i++) { if (page[i] === '{') depth++; else if (page[i] === '}') { depth--; if (depth === 0) { end = i; break; } } }
const handler = page.slice(at, end + 1);
ok('that handler runs the prefix keys first, then Shift+Enter', handler.indexOf('prefixKeys.handle(ev)') > 0 && handler.indexOf('canonShiftEnter(') > handler.indexOf('prefixKeys.handle(ev)'));
ok('it sends only when a session is running, through the same path as typed keys', /session \? canonShiftEnter\(/.test(handler) && handler.includes('sendInput(nl)') && page.includes('term.onData(sendInput);'));
const emb = page.indexOf('if (window.parent !== window) {');
let d2 = 0, e2 = emb;
for (let i = page.indexOf('{', emb); i < page.length; i++) { if (page[i] === '{') d2++; else if (page[i] === '}') { d2--; if (d2 === 0) { e2 = i; break; } } }
ok('the handler is attached outside the embedded-only branch', emb > 0 && !(at > emb && at < e2), { emb, at, e2 });

if (fails) { console.log(`\nshift-enter: ${fails} FAILED`); process.exit(1); }
console.log('shift-enter: ok');
