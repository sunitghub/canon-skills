# Plan

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-c723`
<!-- Keep this doc under ~500 words — it is injected at every session start. -->

## Sign-off
<!-- Fill in: Tier: <tier> | Risk: <blast radius / key risks, one line> -->
<!-- Optional, append: | Gate model: <value> -- forces the sprint-close reviewer/evaluator onto that model, overriding the automatic Admin Reviewer and Evaluator defaults. Valid values (case-insensitive): a model id (e.g. haiku, sonnet, opus), or the literal "session" to force full session-model review. Omit entirely for automatic behavior -- there is no separate "auto" value; absence already means automatic. -->

Tier: high-risk | Risk: the daemon types into a live Copilot session from a file it does not control; every close's gate-model line

- [ ] Plan approved — proceed to implementation
Approved: sha256:634bb1173d25d1bc194fabd917b463c104f771b44e7aa86118b09610a525863b 2026-11-16T08:48:08Z
Pipeline: sha256:1de8c9fc6b17 off=- wrapup=code-simplifier,code-reviewer,doc-audit

## Approach
1. **Copilot turn end (daemon).** New `daemon/copilotturn.go`: for a copilot session, a watcher polls `copilotHomeDir()/session-state/<sid>/events.jsonl` (1 s): Lstat must be a regular file; read only whole lines from the last offset (a resume starts at the size seen at spawn); skip lines over 8 MiB and malformed JSON; decode only `type`, `agentId`, `data.toolRequests`. Main-agent `assistant.message` records whether it asked for tools; `assistant.turn_end` with none and no running subagent (`subagent.started` minus `completed`/`failed`) → `se.setStatus("awaiting-input")` + `go s.switchToBuild(se)` (the same call `handleStatus` makes); main-agent `assistant.turn_start` → `running` (not `user.message`: the daemon's own `/model` must not cancel its continue line). Stops when the session exits. `waitAtRest` and the t-3425 rules are unchanged. New session field `copilotSID` (convID stays Claude's).
2. **Gate model printed before dispatch.** `sprint gate-model <id> <reviewer|evaluator|speccheck>`: a `Gate model:` line or a Lite evaluator → `ticket rule: …`; else `_admin_stage_model <role> <agent>` (agent: COCKPIT_AGENT, else copilot when COPILOT_CLI=1, else claude; pi: none) → the id, or `none: omit model` (also for a Haiku evaluator pick or a Claude alias outside fable/opus/sonnet/haiku; speccheck falls back to the reviewer pick). `gate-snapshot.sh pre --role` prints it as one line. complete-checklist.md's Model bullet: pass the model gate-snapshot printed; the full rule stays in complete.md.
3. **Report shape.** One sentence in `agents/canon-evaluator.md`; `cmd_eval_verdict` refuses a verdict-like line with no `^(pass|fail):` (exit 1, names `pass: <summary>` / `fail: <summary>`, count unchanged).
4. Tests per Test Plan; replace `TestSwitchToBuildCopilotTypesCopilotID`'s hand-set status with the log. t-4239 item. Daemon release.

## Files
`tools/canon-go/internal/daemon/copilotturn.go` (new), `daemon/main.go` (field, start watcher at spawn), `daemon/main_test.go` or `copilotturn_test.go`; `tools/sprint`, `tools/gate-snapshot.sh`; `agents/canon-evaluator.md`; `skills/sprint/reference/complete-checklist.md`, `start-checklist.md`, `start.md` step 10 (spec checker's model line); `tools/sprint` usage block and `cmd_eval_verdict` header; a tests/*.sh (registered in scripts/test.sh if new); CHANGELOG at release.

## Decisions
- Signal: Copilot's events.jsonl, read-only; no Copilot hook or settings write (user, grill 1). `session.idle` is never on disk.
- Gate model: printed by canon before dispatch, no Copilot settings (grill 2). The ticket's Copilot-only agent files are dropped: two files per gate and a copy written into projects; the printed line is the agent's next step (t-fcb1); the after-the-fact check is t-2af1 (`modelSelectionSource` per gate run). Spec-check findings 1-7 adopted (user, 2026-11-16).
- Report shape: agent file + eval-verdict (grill 3). Mac [manual] run now, Windows on t-4239 (grill 4).
- Number moved: Copilot gate re-runs from report shape (Windows run: 1 of 2 evaluator runs) → 0; Build switch fires on Copilot: 0% → 100% of approvals.

## Grill
1. events.jsonl (user, 2026-11-16). 2. Print pre-dispatch. 3. Both. 4. Mac now + VM later.

## Pre-mortem
1. Types while Copilot still works (a background subagent, a queued message) → subagent counter + `waitAtRest`'s 2 s quiet + no menu; test a running subagent.
2. A huge `model.messages_snapshot` line → read cap, skip; test.
3. Replaying an old turn_end on resume → offset at spawn; test.
4. A planted symlink/FIFO log blocks or reads elsewhere → Lstat regular, no follow; test.
5. Wrong agent outside Cockpit → COPILOT_CLI check; Windows unverified → t-4239.
6. A test pins checklist phrases (t-fcb1) → grep tests/ for every phrase changed.

## Impact
Readers of `awaiting-input` for copilot: board state (`done`, was working/idle), `switchToBuild`, `waitAtRest`; reaper unchanged (activity-based). gate-snapshot output is read by every gate dispatch (Claude too: an extra line).
