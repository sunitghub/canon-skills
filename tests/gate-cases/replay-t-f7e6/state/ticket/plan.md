# Plan

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-f7e6`
<!-- Keep this doc under ~500 words — it is injected at every session start. -->

## Sign-off
<!-- Fill in: Tier: <tier> | Risk: <blast radius / key risks, one line> -->
<!-- Optional, append: | Gate model: <value> -- forces the sprint-close reviewer/evaluator onto that model, overriding the automatic Admin Reviewer and Evaluator defaults. Valid values (case-insensitive): a model id (e.g. haiku, sonnet, opus), or the literal "session" to force full session-model review. Omit entirely for automatic behavior -- there is no separate "auto" value; absence already means automatic. -->

Tier: high-risk | Risk: file writes on branch-controlled paths; a wrong check either lets a planted link through or refuses every worktree write

- [ ] Plan approved — proceed to implementation
Approved: sha256:980078dca046f5c73771940e7c6f04e10df071a8a72f8da3bf458f0da4b95faa 2026-11-15T14:13:04Z
Pipeline: sha256:1de8c9fc6b17 off=- wrapup=code-simplifier,code-reviewer,doc-audit

## Approach
<!-- Describe how you will implement this. Keep this heading unchanged. -->
Tier: high-risk — file writes on paths a branch or cloud PR controls (a security boundary), across every tkt/sprint/gate writer.

1. tools/platform-lib.sh: move `_is_dir_link`, `_under_link`, `_not_regular` from tools/skills/project.sh verbatim. Add `wt_write_ok <path>`: once per process ask git from `$PWD` (not the target: a planted link would answer for the outside repo) for its top level, git dir and common dir; when they say linked worktree and <path> lies under its top level (physical or logical form), return 1 with `canon: refusing to write <path>: <what> is a link or junction in this worktree (t-f7e6)` when `_under_link <top> <path>` or `_not_regular <path>`; else 0.
2. ticket-root.sh and frontmatter-lib.sh load platform-lib.sh themselves (the idiom at ticket-root.sh:218); callers write `wt_write_ok … || <refuse>`, so a missing helper (127) refuses. `tickets_dir` unchanged. `_safe_ticket_path` (tkt:1203) calls `_under_link` instead of its walk.
3. Writers call it before writing, per criterion 1 (for `set_*` on `<file>.tmp` too; `copy_ticket_back` on its source folder, rooted at the worktree).
4. Tests per the Test Plan (characterize first: the planted-link writes go outside before the fix). Docs: CHANGELOG; a DECISIONS row (gitignored: not committed).

## Grill
- Why worktrees only? User decision: a main checkout's links are the person's own; a worktree's tree is the branch's. Falsifier: a main-checkout write refused.
- Why refuse at the write, not redirect in `tickets_dir`? A redirect to main's `.tickets` would put a tracked-layout worktree's writes into main's copy, which `tkt merge` then trusts when the worktree path is a link (tkt:2370-2378): it weakens the merge guard (spec check 2). Reads keep resolving as today.
- Why ask git from $PWD? From the target's folder git follows the planted link and can answer for an outside repository (spec check 3). Residual: a command run with its cwd inside a planted link is not seen as a worktree; canon's commands run from the checkout root.
- Race (check then write)? Bash has no O_NOFOLLOW; the check is right before the write; a racing swap needs code already running in the worktree. Same residual as t-f5e4's bash side.
- Windows: `_is_dir_link` spawns PowerShell per existing folder it walks, only on worktree writes (about two per ticket write; reads untouched since tickets_dir is unchanged); the junction case is a [manual] Windows check on t-e88d.

## Impact
Every tkt/sprint/gate write path in a worktree; readers of the moved helpers (skills/project.sh, cmd-refresh.sh, tests/skills-mirror-gitignore.sh, tests/worktree-links-parity.sh). The board and daemon are slices t-f278 and t-61f4.

## Files
<!-- List files to create or modify. -->
- `tools/platform-lib.sh`, `tools/skills/project.sh`, `tools/ticket-root.sh`, `tools/frontmatter-lib.sh`, `tools/tkt`, `tools/sprint`, `tools/sprint-headless`, `tools/sprint-headless-eval`, `tools/evidence.sh`, `tools/subagent-log.sh`, `tools/gate-snapshot.sh`, `tools/work-beat`
- `DECISIONS.md` (gitignored, not committed)
- `tests/worktree-write-links.sh` (new), `scripts/test.sh`
- `CHANGELOG.md`

## Decisions
<!-- Record non-obvious tradeoffs and why. Answer each item under the ticket's ## Open questions here, or write "carried forward: <question>". Keep this heading unchanged. -->
- Split (user, 2026-11-15): this sprint bash; board t-f278; daemon t-61f4.
- Worktrees only (user, 2026-11-15).
- Shell only: no daemon release.
- Number it moves: canon writers into a worktree's .tickets/.claude that follow a planted link: ~20 bash writers → 0 (board and daemon in their slices).
