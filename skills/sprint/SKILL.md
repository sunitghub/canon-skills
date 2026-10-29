---
name: sprint
description: Manages the sprint workflow for focused changes. Use when asked to add, fix, update, implement, debug, or build — see the Workflow tiers section for what's out of scope.
category: dev
tags: [workflow, planning, quality, tickets, orchestration]
depends: [wrapup, learnings-sweep, promote-learnings]
---

# Sprint

CLI-backed commands:

| Command | When |
|---|---|
| `sprint start` | Any normal or high-risk dev request |
| `sprint continue <id>` | Resume an in_progress ticket (the cockpit sends it when no conversation can be resumed) |
| `sprint complete` | When you believe the work is done |

The `sprint` CLI owns deterministic workflow state: ticket creation, active
ticket tracking, context file creation, and close validation. The agent owns
sprint doc creation, orientation, gray-area resolution, impact analysis,
implementation, review, and test judgment.

**Gate reports are never hand-written.** `review-notes.md` and `eval-report.md` are written only by the fresh
reviewer and evaluator subagents that `sprint complete` calls for (`reference/complete.md` steps 2-3). If the CLI says
one is missing or fails to verify it, dispatch that gate — do not create or edit the file yourself.

Every `Read skills/...` reference in this file and its `reference/*.md` docs is a plain relative
path inside canon's own repo. In a consumer project, resolve via `.claude/skills/...` (Claude
Code) or `.agents/skills/...` (Codex/Pi) instead — canon's install symlinks into its real
`skills/` tree.

## Workflow tiers

Choose the lightest tier that still protects the work.

### Trivial

Use no sprint when:
- The request is a question or explanation
- The change is a single line or trivially mechanical (e.g. rename, typo fix, config tweak)
- The user explicitly says to skip it ("just fix it", "quick change")

**Not trivial** — use normal tier when the change:
- Adds a new file (test, script, config, doc)
- Wires into test or build infrastructure
- Modifies a hook, pipeline, or post-commit script
- Touches more than one file with coordinated intent

These four triggers can never downgrade to trivial mid-sprint — `complete.md`'s/`start.md`'s downgrade rule excludes them (`skills/sprint/reference/complete.md` steps 2-3, Reviewer gate / Evaluator review).

Work directly, then report verification.

### Bugfix (eval-only)

A close-time downgrade for a small fix: it keeps the binding fresh-context evaluator and skips the
advisory reviewer and heavy wrapup, so it **never drops below the binding evaluator**. Planning runs as
Normal; at close `sprint suggest-tier` reads the diff and proposes `bugfix` only for one logic file plus
its covering test with none of the four not-trivial triggers above (a new file beyond the test is one). The
evaluator judges whether that test asserts an independent invariant (`reference/root-why.md`). Then write
`Tier: bugfix` in `plan.md`'s `## Sign-off` (`complete.md` steps 1-2); the CLI still requires the eval-report,
sign-off and acceptance gates.

### Normal

Default for focused, reversible product/docs/code changes on a small surface.

Run `sprint start`, create `acceptance.md`/`plan.md`, build after approval. Keep plan.md brief: files, approach, known constraints. Test plan goes in `acceptance.md ## Test Plan`, not plan.md.

Skip full orient/grill/impact-analysis unless the local code is unclear or a high-risk trigger appears.

### High-risk

Use the full planning pipeline when any condition applies:
- Security-sensitive behavior changes: auth, authorization, secrets, sessions, crypto, external input, file writes, API endpoints
- Irreversible or hard-to-reverse operations: deletes, sends, payments, migrations, data rewrites, publishes, deploys
- Broad audience or shared-state blast radius
- Multiple UI/API/job trigger paths reach the same behavior
- Downstream consumers react to the changed data or event
- The implementation has genuine gray areas that would materially change the design

High-risk sprints run orient, grill, impact-analysis, required mitigation tests, and wrapup.

### Lite (light close)

**Orthogonal to the risk tiers above** — a user-elected close modifier, not a fifth risk level.
Set by `demo: true` in ticket frontmatter (`tkt demo <id> on`, or the board's **Lite** option); it rides
on top of a normal or high-risk sprint and is never chosen at `sprint start`.

One light-close covers **two intents**, both explicit and user-elected:
- **Live demo** (20–30 min time-box) — trim the close so a demo isn't gated on full wrapup.
- **Docs / research / UX work** — a sprint whose entire surface is `.md`/`.pen` (+ exported
  visuals): research write-ups, feature docs, UX/screen mockups, wireframes. There is no code
  to code-review or simplify, so the heavy wrapup + advisory reviewer add little; the binding
  evaluator still earns its keep by grading the doc/mockup against its own acceptance criteria
  (research questions answered with cites; required screens present, embedded, and fresh).

For either intent, `sprint complete` runs a **fast close-path**:
**keep exactly `security-review` + the binding evaluator, skip the advisory reviewer + the rest of wrapup — a superset of what `bugfix` trims, additionally dropping `code-reviewer` (which `bugfix` keeps).**
**The evaluator is forced to Haiku
(`security-review` runs inline on the session model)** — only the dispatched evaluator takes a
`model:` param; see `reference/complete.md`'s Model-tier section. It is a
user-elected `bugfix`-lite and **never drops below the binding evaluator** — so it never needs,
and must never set, `eval_override`.

It is the one gate reduction set by a user flag rather than the diff, so it is loud (Lite markers on the
Wrapup Gates rows, a `summary.md` demo line). Docs/research/UX requests (study, research, docs, mockup,
wireframe) get the light close **proposed** with a reason (`tkt demo <id> on`), never auto-applied; a
request that also touches code is a normal/high-risk sprint. The close-path is `reference/complete.md`'s "Demo mode" (step 1).
**Headless/CI never reduces the gate set for `demo`: `sprint-headless` runs its full pipeline and ignores `demo` entirely; `sprint-headless-eval` (already eval-only) also runs its full gate set but reads `demo: true` to default the evaluator to Haiku when no `--model` is given — a model choice, never a skipped gate.**
(ticket-id mode; explicit `--model` wins.)

## Job types (JTBD)

Job type is a second dimension, **orthogonal to the risk tiers above**. The tier decides how much
planning and which gates run; the job type only adds an optional *pre-implementation planning
step* — it never changes which gates run.

| Job | Signal | Added planning step |
|---|---|---|
| Bug fix | ticket `type: bug` | **root-why** — `skills/sprint/reference/root-why.md` (5-Whys + convert the report into an independent invariant + worked example before coding) |
| Refactor | recognized job shape (restructure without behavior change) | **mikado** skill — reversible dependency graph before touching code |
| Feature / other | default | none beyond the tier's own planning |

The invariant: job type may *add* a planning step; only structural risk may *reduce* gates.

## sprint start

Read `skills/sprint/reference/start-checklist.md` first: the normal path on one page (classify the tier,
fill `acceptance.md` and `plan.md`, present the brief, then wait for explicit approval before any code). Read
`skills/sprint/reference/start.md` (the full protocol, steps 1-11) only for a case the checklist's
"Read the detail when" table names, and only that section.

## sprint complete

Read `skills/sprint/reference/complete-checklist.md` first: the normal close on one page (confirm with the
user, wrapup, fresh reviewer and evaluator subagents, summary, `sprint complete`, then ask before pushing). Read
`skills/sprint/reference/complete.md` (the full protocol, trigger, confirmation, steps 1-10) only for a
case the checklist's "Read the detail when" table names, and only that section.

## Planning files

Canonical layout:
```
.tickets/<id>/
  ticket.md        ← tkt-managed; never edit status directly — valid values: open, in_progress, closed, cancelled
  acceptance.md    ← definition of done + test plan + ## QA (Tested locally); all three sections are seeded at sprint start with an unchecked box, which blocks close if left unchecked
  plan.md          ← approach, decisions, grill/impact sections for high-risk; ## Sign-off skeleton (with an unchecked approval box) is created at sprint start, filled in and checked on approval, re-read after compaction
  research.md      ← objective truth compression, written before ## Approach; brief bullets for normal-tier, full orient protocol for high-risk/brownfield
  review-notes.md  ← advisory reviewer findings (code quality, scope, standards) + YES/NO verdict; written at sprint complete for normal+ sprints
  eval-report.md   ← adversarial per-criterion grades (pass/fail with file:line) + evaluator-run-id; written at sprint complete for non-trivial sprints (normal, high-risk, and bugfix — bugfix is eval-only, so it keeps this)
  skill-eval-<skill>.md ← optional advisory; the sprint's skill-eval report for a skill whose instructions it edited (run at sprint complete step 1, before the reviewer); never close-gated
  mutation-report.md ← non-binding pre-evaluator step; written by the mutation-test skill at sprint complete when logic files changed (a skip needs a reason); never close-gated
  learnings.md     ← optional UNPROMOTED lessons candidate; written by `tkt learn` from this sprint's deviations + evaluator and reviewer findings, for a non-builder to promote; never close-gated
  summary.md       ← plan-vs-actual table; written at sprint complete
```

## DECISIONS.md

Repo root. Records durable choices future sprints must respect. Not a session log. Write non-obvious choices only. Skip decisions obvious from code.
