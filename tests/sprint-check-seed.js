#!/usr/bin/env node
// sprint-check-seed — unit coverage for the Test Plan runner-placeholder seeding (t-321a).
//
// Loads the REAL hasGherkinScenario / seedTestPlanRunnerPlaceholder out of
// the board's scripts (tests/board-script.js) into a vm sandbox (not a copy) and asserts the board seeds a Test
// Plan placeholder when an Acceptance doc has a Gherkin scenario, never clobbers a real command, is
// idempotent, and does nothing without a scenario.
const { loadBoard } = require('./board-script');

const ctx = loadBoard();

const { hasGherkinScenario, seedTestPlanRunnerPlaceholder, criteriaCursorOffset } = ctx;
const TEST_PLAN_RUNNER_PLACEHOLDER = '- [ ] <the agent writes the runner command here after building the runner>';
let fails = 0;
function ok(name, cond, detail) {
  if (cond) { console.log('  ok   ' + name); }
  else { fails++; console.log('  FAIL ' + name + (detail != null ? '  => ' + JSON.stringify(detail) : '')); }
}
const countPlaceholder = (s) => s.split(TEST_PLAN_RUNNER_PLACEHOLDER).length - 1;

ok('helpers loaded from the board scripts',
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

// 7. criteriaCursorOffset — caret lands inside ## Criteria (after its last line, before ## Test Plan).
{
  ok('criteriaCursorOffset loaded', typeof criteriaCursorOffset === 'function');
  const doc = 'Ticket: `t-x`\n\n## Criteria\nThe checklist...\n<!-- guide -->\n\n- [ ]\n\n## Test Plan\n<!-- g -->\n- [ ]\n\n## QA\n- [ ] Tested locally';
  const off = criteriaCursorOffset(doc);
  const tpIdx = doc.indexOf('## Test Plan');
  ok('offset is inside the Criteria section (before ## Test Plan)', typeof off === 'number' && off > doc.indexOf('## Criteria') && off < tpIdx, { off, tpIdx });
  ok('offset lands at end of the last Criteria line (the empty checkbox)', doc.slice(0, off).endsWith('- [ ]'), doc.slice(off - 6, off));
}

// 8. No ## Criteria heading → null.
ok('criteriaCursorOffset returns null without a Criteria heading', criteriaCursorOffset('## Notes\n- [ ] x') === null);

// 9. Skips the guide comment / blank when Criteria already has a real criterion.
{
  const doc = '## Criteria\n<!-- guide -->\n- [ ] **Real criterion**\n\n## Test Plan\n- [ ]';
  const off = criteriaCursorOffset(doc);
  ok('offset lands after the real criterion line, not the comment', doc.slice(0, off).endsWith('**Real criterion**'), doc.slice(0, off));
}

console.log(fails === 0 ? 'sprint-check-seed: ok' : `sprint-check-seed: ${fails} FAILED`);
process.exit(fails === 0 ? 0 : 1);
