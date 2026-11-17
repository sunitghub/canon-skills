# Acceptance

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-f7e6`

## Criteria
The checklist of behavior that must be true before the sprint can close.
<!-- Add or edit checklist items below. Keep this heading unchanged. -->
<!-- Optional style for behavior: When <trigger>, <system> <does response>. Example: When tkt gets an unknown id, it exits 1 and names the id. Docs and files stay free text. -->

- [ ] In a linked worktree, every bash writer into `.tickets/` or `.claude/` refuses, with one stderr line naming the path and the link (t-f7e6), when a folder from the worktree root down to the target is a link or junction (`.tickets` itself included) or the target (or its `.tmp`) exists and is not a plain file; nothing is created or changed outside the worktree (a dangling link's target is not created either). The writers: frontmatter-lib.sh's `set_field`, `set_or_add_field`, `remove_field`; tkt `ensure_tickets_dir` (its `.gitignore` seed), ACTIVE (`set_active`), `cmd_create`, `.cockpit-cwd`, `cmd_learn`, `cmd_land`'s markers, `cmd_compact`'s archive, `_gh_trail`, `_export_machine_log`, the import paths (`_safe_ticket_path`); ticket-root.sh `copy_ticket_back` (its source folder); sprint `cmd_start`, `cmd_approve`, `cmd_relay_report`, `cmd_manual_qa`, `cmd_eval_verdict`; sprint-headless's and sprint-headless-eval's ticket writes; `evidence.sh stamp`; `subagent-log.sh` (`.claude/subagent-runs.jsonl`); `gate-snapshot.sh`; `work-beat`. A refusal makes the command exit non-zero, except the best-effort heartbeat (work-beat) and GitHub trail (`_gh_trail`), which print the line and skip.
- [ ] "In a linked worktree" is asked of git from the command's own working folder (once per process), never from the target path, so a planted link cannot make the target look like a main checkout; a target outside that worktree (CANON_TICKETS_DIR naming the main checkout's `.tickets`) and any write in a main checkout, a linked `.tickets` of the person's own included, behave as today. `tickets_dir` is unchanged (reads still resolve as before).
- [ ] One copy of the rule: `_is_dir_link`, `_under_link` and `_not_regular` move from tools/skills/project.sh to tools/platform-lib.sh unchanged; `wt_write_ok <path>` there is the one worktree check; `_safe_ticket_path` uses `_under_link` instead of its own `-L` walk; ticket-root.sh and frontmatter-lib.sh load platform-lib.sh themselves, and a missing helper refuses (fails closed), never passes. tests/worktree-links-parity.sh still holds bash and Go in step.

## Test Plan
The commands or checks that prove the criteria work.
<!-- Add or edit test commands below. Keep this heading unchanged. -->

- [ ] A new `tests/worktree-write-links.sh` registered in scripts/test.sh (protects every tkt/sprint/gate write in a linked worktree: the Cockpit's and `tkt land`'s). Two layouts: a worktree with its own real `.tickets` (tracked; needed for the `.claude` cases, since `project_root` is the main checkout otherwise) and one without. Planted: `.tickets` → an outside git repository; `.tickets/<id>` → outside; `ticket.md`, `plan.md`, `ticket.md.tmp` → an outside file; a dangling link at `.tickets/.gitignore`; `.claude` → outside; `.claude/subagent-runs.jsonl` → an outside file. Each listed writer refuses with the line and a non-zero exit (work-beat and `_gh_trail`: the line, exit 0), every outside file is byte-identical and no outside file appears. Passes today: a target folder not yet made; CANON_TICKETS_DIR naming main's `.tickets` from a worktree; a main checkout whose `.tickets` is the person's own link; a worktree without `.tickets` whose main `.tickets` is such a link. Revert-proof per choke point.
- [ ] In the same test: `_under_link()`, `_not_regular()`, `_is_dir_link()` and `wt_write_ok()` are each defined exactly once under tools/, and no writer in tools/ keeps its own `-L` walk; a shell that loads only ticket-root.sh or frontmatter-lib.sh refuses a planted write (fail closed).
- [ ] `bash tests/worktree-links-parity.sh`, `tests/skills-mirror-gitignore.sh`, `tests/tkt-land.sh`, `tests/tkt-merge-branch.sh`, `tests/sprint.sh`, `tests/evidence.sh`, `tests/tkt-send-issue.sh`, `tests/ticket-root-worktree.sh`, `tests/frontmatter-lib.sh` pass unchanged.
- [ ] [manual] Windows (Git Bash): the same refusal for a junction, recorded on the VM.
- [ ] Full suite once, stamped.

## QA
Edge cases and sign-off.
<!-- Add or edit QA items below. Keep this heading unchanged. -->

- [ ] Tested locally

