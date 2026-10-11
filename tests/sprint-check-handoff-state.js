#!/usr/bin/env node
// sprint-check-handoff-state — unit coverage for the cockpit STATUS panel's
// HANDOFF state resolution (t-8ff0). Loads the REAL handoffDisplayState /
// findHandoffStateForTicket / sectionContent out of the board's scripts (tests/board-script.js)
// (not a copy) and asserts the id-matched In-Progress bullet is
// preferred, that Current Focus is the honest fallback (active sprint OR id named),
// that an unrelated ticket's focus is never shown, and that neither → the hint state.
const { loadBoard } = require('./board-script');

const ctx = loadBoard();

const { handoffDisplayState, findHandoffStateForTicket, sectionContent, handoffNextSteps } = ctx;
let fails = 0;
function ok(name, cond, detail) {
  if (cond) { console.log('  ok   ' + name); }
  else { fails++; console.log('  FAIL ' + name + (detail != null ? '  => ' + JSON.stringify(detail) : '')); }
}

ok('helpers loaded from the board scripts',
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

// t-6ecc: handoffNextSteps — the actionable "## Next Steps" surfaced in STATUS.
ok('handoffNextSteps loaded from the board scripts', typeof handoffNextSteps === 'function');
const WITH_STEPS = [
  '## Current Focus', 'Building the ToDo app', '',
  '## In Progress', '- generic', '',
  '## Next Steps', '1. Run `sprint complete` to close t-pdry.', '',
].join('\n');
// (h) active sprint → returns the Next Steps text.
ok('(h) next steps returned for the active sprint',
  /Run `sprint complete`/.test(handoffNextSteps(WITH_STEPS, 't-pdry', true)), handoffNextSteps(WITH_STEPS, 't-pdry', true));
// (i) not active + id NOT named in the section → '' (never another ticket's steps).
ok('(i) not active + id not named → no steps',
  handoffNextSteps(WITH_STEPS, 't-zzzz', false) === '', handoffNextSteps(WITH_STEPS, 't-zzzz', false));
// (j) not active but the section names the id → returned.
ok('(j) not active but section names the id → returned',
  /Run `sprint complete`/.test(handoffNextSteps(WITH_STEPS, 't-pdry', false)), handoffNextSteps(WITH_STEPS, 't-pdry', false));
// (k) no ## Next Steps section → ''.
ok('(k) missing Next Steps section → empty', handoffNextSteps(LIVE, 't-pdry', true) === '', handoffNextSteps(LIVE, 't-pdry', true));

if (fails) { console.log(`\nsprint-check-handoff-state: ${fails} FAILED`); process.exit(1); }
console.log('sprint-check-handoff-state: ok');
