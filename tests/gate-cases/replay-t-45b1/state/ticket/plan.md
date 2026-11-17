# Plan

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-45b1`
<!-- Keep this doc under ~500 words — it is injected at every session start. -->

## Sign-off
<!-- Fill in: Tier: <tier> | Risk: <blast radius / key risks, one line> -->
<!-- Optional, append: | Gate model: <value> -- forces the sprint-close reviewer/evaluator onto that model, overriding the automatic Admin Reviewer and Evaluator defaults. Valid values (case-insensitive): a model id (e.g. haiku, sonnet, opus), or the literal "session" to force full session-model review. Omit entirely for automatic behavior -- there is no separate "auto" value; absence already means automatic. -->

Tier: normal | Risk: the pane header for every Cockpit session (daemon page + board message); a daemon release

- [ ] Plan approved — proceed to implementation
Approved: sha256:c840f6c67cb61b8ad3df1268d7425ca62cf62b94f4f9e18e142e2c00b88fe346 2026-11-16T23:50:00Z
Pipeline: sha256:1de8c9fc6b17 off=- wrapup=code-simplifier,code-reviewer,doc-audit

## Approach
<!-- Describe how you will implement this. Keep this heading unchanged. -->
Scope: the "First slice" and "pane header's layout" sections of this ticket only; the transcript-read models/context/tokens (the Outcome above) stay for later.
1. Daemon (internal/daemon/main.go handleSessions): sessionInfo gains `model` and `stage`, filled from se.model and se.stage under the session lock.
2. Board (static/board-cockpit.js): postPaneInfo sends the fields separately: {model, stage, cache_pct, llm_calls, tool_calls, sub_agents, cwd} (meter fields only when the row has a meter); the early-return path sends the same shape, empty.
3. Daemon page (internal/daemon/web/cockpit.html): the header wraps into two rows: row 1 keeps brand, start controls, then the labelled info fields, spacer, A−/A+, status; row 2 is the folder path (its own full-width line, left-aligned, rtl clip kept). The pane-info handler builds the fields with textContent only; a small display-name helper turns model ids into names (Sonnet 5.5).
4. Tests: daemon Go test for the row fields; frame_test.go's header pins and the specs that post the old meter string updated; new spec for the two rows and the edge states; revert proofs.

## Files
<!-- List files to create or modify. -->
`tools/canon-go/internal/daemon/main.go`, `tools/canon-go/internal/daemon/web/cockpit.html`, `tools/canon-go/internal/daemon/frame_test.go` (+ a main_test case), `tools/sprint-check-app/static/board-cockpit.js`, `tests/sprint-check-app.spec.js`; daemon release.

## Decisions
<!-- Record non-obvious tradeoffs and why. Answer each item under the ticket's ## Open questions here, or write "carried forward: <question>". Keep this heading unchanged. -->
