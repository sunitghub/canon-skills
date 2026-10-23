---
name: complete-checklist
description: One-page sprint-close checklist for a normal or high-risk Claude Code sprint; points to complete.md for other cases
category: dev
tags: [workflow, close, gates, sprint]
hidden: true
---

# Sprint Complete — checklist

The normal path; every tool named is on PATH. For a case in the last list, read only that section of
`complete.md`.

**First** ask "Ready to close sprint `<id>`? This will run wrapup and move the ticket to Done.
Confirm to proceed." A broad "continue"/"finish" is not close approval.

## Steps

1. **Wrapup** (`skills/wrapup/SKILL.md`): code-simplifier, code-reviewer (inline), security-review,
   doc-audit (`tools/doc-check` first), then refresh docs.
   - **Mutation sweep** (pre-evaluator) for shell, JS, Python or Go logic: `skills/mutation-test/SKILL.md`
     (`mutant-sweep --check` first), triage every survivor; after the interim commit
     `evidence.sh stamp <id> mutant-sweep -- mutant-sweep …`. Non-binding; not skippable without a reason:
     `mutation-test | skipped | <reason>`.
   - **Skill eval** if a skill or gate agent changed: `tools/skill-eval-scope.sh`; for each `run <skill>`
     follow `skills/skill-eval/SKILL.md` from this session; advisory. Commit its `history.jsonl` line.
   - **Interim commit** (specific paths, no `git add -A`) before any gate.
   - **Evidence:** in a `git clone` of the final commit, run
     `CANON_TICKETS_DIR=<project>/.tickets evidence.sh stamp <id> test-sh -- scripts/test.sh`; re-stamp after
     any tracked change.
   - `## Wrapup Gates` in `acceptance.md`: a row per gate (`ran`/`skipped` + evidence);
     `reviewer` and `code-reviewer` are separate.
   - No push to `origin/main` from first dispatch until both gates report.
2. **Reviewer** (advisory). Model check below, then `gate-snapshot.sh pre .tickets/<id>/gate-snapshot.txt --role reviewer`;
   `Agent` with `subagent_type: "canon-reviewer"`; after: `gate-snapshot.sh post …` (any difference: stop,
   show the PRE recovery hash), `subagent-log.sh --agent-id reviewer-<id> --agent-type reviewer` + cost flags, `--model` (complete.md),
   `sprint check-review-notes <id>` (`shape refused`: re-dispatch). Row: `verdict: YES|NO — …
   (model: <m> — <source>)`. A NO is surfaced, not blocking.
3. **Evaluator** (binding). `mutation-test` row filled; `sprint check-evidence <id>` ok; `eval_fail_count` below 3; snapshot
   pre (`--role evaluator`); `Agent` with `subagent_type: "canon-evaluator"`; snapshot post. Then:
   - Line 1 `evaluator-run-id: <epoch>-<n>`: run `date +%s`; skew over 300 s → discard, re-dispatch. Never
     write a run-id yourself.
   - `subagent-log.sh --agent-id <run-id> --agent-type evaluator` + cost flags, `--model`, then `sprint eval-verdict <id>`
     (also on pass).
   - `fail`, `partial` or `not-run`: surface it, stop. A tracked change after grading needs a fresh
     evaluator (`graded-head:`), except the late docs (`.tickets/`, LEARNINGS, DECISIONS, HANDOFF).
   - Row: `verdict: pass — … (model: <m> — <source>; <N>m)`.
4. **Tests:** each criterion has a Test Plan line exercising it; each item ✓ with dated evidence. Re-run any
   "pre-existing failure" the evaluator claims, in the real tree.
5. **Acceptance:** every criterion and QA "Tested locally" box truly met.
6. **DECISIONS.md:** durable choices and why; archive a superseded entry, mark a retired fragment
   `superseded-by: <date>`.
7. **Conventions:** propose a new convention line; ask first.
8. **Summary:** `.tickets/<id>/summary.md`, one row per criterion (`delivered`/`waived`/`deferred`/`partial`;
   escape `|`), plus a paragraph naming gate models, any reviewer NO. Run `tkt learn <id>`;
   if it writes a file, run `/learnings-sweep <id>`. Say which in chat and summary.
9. **Close:** `sprint complete <id>`, never a hand-edited status. On refusal, report and stop.
10. **Commit & push:** stage specific files, `Closes: <id>` in the body, show them; ask. Public: only `tkt push-main`.
    A push is not a release: `VERSION` bumps need `scripts/release.sh --dry-run` and a yes. Worktree, after the merge: `tkt worktree-reset`.

## Gate dispatch inputs

- **Model:** `Gate model:` in plan.md's Sign-off wins (`session` = your own alias). Else the Admin default:
  `$CANON_HOME/cockpit/model-tiers.json` (else `tools/sprint-check-app/model-tiers.json`)
  `defaults.eval.anthropic` → its `alias` in `models.anthropic`; pass it as `model` if it is `fable`,
  `opus`, `sonnet` or `haiku`. Else omit `model` (definition floor `claude-sonnet-5`). Record the source:
  `Gate model override`, `Admin Review & Eval default`, `definition floor`.
- **The prompt says:** ticket id, repo path and branch; read `reference/review.md` (reviewer) or
  `reference/eval.md` (evaluator) and follow it; the model designation to record as `Model:`; write
  `.tickets/<id>/review-notes.md` / `eval-report.md` and return the verdict line; read-only except
  that report; run tools only in its own `mktemp -d` with `CANON_HOME`, `HOME`, `TMPDIR`,
  `XDG_CONFIG_HOME` pinned inside it; never kill by name or pattern; evaluator only: take the
  `evaluator-run-id` as the very last command. Never pass a changed-files list.
- `Plan` fallback: `sprint relay-report <id> [reviewer]` writes its report (the main session never types one).

## Read the detail when

| Case | Read in `complete.md` |
|---|---|
| `Tier: bugfix` or `Tier: trivial` in Sign-off | step 1 "Bugfix tier — lighter wrapup"; step 2 "Bugfix downgrade" |
| `demo: true` in ticket.md (and the `skills:` Upkeep guard) | step 1 "Demo mode"; "Upkeep report-only guard" |
| `Gate model: openai:<id>`, Copilot CLI, Codex or pi | "Gate dispatch mechanics": its `openai`, Copilot, Codex and pi bullets |
| no git, or no commit yet | step 1 "Folder without git"; mechanics rule 7 |
| a gate wrote outside its report, or snapshot post differs | mechanics rule 7 |
| a subagent could not write its report | mechanics rule 6 |
| evaluator `fail`, retry budget at 3, or `eval_override` | step 3 "Retry budget" and the `fail` paragraph |
| the close refuses the report (transcript or stale-eval guard) | step 3 "Stale-eval guard", "backed by a real transcript" |
| high-risk or untrusted-input sprint (break-it) | step 3 "Break-it" |
| scenario-backed Test Plan lines | step 4 |
| a waived, deferred or partial item, or the learnings cap | step 8 |
| a release | step 10 "Releases" |
