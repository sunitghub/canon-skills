#!/usr/bin/env node
// sprint-check-gherkin — unit coverage for the Gherkin acceptance validator (t-6e32).
//
// Loads the REAL functions out of tools/sprint-check-app/app.html into a vm
// sandbox (not a copy) and asserts validateGherkinBlocks flags every malformed
// branch and passes well-formed / non-gherkin input. This is the committed
// regression guard behind acceptance.md's C5/T4 — each of the four error
// branches has its own case, so breaking any one branch fails the suite.
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const APP = path.join(__dirname, '..', 'tools', 'sprint-check-app', 'app.html');
const html = fs.readFileSync(APP, 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);

// Lenient DOM stubs — function declarations are hoisted, so validateGherkinBlocks
// is defined even if some later top-level init statement touches the DOM and throws.
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

const { validateGherkinBlocks } = ctx;
let fails = 0;
function ok(name, cond, detail) {
  if (cond) { console.log('  ok   ' + name); }
  else { fails++; console.log('  FAIL ' + name + (detail != null ? '  => ' + JSON.stringify(detail) : '')); }
}

ok('validateGherkinBlocks is loaded from app.html', typeof validateGherkinBlocks === 'function');

const valid = [
  '```gherkin',
  'Scenario: Valid code above minimum applies the discount',
  '  Given cart_total 120.00', '  And code "SAVE20"', '  When discount is applied',
  '  Then applied is true', '  And final_total is 96.00', '',
  'Scenario: Valid code below minimum is rejected',
  '  Given cart_total 40.00', '  When discount is applied', '  Then applied is false', '',
  'Scenario: Unknown code is rejected',
  '  Given cart_total 200.00', '  When discount is applied', '  Then applied is false',
  '```',
].join('\n');

// Passing inputs.
ok('valid 3-scenario block passes', validateGherkinBlocks(valid) === '', validateGherkinBlocks(valid));
ok('non-gherkin content passes', validateGherkinBlocks('## Criteria\n- [ ] a\n- [x] b\n') === '');
ok('feature description lines are not flagged',
  validateGherkinBlocks('```gherkin\nFeature: F\n  As a user\n  I want X\nScenario: s\n  Given a\n  Then b\n```') === '');
ok('background steps are not "before a scenario"',
  validateGherkinBlocks('```gherkin\nBackground:\n  Given setup\nScenario: s\n  Given a\n  Then b\n```') === '');
ok('toolbar skeleton passes',
  validateGherkinBlocks('- [ ] **Scenario name**\n```gherkin\nScenario: Scenario name\n  Given \n  When \n  Then \n```\n') === '');

// Each malformed branch — the four T4 error branches, one case each.
ok('branch 1: step before any Scenario is blocked',
  /before any Scenario/.test(validateGherkinBlocks('```gherkin\nGiven cart_total 10\nScenario: x\n  Then ok\n```')));
ok('branch 2: Scenario with no steps is blocked',
  /no Given\/When\/Then/.test(validateGherkinBlocks('```gherkin\nScenario: empty\nScenario: real\n  Given a\n```')));
ok('branch 3: unrecognized keyword among steps is blocked',
  /Unrecognized Gherkin keyword/.test(validateGherkinBlocks('```gherkin\nScenario: x\n  Given a\n  Wen b\n```')));
ok('branch 4: unclosed fence is blocked',
  /Unclosed/.test(validateGherkinBlocks('```gherkin\nScenario: x\n  Given a\n')));
ok('block with no Scenario is blocked',
  /has no Scenario/.test(validateGherkinBlocks('```gherkin\nFeature: f\n```')));

if (fails) { console.error(`sprint-check-gherkin: ${fails} FAILED`); process.exit(1); }
console.log('sprint-check-gherkin: ok');
