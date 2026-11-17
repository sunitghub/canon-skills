# Plan

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-38ab`
<!-- Keep this doc under ~500 words — it is injected at every session start. -->

## Sign-off
<!-- Fill in: Tier: <tier> | Risk: <blast radius / key risks, one line> -->
Tier: high-risk | Risk: deletes real folders; runs on every registered project at canon update
<!-- Optional, append: | Gate model: <value> -- forces the sprint-close reviewer/evaluator onto that model, overriding the automatic Admin Review & Eval default. Valid values (case-insensitive): a model id (e.g. haiku, sonnet, opus), or the literal "session" to force full session-model review. Omit entirely for automatic behavior -- there is no separate "auto" value; absence already means automatic. -->

- [ ] Plan approved — proceed to implementation
Approved: sha256:adeb4927de8eae947a7d97f5180bbfbcc3c8253d58b738043defc6a2c529d416 2026-11-04T01:25:07Z

## Approach
bash only (`tools/skills/`); Go untouched. Replacing a real folder is the one irreversible step, so it is allowed only for what is proven canon's.
- `_canon_only_dir <dir> skills|agents` (project.sh): true when `<dir>` is empty, or (skills) every entry is a folder named after a canon skill whose files are symlinks into canon or `cmp`-identical to canon's current, or (agents) every entry is a `canon-*.md` with the `canon:agent` marker. Anything else, or any link, is false.
- `_remove_canon_only_dir`: `rm` each proven file, `rmdir` subfolders deepest first, `rmdir` the folder; a failing `rmdir` leaves the rest with a line. Runs only after `_under_link` / `_is_dir_link` (t-f5e4) say the path is real.
- `upsert_skills_symlinks`: a canon-only real folder is removed and replaced by `_create_dir_link`. Otherwise the per-skill layout stays and `_link_skill_children` serves every child of a canon skill (symlinks; on Windows junctions for folders, `cp` for files). A canon-named folder whose SKILL.md differs is left and reported.
- `upsert_gate_agents`: the same replacement for an empty or marker-only `.claude/agents`.
- `cmd_refresh`: after the loop, run `skill_problems` per registered skill (the one owner `status` uses); each problem prints `[needs attention] <problem>: <fix>`, and "All up to date." prints only with none. `display.sh` problem text names the fix for a real folder.
- Number moved: none; target: `refresh` and `status` agree on every case in the tests.

## Files
`tools/skills/project.sh`, `tools/skills/cmd-refresh.sh`, `tools/skills/display.sh`, `tools/skills/cmd-status.sh`, `tests/skills-refresh.sh` (all new cases, agents too), `CHANGELOG.md`. `tests/skills-agents.sh` and `sprint-gate-agents.sh` run unchanged as regression.

## Decisions
- Safe "canon-only" rule: identical or symlinked files only; an older stale copy is reported, not removed (user, "go").
- Files removed one by one then `rmdir`; no `rm -rf` of unproven content (user).
- Go side untouched: git holds no empty folders, a committed copy is the branch's own (user).
- `[needs attention]` from `skill_problems` so refresh and status share one fact source (user).
- Carried forward: why ToDo-App's folders were real at all (the user's `git ls-files` check): the Windows copy from `ln` explains it; no code depends on the answer.
- Tier: high-risk (deletes real folders; runs on every registered project at `canon update`).

## Grill
Four gray areas (what counts as canon-only, removal method, Go scope, refresh/status agreement), resolved "go" 2026-11-03.

## Pre-mortem
1. A Windows project with local skills sees `[needs attention]` after every `canon update`, because its SKILL.md copies go stale and are never overwritten. Accepted: the line says how to fix it; a proper per-file manifest is a follow-up if it recurs.
2. `cmp`/symlink detection is wrong on Windows (`ln` copies; `readlink` differs), so a canon-only folder is judged project-local and stays. Safe direction (nothing deleted); the VM check covers it.
3. A user's own file named like a canon skill file inside a canon-named folder is judged "differs" and kept: correct.
4. Another writer deletes through the same helper: none; `remove_skills_symlinks` (uninstall) is unchanged.

## Impact Assessment
Audience HIGH (`canon update` refreshes every registered project unattended). Reversibility HIGH (a deleted folder is not recoverable by canon). Blast radius MEDIUM (a wrong keep is harmless; a wrong delete is the risk). Trigger paths MEDIUM (`add`, `refresh`, `init`, the board's Refresh). Cascade LOW.
Required: audit-free (no log); every project-local file byte-identical in tests; the guard case; user approval of this plan.
