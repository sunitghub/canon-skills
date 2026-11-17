# Plan

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-788f`
<!-- Keep this doc under ~500 words — it is injected at every session start. -->

## Sign-off
<!-- Fill in: Tier: <tier> | Risk: <blast radius / key risks, one line> -->
<!-- Optional, append: | Gate model: <value> -- forces the sprint-close reviewer/evaluator onto that model, overriding the automatic Admin Reviewer and Evaluator defaults. Valid values (case-insensitive): a model id (e.g. haiku, sonnet, opus), or the literal "session" to force full session-model review. Omit entirely for automatic behavior -- there is no separate "auto" value; absence already means automatic. -->

Tier: high-risk | Risk: a close path that runs one local gate (manual-qa) because the cloud already ran the full close and merge-pr checked the graded head; must refuse every other shape; demo Fri

- [ ] Plan approved — proceed to implementation
Approved: sha256:538a4e2367eceae8a06a472e211f0d3a44066f0ff7ed9c326a3bdb69476558a5 2026-11-16T15:22:54Z
Pipeline: sha256:1de8c9fc6b17 off=- wrapup=code-simplifier,code-reviewer,doc-audit

## Approach
<!-- Describe how you will implement this. Keep this heading unchanged. -->
1. **github-status (tools/tkt).** One predicate `_cloud_close_counts <ticket.md>`: status closed, or manual: true with cloud_status: closed. The `late` check (~3100), the `trk` skip (~3113) and `results-in` (~3136) all use it.
2. **Card + form.** board-github.js `ghTestClose(t)` (runs github, merged, manual true, cloud_status closed, status open) → a **Test & close** button before the Start fallback. It opens a small dialog (the board's base dialog): "Tested by" (prefilled from the last value, kept per viewer), one or more steps "What you tested" + Pass/Fail, then **Record and close**. The board route `POST …/github/test-close` (internal/board/main.go, beside merge/land; apiGitHubPostRe ~2438 gains it; a new `resolveSprint` with a SPRINT_BIN override like resolveTkt's TKT_BIN, so tests stub it) validates the payload (1-10 steps, each 1-200 chars, no newline or `|`; by 1-80 chars) and runs `sprint manual-qa <id> --by … --step "<what>|pass|fail"…` then, only when every step passed, `sprint complete <id>`, in the tab's project, never through a shell; the dialog shows both outputs. A fail step records it and does not close (the dialog says so).
3. **Close (tools/sprint cmd_complete; the dispatcher ~2478 passes its args).** When an id is given and it is not the active in_progress sprint, take the manual-after-merge path only if all hold: manual true; cloud_status closed; status open; `merged:` names a merge commit whose second parent (the PR head) is graded-head plus merge-safe late docs only (`late_docs_delta`, tools/ticket-root.sh, re-run here: `merged:` is also written by github-status's poll and `tkt merged`, which never check the graded head); eval-report.md has a `^pass:` line (not `_gate_eval_report_verdict`, which also accepts eval_override); every criterion other than [manual] ones is ticked; `_manual_qa_state` fresh with ≥1 pass and 0 fail. Then tick the [manual] criteria ("— manual-qa.md <date>"), `TKT_SPRINT_GATE_PASSED=1 tkt close`, sprint.completed and close.confirmed `tier=manual-merged` (≤16 chars, events.go:63), handoff_recent, "Sprint completed". Any miss: refuse, name it, write nothing. No id, or the active id: today's path unchanged; another id while a sprint is active and the shape does not match: refuse (today it closed the active sprint, ignoring the id).
4. `_manual_next` and import-results' next lines keep their text (they become true).
5. Tests: github-status cases, a board spec, cloud-round-trip.sh end to end plus refusals, a tests/sprint.sh case for the active id; revert-proofs.

## Files
<!-- List files to create or modify. -->
`tools/tkt`, `tools/sprint`, `tools/sprint-check-app/static/board-github.js` (+ the dialog), `tools/canon-go/internal/board/main.go` (the route; a canon-go daemon release), tests: `tests/cloud-round-trip.sh`, the github-status test file, `tests/sprint.sh`, a board spec; `skills/sprint/reference/complete.md` (one paragraph: the manual-after-merge close), `docs/plugins.md` (the close.confirmed tier values: + manual-merged); CHANGELOG at release.

## Decisions
<!-- Record non-obvious tradeoffs and why. Answer each item under the ticket's ## Open questions here, or write "carried forward: <question>". Keep this heading unchanged. -->
- North star: this never drops below the binding evaluator: the cloud's evaluator graded this exact code (merge-pr refused any head other than graded + late docs), and its transcript cannot travel (t-b650), so re-running it here would grade the same code twice. The local gate is the one thing the cloud could not do: the person's test.
- The close ticks [manual] criteria itself from a fresh all-pass manual-qa.md, so the board path needs no hand edit of acceptance.md.
- `_manual_mode_refusal` (Manual refused on high-risk or for some file kinds) is not applied on this path: the cloud copy ran with Manual off and the full gate set (t-e790); Manual here only means "the person tests after the merge".
- A squash or rebase merge has no second parent to check: refused, naming it (close with the full gates in a worktree).

## Grill
- Close path: manual test only (user, 2026-11-16): the cloud ran every gate on this code; the local gate is the person's test.
- [manual] ticks: the close ticks them from a fresh all-pass manual-qa.md (user).
- Card: a small form that records the test and closes (user), not a typed Terminal line.

## Pre-mortem
- The new path closes a ticket it should not: guarded by six conditions (open, manual, cloud_status closed, merged, verdict pass, fresh all-pass manual-qa) and a refusal test per condition; it never runs for no id or the active sprint.
- A forged frontmatter (someone writes merged: by hand) skips the evaluator: merged: is written only by merge-pr/github-status after GitHub says MERGED; the path also requires an imported eval-report pass. Residual: a hand-edited ticket can claim this path, as it can already claim other fields; out of scope, named in DECISIONS.
- The form's text reaches a command line: args only (exec, no shell), length and character checks, `|` refused (manual-qa's separator).
- github-status change flips other tickets' stages: the predicate only widens for manual + cloud_status closed; tests pin non-Manual and Manual-not-closed.

## Impact
- tkt github-status → the board card and Cloud row for cloud Manual tickets only.
- sprint complete <id> → a new branch only for the named shape; no-id behaviour unchanged.
- Board: one route, one card button, one dialog; daemon/board binary release (canon-go).
