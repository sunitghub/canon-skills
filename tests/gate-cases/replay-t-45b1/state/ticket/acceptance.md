# Acceptance

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-45b1`

## Criteria
The checklist of behavior that must be true before the sprint can close.
<!-- Add or edit checklist items below. Keep this heading unchanged. -->

- [ ] The daemon's /sessions row carries the session's own `model` and `stage` (plan, switching or build; the Plan pick at spawn, the Build pick after the switch); empty for pi and terminal sessions.
- [ ] The Cockpit pane header has two rows. Row 1, after the agent picker and Run sprint: `Model <name> · <stage>`, `Cache <n>%`, `LLM calls <n>`, `Tool calls <n>`, `Subagents <n>` (labelled; Subagents shown at 0), then A−/A+ on the right. Row 2: the session's folder (the worktree for a worktree session), left-aligned, full width, cut from the left only when the pane is narrower than the path, the full path as its tooltip. A model id shows as its display name (`claude-sonnet-5-5` and `claude-sonnet-5.5` → `Sonnet 5.5`; an alias stays as written).
- [ ] Before the session's first answer (no meter yet), row 1 shows the model and stage only; a session with no model (pi) shows the counts only; nothing reads "undefined".

## Test Plan
The commands or checks that prove the criteria work.
<!-- Add or edit test commands below. Keep this heading unchanged. -->

- [ ] Criterion 1 (every Cockpit session, the board's pane header): daemon Go test: a spawned session's /sessions row has model and stage; after switchToBuild, the Build model and stage build; a pi session has neither.
- [ ] Criterion 2-3: board spec on the real page: the labelled fields in row 1 from a stubbed row (meter, model, stage), the path alone on row 2, left-aligned, with its title; the display name; no meter → model only; no model → counts only; both themes, no horizontal scroll at a narrow pane. Update frame_test.go TestCockpitPaneHeader and the specs that pin the old one-string meter. Revert-prove the second row and the labels.
- [ ] Release gate: full-suite stamp from a plain clone and a full board spec.

## QA
Edge cases and sign-off.
<!-- Add or edit QA items below. Keep this heading unchanged. -->

- [ ] Tested locally

