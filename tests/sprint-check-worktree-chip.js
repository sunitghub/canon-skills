#!/usr/bin/env node
// sprint-check-worktree-chip — unit coverage for the board card's worktree chip label (t-44b0).
// Loads the REAL worktreeChipLabel out of tools/sprint-check-app/app.html into a vm sandbox. The Windows
// separator/drive-letter cases run on any OS because the function only folds strings (rendered chip: Playwright).
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const APP = path.join(__dirname, '..', 'tools', 'sprint-check-app', 'app.html');
const html = fs.readFileSync(APP, 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);

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

const { statusBadgeInfo } = ctx;
let fails = 0;
function ok(name, cond, detail) {
  if (cond) { console.log('  ok   ' + name); }
  else { fails++; console.log('  FAIL ' + name + (detail != null ? '  => ' + JSON.stringify(detail) : '')); }
}

const { worktreeChipLabel } = ctx;
ok('worktreeChipLabel loaded from app.html', typeof worktreeChipLabel === 'function');

const MAIN = { path: 'C:/Users/agentops/Documents/ToDo', branch: 'master', is_main: true };
const WT = { path: 'c:/Users/agentops/Documents/ToDo-worktrees/sprint-restyle-ui', branch: 'sprint/restyle-ui', is_main: false };
const entries = [MAIN, WT];
const cases = [
  ['backslash cwd vs git slash path', entries, 'C:\\Users\\agentops\\Documents\\ToDo-worktrees\\sprint-restyle-ui', 'sprint/restyle-ui'],
  ['drive-letter case differs', entries, 'C:/Users/agentops/Documents/ToDo-worktrees/sprint-restyle-ui', 'sprint/restyle-ui'],
  ['trailing separators on cwd', entries, 'C:\\Users\\agentops\\Documents\\ToDo-worktrees\\sprint-restyle-ui\\', 'sprint/restyle-ui'],
  ['trailing slash on entry path', [{ path: '/tmp/wt/chip-x/', branch: 'chip-x', is_main: false }], '/tmp/wt/chip-x', 'chip-x'],
  ['main checkout, backslash cwd', entries, 'c:\\users\\agentops\\documents\\todo\\', 'main'],
  ['no entry matches → folder name, not main', entries, 'C:\\x\\ToDo-worktrees\\gone\\', 'gone'],
  ['no entry matches, POSIX cwd', [], '/tmp/wt/other/', 'other'],
  ['matched worktree without a branch → folder name', [{ path: 'C:/w/detached', branch: '', is_main: false }], 'C:\\w\\detached', 'detached'],
  ['entries not an array → folder name', null, 'C:\\w\\x', 'x'],
  ['entry without a path never matches an empty-ish cwd', [{ branch: 'b', is_main: false }, null], '', ''],
  ['null cwd does not throw', entries, null, ''],
];
for (const [name, ents, cwd, want] of cases) {
  let got; try { got = worktreeChipLabel(ents, cwd); } catch (e) { got = 'THREW ' + e.message; }
  ok(name, got === want, { got, want });
}

if (fails) { console.log(`\nsprint-check-worktree-chip: ${fails} FAILED`); process.exit(1); }
console.log('sprint-check-worktree-chip: ok');
