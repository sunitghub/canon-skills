# Acceptance

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-788f`

## Criteria
The checklist of behavior that must be true before the sprint can close.
<!-- Add or edit checklist items below. Keep this heading unchanged. -->

- [ ] When a Manual ticket is open with `cloud_status: closed`, a passing eval-report on graded-head, and an open PR whose head is graded-head plus merge-safe late docs only, `tkt github-status` reports `results-in` with `land: false` (the card shows Check & merge); a non-Manual open ticket and a Manual one whose cloud copy did not close keep today's stages.
- [ ] When a ticket with `runs: github`, `manual: true` and `cloud_status: closed` is merged (`merged:` set) and still open, the board card shows **Test & close** (not ▶ Start). It opens a form (Tested by; steps: what you tested + Pass/Fail) whose **Record and close** runs `sprint manual-qa` with those steps and, only when all passed, `sprint complete <id>`, showing both outputs; a fail is recorded and the ticket stays open. The board route refuses a malformed payload (no steps, over 10, a step over 200 chars or holding a newline or `|`, an empty name) without running anything.
- [ ] When `sprint complete <id>` names a ticket that is open, `manual: true`, `cloud_status: closed`, whose `merged:` merge commit's second parent is graded-head plus merge-safe late docs only, whose eval-report.md has a `pass:` line, and whose criteria other than [manual] are all ticked, it closes it after one local gate: a fresh manual-qa.md with at least one pass and no fail. It ticks the [manual] criteria citing manual-qa.md, closes the ticket (`tkt close`), and records sprint.completed and close.confirmed (`tier=manual-merged`). When any condition fails it refuses, naming it, and ticket.md, acceptance.md and the events log are unchanged.
- [ ] `sprint complete` with no id, or with the id of the active in_progress sprint, behaves exactly as today (full gate list); with another id that does not match the shape above, it refuses naming the active sprint and that id, instead of closing the active sprint.

## Test Plan
The commands or checks that prove the criteria work.
<!-- Add or edit test commands below. Keep this heading unchanged. -->

- [ ] Criterion 1 (the board card's next step for every cloud Manual ticket): tests/tkt-github-status fixture (or the existing github-status test file): Manual open + cloud_status closed + PR head = graded + late docs → results-in, land false; status closed unchanged; non-Manual open → results-ready/land; Manual with cloud_status in_progress → not results-in. Revert-prove.
- [ ] Criterion 2 (board card and route): Go test of the route with a stub sprint (SPRINT_BIN): payload refusals run nothing; a pass runs manual-qa then complete with exactly those args; a fail runs only manual-qa. Board spec: the button shows only for the named shape; the form posts the steps and shows the outputs. Revert-prove.
- [ ] Criterion 3 (the close): the chain on merge-pr's own record in tests/tkt-merge-pr.sh (GitHub makes a real merge commit; merge-pr writes merged: and moves main; sprint manual-qa; `sprint complete <id>` closes it, [manual] ticked) — moved here from tests/cloud-round-trip.sh, which never runs merge-pr; and tests/sprint-manual-merged.sh: every refusal leaves ticket.md, acceptance.md and the events log unchanged (no manual-qa, stale, n/a-only, a fail step, not merged, merged not in HEAD, PR #n form, a code commit after graded-head, a squash merge, cloud_status not closed, verdict fail, eval_override with a fail verdict, an unchecked non-[manual] item, no acceptance.md, no eval-report, no or two graded-heads, not Manual, not open). Revert-proven. — 2026-11-16, after the first evaluator's fail (the chain was ticked but not written)
- [ ] Criterion 4: tests/sprint.sh unchanged and passing; new cases: `sprint complete <active id>` = no-id behaviour; `sprint complete <other open id>` while a sprint is active refuses and closes nothing.
- [ ] Release gate: full-suite stamp from a plain clone. — 2026-11-16: evidence/test-sh.log exit 0 at 673fdd02. Earlier stamps failed on this branch's pipefail pattern and CANON_TICKETS_DIR in two tests (fixed 61577b71, 673fdd02) and once on two daemon load flakes (TestStartWorktreeLinksGateAgents, TestSpawnUsesAdminStageModel: 3 s file waits, both pass alone; daemon untouched here)

## QA
Edge cases and sign-off.
<!-- Add or edit QA items below. Keep this heading unchanged. -->

- [ ] Tested locally — tests/sprint-manual-merged.sh (a real --no-ff merge, every refusal), tkt-github-status.sh, the route's Go tests, two board specs, the full board spec; the live run is t-m4gt on the Windows VM after 0.63.0

