---
name: complete-checklist
description: One-page sprint-close checklist for a normal or high-risk Claude Code sprint; points to complete.md for other cases
category: dev
tags: [workflow, close, gates, sprint]
hidden: true
---

# Sprint Complete — checklist

**First** ask "Ready to close sprint `<id>`? This will run wrapup and move the ticket to Done.
Confirm to proceed." A broad "continue"/"finish" is not approval.

## Steps

1. **Wrapup** (`skills/wrapup/SKILL.md`): code-simplifier, code-reviewer (inline), doc-audit (`tools/doc-check` first), docs.
   - **Pre-gate:** `sprint pre-gate-check <id>` first; non-zero: stop.
   - **Skill eval** if `tools/skill-eval-scope.sh` lists a changed skill or gate agent: per `run <skill>`
     follow `skills/skill-eval/SKILL.md`; advisory, batched in step 2.
   - **Interim commit** (specific paths) before any gate.
   - `## Wrapup Gates` in `acceptance.md`: a row per gate (`ran`/`skipped` + evidence; inline gates: `sprint wrapup-row <id> <gate> ran|skipped "<evidence>"`, which the progress card reads); `reviewer` and
     `code-reviewer` are separate.
   - Push `origin/main` after the gates.
2. **Reviewer** (advisory). `sprint gate-snapshot pre .tickets/<id>/gate-snapshot.txt --role reviewer`;
   `Agent` with `subagent_type: "canon-reviewer"`, batched with break-it, skill-eval executors; after all (before any fix or commit): `sprint gate-snapshot post …` (differs: stop,
   show PRE hash), `sprint subagent-log --agent-id reviewer-<id> --agent-type reviewer` + cost flags, `--model` (complete.md),
   `sprint check-review-notes <id>` (`shape refused`: re-dispatch). Row: `verdict: YES|NO — …
   (model: <m> — <source>)`. A NO is surfaced, not blocking.
3. **Evaluator** (binding). First `security-review` (inline) on the final diff; commit its fixes. Then,
   after all fixes (never edit a tracked file while a stamp runs), once:
   - **Mutation sweep** (logic files): `skills/mutation-test/SKILL.md`
     (`mutant-sweep --check` first), triage survivors; then
     `sprint evidence stamp <id> mutant-sweep -- mutant-sweep …`. Non-binding; not skippable without a reason: `mutation-test | skipped | <reason>`.
   - **Evidence:** in a clone of the final commit run
     `CANON_TICKETS_DIR=<project>/.tickets sprint evidence stamp <id> test-sh -- <project test command>`
     (canon: `scripts/test.sh`; `--only <suite>` per complete.md).
   `mutation-test` row filled; `sprint check-evidence <id>` ok (`[manual]`: `sprint manual-qa`); `eval_fail_count` below 3; snapshot
   pre (`--role evaluator`); `Agent` with `subagent_type: "canon-evaluator"`; post (before fix commits):
   - Line 1 `evaluator-run-id: <epoch>-<n>`: run `sprint run-id`; skew over 300 s → discard, re-dispatch.
   - `sprint subagent-log --agent-id <run-id> --agent-type evaluator` + cost flags, `--model`, then `sprint eval-verdict <id>`.
   - `fail`, `partial` or `not-run`: surface it, stop. A tracked change after grading needs a fresh
     evaluator (`graded-head:`), except the late docs (`.tickets/`, LEARNINGS, DECISIONS, HANDOFF).
   - Row: `verdict: pass — … (model: <m> — <source>; <N>m)`.
   - `sprint second-eval <id>` names a model: complete.md "Second evaluator".
4. **Tests:** a Test Plan line per criterion; each ✓ with dated evidence. Re-run a claimed "pre-existing failure" in the real tree.
5. **Acceptance:** every criterion and QA "Tested locally" box met.
6. **DECISIONS.md:** one row (rule, falsifier, id); `sprint decisions related|archive|mark` routes the rest.
7. **Conventions:** propose a convention line; ask first.
8. **Summary:** `.tickets/<id>/summary.md`, one row per criterion (`delivered`/`waived`/`deferred`/`partial`;
   escape `|`), plus a paragraph naming gate models, any reviewer NO. `tkt learn <id>`;
   if it writes a file, `/learnings-sweep <id>`. Route each Noticed bullet: ticket `[t-xxxx]` or `[dismissed: why]`.
9. **Close:** `sprint complete <id>`, never a hand-edited status. Refused: report, stop.
10. **Commit & push:** stage specific files plus DECISIONS/HANDOFF/LEARNINGS unless gitignored; `Closes: <id>` in the body; show; ask. "No remote is configured: committed locally, nothing pushed" if none; "pushed" only after a push that succeeded. Worktree: no PR;
    **Check & merge**, then `tkt worktree-reset`. Canon: `public` only via `tkt push-main`; a push is not a release.

## Gate dispatch inputs

- **Prompt and model:** `sprint gate-prompt <id> <reviewer|evaluator|evaluator2>` prints the whole prompt (protocol, `Model:`
  line, report path or Copilot's write-no-file rule, the evaluator's check-evidence output); stderr names the `model` to pass
  (none: omit it). Pass the prompt verbatim; add no report shape, verdict line, run-id or changed-files list of your own.
- `Plan` fallback, Copilot gates: `sprint relay-report <id> [reviewer]` writes the report (it takes no input);
  session never types one. Copilot's `task` call needs `name`.

## Read the detail when

| Case | Read in `complete.md` |
|---|---|
| `Tier: bugfix` or `Tier: trivial` in Sign-off | step 1 "Bugfix tier — lighter wrapup"; step 2 "Bugfix downgrade" |
| `demo: true`, or the `skills:` maintenance-skill guard | step 1 "Demo mode"; "Maintenance-skill report-only guard" |
| `Gate model: openai:<id>`, Copilot CLI, Codex or pi | "Gate dispatch mechanics" |
| no git, or no commit yet | step 1 "Folder without git"; mechanics rule 7 |
| gate wrote outside its report, or snapshot post differs | mechanics rule 7 |
| a subagent could not write its report | mechanics rule 6 |
| evaluator `fail`, retry budget at 3, or `eval_override` | step 3 "Retry budget", `fail` paragraph |
| close refuses the report (transcript, stale-eval guard) | step 3 "Stale-eval guard", "backed by a real transcript" |
| high-risk or untrusted-input sprint (break-it) | step 3 "Break-it" |
| scenario-backed Test Plan lines | step 4 |
| a waived, deferred or partial item, or the learnings cap | step 8 |
| `manual: true` | step 1 "Manual mode" |
| a release | step 10 "Releases" |
| a land worktree | step 6 "Land worktree" |
