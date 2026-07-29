#!/usr/bin/env node
// sprint-check-editor — unit coverage for the doc-editor Tab-indent transform (t-d95f).
//
// Loads the REAL computeTabEdit out of tools/sprint-check-app/app.html into a vm sandbox
// (not a copy) and asserts Tab / Shift+Tab behavior on a textarea's (value, selection).
// This is the committed regression guard behind the "Tab indents in the editor" criterion.
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const APP = path.join(__dirname, '..', 'tools', 'sprint-check-app', 'app.html');
const html = fs.readFileSync(APP, 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);

// Lenient DOM stubs — function declarations are hoisted, so computeTabEdit is defined even
// if some later top-level init statement touches the DOM and throws.
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
for (const s of scripts) { try { vm.runInContext(s, ctx, { timeout: 5000 }); } catch (_) { /* hoisted fns still bound */ } }

const { computeTabEdit } = ctx;
let fails = 0;
function ok(name, cond, detail) {
  if (cond) { console.log('  ok   ' + name); }
  else { fails++; console.log('  FAIL ' + name + (detail != null ? '  => ' + JSON.stringify(detail) : '')); }
}
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

ok('computeTabEdit is loaded from app.html', typeof computeTabEdit === 'function');

// 1. Plain Tab, no selection: inserts two spaces at the cursor, cursor after them.
{
  const r = computeTabEdit('abc', 1, 1, false);
  ok('plain Tab inserts two spaces at cursor', eq(r, { value: 'a  bc', selStart: 3, selEnd: 3 }), r);
}

// 2. Multi-line selection: indents every spanned line by two spaces.
{
  const value = 'one\ntwo\nthree';
  // selection spans the middle of line 1 through the middle of line 3
  const r = computeTabEdit(value, 1, value.length - 1, false);
  ok('multi-line Tab indents each spanned line',
    r.value === '  one\n  two\n  three', r);
}

// 3. Shift+Tab: outdents (strips up to two leading spaces) per spanned line.
{
  const value = '    one\n  two\nthree';
  const r = computeTabEdit(value, 0, value.length, true);
  ok('Shift+Tab outdents up to two spaces per line',
    r.value === '  one\ntwo\nthree', r);
}

// 4. Shift+Tab on a line with no leading whitespace is a no-op for that line (no crash).
{
  const r = computeTabEdit('nolead', 0, 6, true);
  ok('Shift+Tab on unindented line is a no-op', r.value === 'nolead', r);
}

// 5. Shift+Tab strips a leading tab char too.
{
  const r = computeTabEdit('\tindented', 0, 9, true);
  ok('Shift+Tab strips a leading tab', r.value === 'indented', r);
}

// 6. Selection ending exactly at a line start does not indent the trailing empty line.
{
  const value = 'a\nb\n'; // select "a\nb\n" (ends right after the last \n)
  const r = computeTabEdit(value, 0, 4, false);
  ok('trailing empty line is not indented', r.value === '  a\n  b\n', r);
}

console.log(fails === 0 ? 'sprint-check-editor: ok' : `sprint-check-editor: ${fails} FAILED`);
process.exit(fails === 0 ? 0 : 1);
