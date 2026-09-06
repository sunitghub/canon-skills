#!/usr/bin/env node
// sprint-check-handoff-state — unit coverage for the cockpit STATUS panel's
// HANDOFF state resolution (t-8ff0). Loads the REAL handoffDisplayState /
// findHandoffStateForTicket / sectionContent out of tools/sprint-check-app/app.html
// into a vm sandbox (not a copy) and asserts the id-matched In-Progress bullet is
// preferred, that Current Focus is the honest fallback (active sprint OR id named),
// that an unrelated ticket's focus is never shown, and that neither → the hint state.
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

const { handoffDisplayState, findHandoffStateForTicket, sectionContent } = ctx;
let fails = 0;
function ok(name, cond, detail) {
  if (cond) { console.log('  ok   ' + name); }
  else { fails++; console.log('  FAIL ' + name + (detail != null ? '  => ' + JSON.stringify(detail) : '')); }
}

ok('helpers loaded from app.html',
  typeof handoffDisplayState === 'function' && typeof findHandoffStateForTicket === 'function' && typeof sectionContent === 'function');

// The exact live case (t-8ff0): id in Current Focus, generic In-Progress bullets.
const LIVE = [
  '# Handoff', '<!-- canon:handoff:BEGIN -->',
  '## Current Focus', 'Sprint t-pdry: Create plain HTML/CSS/JS ToDo app', '',
  '## In Progress',
  '- Awaiting user approval on plan.md (Tier: normal, single static file)',
  '- Research.md complete; acceptance.md and plan.md filled in with criteria/approach/test plan', '',
  '## Discoveries', '- Stack chosen: plain HTML/CSS/JS', '',
  '<!-- canon:handoff:END -->',
].join('\n');

// (a) id-matched In-Progress bullet is preferred.
const withBullet = LIVE.replace(
  '- Awaiting user approval on plan.md (Tier: normal, single static file)',
  '- t-pdry — awaiting plan.md approval');
{
  const r = handoffDisplayState(withBullet, 't-pdry', false);
  ok('(a) id-matched In-Progress bullet wins', r.source === 'in-progress' && /t-pdry/.test(r.text), r);
}

// (b) no id-matched bullet, Current Focus names the id, not active → Current Focus fallback.
{
  const r = handoffDisplayState(LIVE, 't-pdry', false);
  ok('(b) Current Focus fallback when it names the id', r.source === 'current-focus' && /Create plain HTML\/CSS\/JS ToDo app/.test(r.text), r);
}

// (c) no id-matched bullet, id NOT in Current Focus, but ticket is the active sprint → Current Focus.
const focusNoId = LIVE.replace('Sprint t-pdry: Create plain HTML/CSS/JS ToDo app', 'Building the ToDo app');
{
  const r = handoffDisplayState(focusNoId, 't-pdry', true);
  ok('(c) active sprint falls back to Current Focus even without the id', r.source === 'current-focus' && /Building the ToDo app/.test(r.text), r);
}

// (d) no id-matched bullet, not active, id NOT in Current Focus → hint (never an unrelated focus).
{
  const r = handoffDisplayState(focusNoId, 't-pdry', false);
  ok('(d) unrelated/non-active gets the hint, not another ticket\'s focus', r.source === null && r.text === null, r);
}

// (e) empty raw → null.
{
  const r = handoffDisplayState('', 't-pdry', true);
  ok('(e) empty HANDOFF → null', r.source === null && r.text === null, r);
}

// (f) no ## Current Focus section at all, active, no bullet → hint (no crash).
const noFocus = ['## In Progress', '- generic work', '', '## Next Steps', '1. x'].join('\n');
{
  const r = handoffDisplayState(noFocus, 't-pdry', true);
  ok('(f) missing Current Focus section → hint, no crash', r.source === null, r);
}

// (g) render check: the fallback text formats to visible <p> HTML (this is what
// renderCockpitState feeds to formatStateAsParagraphs for the current-focus branch).
const { formatStateAsParagraphs } = ctx;
{
  const r = handoffDisplayState(LIVE, 't-pdry', false);
  const html = formatStateAsParagraphs(r.text, { id: 't-pdry' });
  ok('(g) Current Focus fallback renders visible <p> with the focus text',
    /<p>/.test(html) && /Create plain HTML\/CSS\/JS ToDo app/.test(html), html);
}

if (fails) { console.log(`\nsprint-check-handoff-state: ${fails} FAILED`); process.exit(1); }
console.log('sprint-check-handoff-state: ok');
