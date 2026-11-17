# Acceptance

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-c723`

## Criteria
The checklist of behavior that must be true before the sprint can close.
<!-- Add or edit checklist items below. Keep this heading unchanged. -->
<!-- Optional style for behavior: When <trigger>, <system> <does response>. Example: When tkt gets an unknown id, it exits 1 and names the id. Docs and files stay free text. -->

- [ ] When a Cockpit Copilot session's own log (`<COPILOT_HOME or ~/.copilot>/session-state/<sid>/events.jsonl`) gains a main-agent `assistant.turn_end` whose last `assistant.message` has no `toolRequests` (absent or `[]`) and no subagent is still running, the daemon sets the session's status to `awaiting-input` (board state `done`), which runs the t-3425 Build switch (`/model <build>` then the continue line, once, only at rest); a main-agent `assistant.turn_start` sets it back to `running` (a `user.message` or `session.model_change` does not, so the daemon's own `/model` never cancels its continue line). A turn that ends with tool calls, a subagent's turn (`agentId` set), a partial last line, a malformed or over-long (> 8 MiB) line, or a log that is not a regular file changes nothing. A resumed session reads only events written after the spawn.
- [ ] When `gate-snapshot.sh pre <file> --role reviewer|evaluator|speccheck` runs for a ticket with no `Gate model:` line (and, for the evaluator, not Lite), it prints `gate-snapshot: dispatch canon-<role> with model: <id> (Admin <Role> default, <agent>)`, the agent being `COCKPIT_AGENT`, else `copilot` when `COPILOT_CLI=1`, else `claude`; with a `Gate model:` line or a Lite evaluator it prints that the ticket's rule applies (complete.md "Model tier for gates"); with no Admin pick, a Haiku evaluator pick, a Claude pick whose alias is not fable/opus/sonnet/haiku, or a pi session, it prints that the dispatch omits `model`; the spec checker falls back to the reviewer pick when the registry has no speccheck default (`COPILOT_CLI=1`: Copilot sets it for its subprocesses, changelog 0.0.421; checked in the Windows run, t-4239 item 8). `sprint gate-model <id> <role>` prints the same resolution. complete-checklist.md's Model bullet tells the agent to pass that printed model and stays within 900 words.
- [ ] `agents/canon-evaluator.md` says the report's verdict line starts with `pass:` or `fail:` (never `verdict:`, bold or a heading); when eval-report.md has no `^pass:` or `^fail:` line but has a verdict-like line (`verdict: pass`, `**pass:**`, `## pass`), `sprint eval-verdict` exits non-zero naming the expected line and does not change `eval_fail_count`.
- [ ] t-4239 has item 8, "Copilot Build switch and gate model line" (Build switch, gate model line, events.jsonl read while Copilot writes it).

## Deferred (user, 2026-11-16)

- The live Copilot run moved to Windows after the release (user: "commit/push/release so I can test it on Windows"): t-4239 item 8 holds it (Build switch after `sprint approve`, a later `session.model_change` to the Build pick, the gate-snapshot model line naming `copilot`, `explicit_override` on the gates). Before-picture on the VM's 0.61.4, 2026-11-16: Copilot ended its turn after `sprint approve` ("Ending my turn now so the session can switch to the Build model (claude-haiku-5.5)") and stayed on Claude Sonnet 5.5; its events.jsonl held only the `source: startup` model_change.

## Test Plan
The commands or checks that prove the criteria work.
<!-- Add or edit test commands below. Keep this heading unchanged. -->

- [ ] Criterion 1 (the Build switch every Copilot Cockpit session takes; DECISIONS t-3425): Go tests in tools/canon-go/internal/daemon replay recorded events.jsonl lines into a fake copilot session's log: a final no-tools turn_end (toolRequests absent and `[]`) → `awaiting-input`, board state `done`, `/model <build>` then the continue line typed once, with a `user.message` and a `session.model_change` logged between them; the log found under `COPILOT_HOME`; a tools turn_end, an `agentId` turn_end, a running subagent, a partial line, a malformed and an over-8-MiB line, a symlink/FIFO log, and pre-spawn lines of a resumed session → no status change, nothing typed. The old hand-set-status Copilot test now drives the log. Revert-proven (drop the toolRequests check; drop the at-spawn offset). — 2026-11-16: go test ./... ok (daemon 55.7s); revert-proofs.md M1-M6.
- [ ] Criterion 2 (every gate dispatch; complete-checklist.md): a shell test runs `gate-snapshot.sh pre … --role reviewer|evaluator|speccheck` and `sprint gate-model` against a scratch project and registry: Admin Copilot and Claude picks (COCKPIT_AGENT, COPILOT_CLI=1, neither, pi), a `Gate model:` line, a Lite evaluator, no pick, a Haiku evaluator pick, a non-Agent Claude alias, a registry with no speccheck default; grep tests/ for every checklist phrase changed. `bash tests/caps.sh`, `bash tests/sprint-checklists.sh`, `bash tests/doc-mirror-parity.sh` pass. — 2026-11-16: tests/sprint-gate-model.sh ok; caps, sprint-checklists, doc-mirror-parity ok; revert-proofs.md S1-S8.
- [ ] Criterion 3 (the close's verdict gate): a shell test feeds `sprint eval-verdict` a `verdict: pass —` report (non-zero, names `pass:`, count unchanged), a `pass:` report (count 0) and a `fail:` report (count +1); grep the sentence in agents/canon-evaluator.md. — 2026-11-16: tests/sprint-gate-model.sh section 5; revert-proofs.md S8.
- [ ] Criterion 5: `grep -n 'Copilot Build switch and gate model line' .tickets/t-4239/ticket.md` matches. — 2026-11-16: matches line 23.
- [ ] Release gate: full-suite stamp from a plain clone (`go test ./...` included). — 2026-11-16: evidence/test-sh.log exit 0 at 44b318c (185 suites, 418 s); the first stamp at 754b673 failed on sprint-second-eval racing this sprint's new test for one shared CANON_HOME, fixed in 44b318c8 (old pair fails 3/3 in parallel, new pair passes 3/3)

## QA
Edge cases and sign-off.
<!-- Add or edit QA items below. Keep this heading unchanged. -->

- [ ] Tested locally — Go and shell suites on this Mac; the live Copilot run is deferred to the Windows VM after the release (## Deferred); the VM before-picture is in research.md

