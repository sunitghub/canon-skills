---
name: ticket
description: Bundled minimal ticket system (tkt) for creating, tracking, and closing tasks. Used by sprint and sprint-check.
category: tools
tags: [project-management, tasks, cli, git]
hidden: true
---

# Ticket — Task Tracking

This project uses `tkt` for task management — a minimal ticket system bundled with canon.
New tickets are stored as `.tickets/<id>/ticket.md` with YAML frontmatter.
Legacy flat `.tickets/<id>.md` tickets remain readable.

## Key Commands

```bash
tkt create "title" [-t bug|feature|task|epic|chore] [-p 0-4] [-d "desc"]   # no -d: the body is the intent skeleton (Problem, Outcome, Constraints, Open questions; a bug adds Expected, Actual)
tkt ls                        # list all tickets
tkt ls --status=in_progress   # filter by status
tkt ls --json                 # machine-readable (see "Machine-readable output")
tkt start <id>                # mark in_progress
tkt current                   # show active ticket
tkt close <id> [--no-sprint]  # mark closed (refuses without --no-sprint — directs to sprint complete if sprint docs exist, or to sprint start/--no-sprint otherwise)
tkt archive <id>              # mark archived (hidden from board, searchable)
tkt reopen <id>               # reopen
tkt ci <id> [on|off]          # mark CI-eligible for headless grading
tkt gate <id> [eval|full]     # headless gate mode: eval-only vs full (needs ci on)
tkt demo <id> [on|off]        # demo close-path: security-review + evaluator only (Haiku)
tkt tags <id> [csv]           # print or replace a ticket's tags (tkt create --tags a,b); the board finds them with tag:x
tkt show <id> [--json]        # show full ticket
tkt learn <id> [--force]      # distill a closed sprint's deviations/findings into an UNPROMOTED .tickets/<id>/learnings.md candidate (proposes, never promotes)
tkt compact [--older-than DAYS] [--dry-run]  # shrink old closed tickets' evidence/ (default 14 days); sprint complete runs it
tkt send-issue <id> [--dry-run] [--public]  # post the ticket as an issue on origin's GitHub repo for a Claude cloud session
tkt import-issue <N> [--body-file F]  # in the cloud session: rebuild .tickets/<id>/ from that issue (sprint import-issue also starts it)
tkt export <id> [--public]          # at the cloud close: send .tickets/<id>/ back (with the PR, or to canon-results/<id>)
tkt import-results <id> [--pr N]    # on your machine: bring canon-results/<id> back; local edits kept in .before-import/
tkt sync-issues [--dry-run [--json]] [--only N[,N...]] # make a ticket of each open issue labelled canon that no ticket links to (labels: bug|feature|task|chore|epic, p0-p4); --json: the dry run as one object (Factory › GitHub's Intake); --only: make tickets for just those issue numbers (refuses, writing nothing, any that is not waiting)
tkt github-doctor [--json]          # read-only GitHub readiness: gh installed and signed in, origin (public/private), test command; the cloud recipe (Cockpit: Factory › GitHub)
tkt cloud-env [--json]              # this project's Claude cloud environment recipe (domains, setup script) from tools/cloud-env.sh; Go projects get the Go part
tkt merge-pr <id> [--pr N] [--test CMD] [--yes | --check]  # on your machine: check a cloud ticket's PR (evaluator passed on its head, own repo, mergeable, suite green on base + PR) and merge it after a y, then fast-forward the local base branch; --check reports readiness without running anything; progress shows while the tests run (CANON_PROGRESS_SECONDS without a terminal, default 30); a red run names the FAILED/FAIL lines and keeps the full log (path printed)
tkt github-status <id> [--json]      # where a ticket sent to GitHub stands: sent, branch (pushed, no PR), pr-open, results-ready, results-in or merged, plus the canon.mirror remotes (read-only apart from fetching a PR head past graded-head that is not local yet; what the board polls)
tkt open-pr <id>                     # open the PR a cloud session did not, from its pushed branch (a commit naming <id>), with "Fixes #N"
tkt push-main                        # push origin's default branch (what GitHub merged, never the local one) to each `git config canon.mirror` remote (opt-in, never forced; prints how to undo); in canon it refuses a commit whose binaries are not released (`scripts/check-binaries-released.sh --rev`)
tkt release-check <sha>              # exit 1 when <sha> ships binaries not yet released; canon's pre-push hook (scripts/install-hooks.sh) runs it for every push to a canon.mirror remote (t-4ea4)
tkt land <id> [--pr N] [--fix]   # continue an imported cloud ticket here: a worktree at the PR head with the ticket bound to it (--fix: even when the PR head's verdict passes, for a suite that fails here); after sprint complete there, `tkt land <id> --finish` removes it (never pushes or merges)
tkt worktree-reset [--yes | --dry-run]  # in a linked worktree whose PR merged: fetch, then reset its long-lived tracking branch to origin's default branch. Refuses (one line, with the fix) in the main checkout, on the default branch, on a detached HEAD, on uncommitted or untracked files (canon's .agents/skills and .claude/skills links aside), on commits on no remote, on skip-worktree/assume-unchanged files, mid merge/rebase/cherry-pick/revert, or when the fetch fails. Prints the commits and files it drops and the new tip; stash and other worktrees are a notice (shared, untouched). Asks once (--yes skips; no terminal refuses). Never pushes, deletes a branch or removes a worktree
tkt take-back <id> [--close-issue]   # bring a ticket sent to GitHub back to this machine (clears runs: github; --close-issue also closes the issue and clears github:)
```

`tkt compact` touches only closed or cancelled tickets whose `ticket.md` is older than DAYS. It deletes the raw
board-spec JSON reports (`evidence/**/board-spec-*-run*.json`) and packs every other evidence file into
`evidence.tgz`, removing the loose files only after the archive lists them all. A file cited by path stays loose: in the
ticket's own docs, in an open or in-progress ticket's docs, or in a tracked repo file. Symlinks are never followed.
Restore one ticket with `tar -xzf .tickets/<id>/evidence.tgz -C .tickets/<id>`.

After `tkt learn <id>` writes a candidate, the `learnings-sweep` skill (not a `tkt` subcommand —
see `skills/learnings-sweep/SKILL.md`) upserts one row into root `LEARNINGS.md`, an always-current
index across tickets. The sprint close protocol has the agent run it in single-ticket mode (the
`sprint complete` CLI does not call it); run the skill in its `--full` mode by hand to backfill or
reconcile the whole repo.

## Machine-readable output

`--json` is on `tkt ls`, `tkt show` and `sprint status`. Pure bash and awk, no `jq` or Python. Text output is unchanged without the flag. On an error (unknown or ambiguous id) stdout stays empty and the message goes to stderr, exit 1.

| Command | Output |
|---|---|
| `tkt ls [--status=X] --json` | array of `{"id","status","type","priority","title"}`; `priority` is a number (`null` if the ticket has none); `[]` when none match |
| `tkt show <id> --json` | `{"id","status","type","priority","created","title","body","eval_override","eval_fail_count","demo"}`; `body` is the text below the title line without its leading blank line; as in text mode, every later line is kept, `# ` and `---` lines included; `eval_override` and `demo` are booleans, `eval_fail_count` a number, defaulting to `false`/`0` when the frontmatter line is absent |
| `sprint status --json` | `{"active":true,"ticket":<tkt show --json>,"files":{"ticket.md":bool,"acceptance.md":bool,"plan.md":bool}}`; with no active sprint `{"active":false}` and exit 1 |

Strings are JSON-escaped (`"`, `\`, and control characters as `\n`, `\t`, `\r`, `\b`, `\f` or `\u00XX`); UTF-8 passes through. `canon sessions --json` covers live sessions.

## Sprint Artifacts

Core sprint-ticket artifacts (see `standards/ticket-layout.md` for the authoritative full field contract and doc lifecycle):

| File | Written by | Purpose |
|---|---|---|
| `ticket.md` | `sprint start` / `tkt` | Frontmatter + description |
| `acceptance.md` | agent at sprint start | Done criteria + test plan + QA |
| `plan.md` | agent at sprint start | Approach + decisions |
| `research.md` | agent at sprint start | Objective truth: relevant files, system model, constraints |
| `review-notes.md` | agent at sprint complete (normal+) | Advisory reviewer findings + verdict |
| `eval-report.md` | agent at sprint complete (non-trivial: normal, high-risk, bugfix) | Adversarial per-criterion grades + verdict |
| `summary.md` | agent at sprint complete | Plan-vs-actual table + close prose |

`summary.md` appears as a **Summary** tab on the board — read-only once the
ticket is closed. It is the permanent record of what was delivered versus what
was planned.

## Closing Sprint Work

Use `sprint complete` for sprint work. It validates required sprint files and
acceptance checkboxes before closing the active ticket.

`tkt close <id>` on its own refuses to close: it directs you to `sprint complete`
if the ticket has sprint docs, or to `sprint start`/`--no-sprint` if it doesn't.
Genuinely doc-less/backlog tickets, or a sprint being deliberately abandoned
without completing it, close via the explicit `tkt close <id> --no-sprint`.

## Agent Workflow

- Before starting work: run `tkt ls` to understand open tasks.
- **When picking up a task: run `tkt start <id>` before writing any code.** This records `.tickets/ACTIVE` so agents agree on the current task, and (`tools/work-beat`) `.tickets/ACTIVE.beat`, the heartbeat that makes the board show Working instead of Resume while an agent is on it.
- Include the ticket ID in every commit body (e.g. `Closes: t-8ms5`) per `standards/efficiency.md`'s Git conventions — type-prefixed subject, not a bare ticket-ID prefix.
- **Do not run `tkt close <id>` for sprint work.** Use `sprint complete` so
  validation runs consistently.
- Don't create tickets for trivial 1-line fixes. Use judgment.
- Prefer updating an existing ticket over creating a duplicate.

## Notes

- Ticket IDs appear in git log via the commit body's `Closes: t-xxxx` line.
- Priority: 0 = highest, 4 = lowest. Default is 2.
- `tkt` is bundled with canon in `tools/tkt` — no external install needed.
- Legacy flat `.tickets/<id>.md` tickets are kept readable for compatibility with older canon projects and simple external tooling. New canon tickets use `.tickets/<id>/ticket.md`.
