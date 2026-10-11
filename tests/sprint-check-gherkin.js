#!/usr/bin/env node
// sprint-check-gherkin — unit coverage for the Gherkin acceptance validator (t-6e32).
//
// Loads the REAL functions out of the board's scripts (tests/board-script.js,
// not a copy) and asserts validateGherkinBlocks flags every malformed
// branch and passes well-formed / non-gherkin input. This is the committed
// regression guard behind acceptance.md's C5/T4 — each of the four error
// branches has its own case, so breaking any one branch fails the suite.
const { loadBoard } = require('./board-script');

const ctx = loadBoard();

const { validateGherkinBlocks } = ctx;
let fails = 0;
function ok(name, cond, detail) {
  if (cond) { console.log('  ok   ' + name); }
  else { fails++; console.log('  FAIL ' + name + (detail != null ? '  => ' + JSON.stringify(detail) : '')); }
}

ok('validateGherkinBlocks is loaded from the board scripts', typeof validateGherkinBlocks === 'function');

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
  validateGherkinBlocks('- [ ] **Scenario name**\n```gherkin\nScenario: Scenario name\n  Given \n  And \n  When \n  Then \n  And \n```\n') === '');

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

// ── Structured runner field on ```gherkin-file references (t-6f8e) ──────────
const { parseFeatureRefBody, renderFeatureRefPlaceholder, renderRunnerLabel } = ctx;
ok('parseFeatureRefBody is loaded from the board scripts', typeof parseFeatureRefBody === 'function');

// parseFeatureRefBody — path + runner, path-only, runner-only, order-independent.
const pr = parseFeatureRefBody('features/discount.feature\nrunner: python dsl_runner.py');
ok('parse: path+runner splits src', pr.src === 'features/discount.feature', pr);
ok('parse: path+runner splits runner', pr.runner === 'python dsl_runner.py', pr);
const po = parseFeatureRefBody('features/discount.feature');
ok('parse: path-only has empty runner', po.src === 'features/discount.feature' && po.runner === '', po);
const ro = parseFeatureRefBody('runner: python dsl_runner.py');
ok('parse: runner-only has empty src', ro.src === '' && ro.runner === 'python dsl_runner.py', ro);
const ord = parseFeatureRefBody('runner: node run.js\n\nfeatures/x.feature');
ok('parse: order-independent + blank lines ignored', ord.src === 'features/x.feature' && ord.runner === 'node run.js', ord);

// renderFeatureRefPlaceholder — path+runner carries both attrs, no error.
const phBoth = renderFeatureRefPlaceholder('features/discount.feature\nrunner: python dsl_runner.py');
ok('placeholder: path+runner has data-feature-src', /data-feature-src="features\/discount\.feature"/.test(phBoth), phBoth);
ok('placeholder: path+runner has data-runner', /data-runner="python dsl_runner\.py"/.test(phBoth), phBoth);
ok('placeholder: path+runner is not an error', !/doc-scenario-error/.test(phBoth), phBoth);
// path-only still renders as today, with an empty runner attr.
const phPath = renderFeatureRefPlaceholder('features/discount.feature');
ok('placeholder: path-only renders (no error)', !/doc-scenario-error/.test(phPath) && /data-feature-src=/.test(phPath), phPath);
ok('placeholder: path-only has empty data-runner', /data-runner=""/.test(phPath), phPath);
// runner-only (no valid path) and traversal are error states.
ok('placeholder: runner-only body is an error', /doc-scenario-error/.test(renderFeatureRefPlaceholder('runner: python dsl_runner.py')));
ok('placeholder: traversal path is an error', /doc-scenario-error/.test(renderFeatureRefPlaceholder('features/../secrets.feature')));

// renderRunnerLabel — resolves `<runner> <src>`, empty when no runner, escapes markup.
const lbl = renderRunnerLabel('python dsl_runner.py', 'features/discount.feature');
ok('label: shows resolved command', /python dsl_runner\.py features\/discount\.feature/.test(lbl) && /doc-scenario-runner/.test(lbl), lbl);
ok('label: empty runner renders nothing', renderRunnerLabel('', 'features/x.feature') === '');
const evil = renderRunnerLabel('python x.py; <img src=x onerror=alert(1)>', 'features/x.feature');
ok('label: escapes markup (no raw <img>)', !/<img/.test(evil) && /&lt;img/.test(evil), evil);

if (fails) { console.error(`sprint-check-gherkin: ${fails} FAILED`); process.exit(1); }
console.log('sprint-check-gherkin: ok');
