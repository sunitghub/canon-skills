#!/usr/bin/env node
// sprint-check-status-badge — unit coverage for the cockpit ticket-status badge
// mapping (t-bc04). Loads the REAL statusBadgeInfo out of
// tools/sprint-check-app/app.html into a vm sandbox and asserts each ticket
// status maps to the right label + board-column color class. Robust across the
// open/in_progress/closed/cancelled statuses without driving the board UI (the
// rendered integration is covered by the Playwright cockpit test).
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

ok('statusBadgeInfo loaded from app.html', typeof statusBadgeInfo === 'function');

const cases = [
  ['open', 'open', 'st-open'],
  ['in_progress', 'in progress', 'st-progress'],
  ['closed', 'closed', 'st-done'],
  ['cancelled', 'discarded', 'st-discarded'],
  ['archived', 'archived', 'st-discarded'],
];
for (const [status, label, cls] of cases) {
  const r = statusBadgeInfo(status);
  ok(`${status} → "${label}" / ${cls}`, r && r.label === label && r.cls === cls, r);
}
// Unknown/empty falls back to the open styling with a safe label.
{
  const r = statusBadgeInfo(undefined);
  ok('undefined status → empty label, st-open (no crash)', r && r.label === '' && r.cls === 'st-open', r);
}

if (fails) { console.log(`\nsprint-check-status-badge: ${fails} FAILED`); process.exit(1); }
console.log('sprint-check-status-badge: ok');
