#!/usr/bin/env node
// sprint-check-seed — unit coverage for the Test Plan runner-placeholder seeding (t-321a).
//
// Loads the REAL hasGherkinScenario / seedTestPlanRunnerPlaceholder out of
// tools/sprint-check-app/app.html into a vm sandbox (not a copy) and asserts the board seeds a Test
// Plan placeholder when an Acceptance doc has a Gherkin scenario, never clobbers a real command, is
// idempotent, and does nothing without a scenario.
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

const { hasGherkinScenario, seedTestPlanRunnerPlaceholder } = ctx;
const TEST_PLAN_RUNNER_PLACEHOLDER = '- [ ] <the agent writes the runner command here after building the runner>';
let fails = 0;
function ok(name, cond, detail) {
  if (cond) { console.log('  ok   ' + name); }
  else { fails++; console.log('  FAIL ' + name + (detail != null ? '  => ' + JSON.stringify(detail) : '')); }
}
const countPlaceholder = (s) => s.split(TEST_PLAN_RUNNER_PLACEHOLDER).length - 1;

ok('helpers loaded from app.html',
  typeof hasGherkinScenario === 'function' && typeof seedTestPlanRunnerPlaceholder === 'function');

ok('detects a fenced gherkin scenario', hasGherkinScenario('x\n```gherkin\nScenario: s\n  Given a\n```'));
ok('detects a bare Scenario: line', hasGherkinScenario('## Criteria\nScenario: foo'));
ok('detects a gherkin-file reference', hasGherkinScenario('```gherkin-file\nfeatures/x.feature\n```'));
ok('no false positive on plain prose', !hasGherkinScenario('## Criteria\n- [ ] do the thing'));

// 1. Scenario present + empty Test Plan (empty checkbox) → placeholder fills the empty slot.
{
  const doc = '## Criteria\n```gherkin\nScenario: s\n  Given a\n  Then b\n```\n\n## Test Plan\n<!-- c -->\n- [ ]\n\n## QA\n- [ ] Tested locally';
  const out = seedTestPlanRunnerPlaceholder(doc);
  ok('seeds placeholder when scenario present + Test Plan empty', out.includes(TEST_PLAN_RUNNER_PLACEHOLDER) && countPlaceholder(out) === 1, out);
  ok('placeholder lands under ## Test Plan (before ## QA)',
    out.indexOf(TEST_PLAN_RUNNER_PLACEHOLDER) > out.indexOf('## Test Plan') && out.indexOf(TEST_PLAN_RUNNER_PLACEHOLDER) < out.indexOf('## QA'), out);
}

// 2. Scenario present + Test Plan already has a real command → unchanged (never clobber).
{
  const doc = '```gherkin\nScenario: s\n  Given a\n  Then b\n```\n\n## Test Plan\n- [ ] `node dsl_runner.js specs/x.feature` exits 0\n';
  const out = seedTestPlanRunnerPlaceholder(doc);
  ok('never clobbers an existing real command', out === doc, out);
}

// 3. No scenario → unchanged (no placeholder).
{
  const doc = '## Criteria\n- [ ] do a thing\n\n## Test Plan\n- [ ]\n';
  const out = seedTestPlanRunnerPlaceholder(doc);
  ok('no placeholder without a scenario', out === doc && !out.includes(TEST_PLAN_RUNNER_PLACEHOLDER), out);
}

// 4. Idempotent: applying twice does not duplicate.
{
  const doc = '```gherkin\nScenario: s\n  Given a\n  Then b\n```\n\n## Test Plan\n- [ ]\n';
  const once = seedTestPlanRunnerPlaceholder(doc);
  const twice = seedTestPlanRunnerPlaceholder(once);
  ok('idempotent (no duplicate on re-apply)', once === twice && countPlaceholder(twice) === 1, twice);
}

// 5. No ## Test Plan heading → unchanged (nothing to seed under).
{
  const doc = '```gherkin\nScenario: s\n  Given a\n  Then b\n```\n\n## Criteria\n- [ ] x\n';
  ok('no Test Plan heading → unchanged', seedTestPlanRunnerPlaceholder(doc) === doc);
}

console.log(fails === 0 ? 'sprint-check-seed: ok' : `sprint-check-seed: ${fails} FAILED`);
process.exit(fails === 0 ? 0 : 1);
