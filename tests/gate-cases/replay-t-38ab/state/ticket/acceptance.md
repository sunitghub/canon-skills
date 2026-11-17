# Acceptance

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-38ab`

## Criteria
The checklist of behavior that must be true before the sprint can close.
<!-- Add or edit checklist items below. Keep this heading unchanged. -->

- [ ] `skills.sh refresh` on a project whose `.claude/skills` and `.agents/skills` are EMPTY real folders replaces each with a link to canon's `skills/`; a second refresh changes nothing.
- [ ] The same for a real folder holding only canon-named skill folders whose files are symlinks into canon or byte-identical copies of canon's current files (the Windows `ln` copies): it becomes a link, nothing else is touched.
- [ ] A real `.claude/skills` holding any project-local entry (a skill folder canon has no skill of that name for, or a file) stays a real folder: the local entry is byte-identical afterwards, and each canon skill folder in it serves the whole skill (`reference/`, `gates/` and any file, not only SKILL.md), through links on macOS/Linux.
- [ ] A canon-named skill folder whose SKILL.md differs from canon's current (a stale copy) is not overwritten; refresh says so, naming the folder and what to do.
- [ ] `.claude/agents`: an EMPTY real folder, or one holding only `canon-*.md` files that carry the `canon:agent` marker, becomes a link to canon's `agents/`; a folder with any other file keeps it (the file byte-identical) and gets canon's agent files copied in as today.
- [ ] Removal deletes only files proven canon's, one by one, then `rmdir`: a folder where anything else appears while it runs is left, with a line saying so; nothing is removed through a link (t-f5e4's `_under_link` / `_is_dir_link` checks run first).
- [ ] `skills.sh refresh` never prints "All up to date." while `skills.sh status` reports a problem for the same project: after its run it prints `[needs attention]` with each problem from `skill_problems` and its fix.
- [ ] The "missing link" / "stale link" text in `status` and refresh's `[needs attention]` line name the fix for a real folder: remove that skill's own folder (`.claude/skills/<name>`, never the whole skills folder, which may hold the user's own skills), then refresh.
- [ ] `CHANGELOG.md` has an Unreleased note: refresh repairs a copied or empty skills/agents folder, and no longer says "All up to date" over a problem.

## Test Plan
The commands or checks that prove the criteria work.
<!-- Add or edit test commands below. Keep this heading unchanged. -->

- [ ] `bash tests/skills-refresh.sh` (extended): cases for criteria 1-8 above, each on a scratch project with HOME/CANON_HOME/TMPDIR pinned. Protects: `skills.sh refresh` / `add` (what `canon update` runs on every registered project, and the Projects card's Refresh button).
- [ ] The project-local-file case compares bytes before and after; the guard case plants `.claude` as a link to an outside folder and requires the outside folder untouched. Protects: the irreversible step (deleting a real folder) and t-f5e4's rule.
- [ ] `bash tests/skills-agents.sh` and `bash tests/sprint-gate-agents.sh`: the agents-folder rule, same protected path.
- [ ] `bash tests/worktree-links-parity.sh` still passes unchanged (the Go side is untouched). Protects: the one-rule contract with Go.
- [ ] Revert check in a scratch copy: remove the canon-only test, the child linking, and the `[needs attention]` block one at a time; each makes a named case fail.
- [ ] `bash scripts/test.sh` once, stamped with `evidence.sh stamp t-38ab full-suite -- bash scripts/test.sh`.
- [ ] Windows VM (user; deferred, recorded in HANDOFF's "t-38ab built" bullet, not run here; includes a nested junction inside a canon skill folder): ToDo-App-style project with copied real folders: refresh converts them to junctions, status `[ok]`; a project with a local skill keeps it and sprint's `reference/start-checklist.md` reads through `.claude/skills/sprint/`.

## QA
Edge cases and sign-off.
<!-- Add or edit QA items below. Keep this heading unchanged. -->

- [ ] Tested locally

