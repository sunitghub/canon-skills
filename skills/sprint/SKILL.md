---
name: sprint
description: Manages the sprint workflow for focused changes. Use when asked to add, fix, update, implement, debug, or build — see the Workflow tiers section for what's out of scope.
category: dev
tags: [workflow, planning, quality, tickets, orchestration]
depends: []
---

# Sprint

CLI-backed commands:

| Command | When |
|---|---|
| `sprint start` | Any normal or high-risk dev request |
| `sprint complete` | When you believe the work is done |

The `sprint` CLI owns deterministic workflow state: ticket creation, active
ticket tracking, context file creation, and close validation. The agent owns
sprint doc creation, orientation, gray-area resolution, impact analysis,
implementation, review, and test judgment.

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

None of these four triggers can be downgraded to trivial mid-sprint — `complete.md`'s and `start.md`'s downgrade rule explicitly excludes them (see `skills/sprint/reference/complete.md` steps 2-3, Reviewer gate / Evaluator review).

Work directly, then report verification.

### Bugfix (eval-only)

A lighter tier between Trivial and Normal for a small, well-contained fix. It is **eval-only**:
it keeps the binding fresh-context **evaluator** and drops the *advisory* reviewer + the heavier
wrapup gates. It **never drops below the binding evaluator** — that is the whole point of the trim.

Eligibility is **structural**, decided at close from the actual diff (not planned scope), and
requires **all** of:
- the change is a single logic file **plus its covering test** (no wider surface);
- a covering test exists that asserts an **independent** invariant (not a re-derivation of the
  code — see `reference/root-why.md`);
- **none** of the four categorical not-trivial triggers is present (new file beyond the test,
  test/build-infrastructure wiring, hook/pipeline/post-commit change, or coordinated multi-file
  intent). If any is present, the sprint stays Normal.

Bugfix is a *complete-time downgrade* (mirrors the trivial valve): planning runs as Normal; at
close, if the diff qualifies, write `Tier: bugfix` in `plan.md`'s `## Sign-off`. Because bugfix is
non-trivial, the CLI still requires the eval-report, sign-off, and acceptance gates — only the
advisory reviewer and heavy wrapup are skipped (`complete.md` steps 1-2). It is strictly safer
than the trivial tier, which skips the evaluator too.

`sprint suggest-tier` surfaces this eligibility mechanically — it reads the diff (never plan prose)
and *proposes* `bugfix` or `normal`; it never writes `Tier:` or auto-downgrades. It checks only the
structural shape (single logic file + covering test, none of the four triggers); whether the test
asserts an *independent* invariant stays a judgment for the binding evaluator.

Pairs naturally with a `type: bug` job (see Job types below): `root-why` produces the independent
invariant, and the covering test that asserts it is exactly the bugfix-tier eligibility precondition.

### Normal

Default for focused, reversible product/docs/code changes that affect a small surface.

Run `sprint start`, create `acceptance.md` and `plan.md`, then build after approval. Keep plan.md brief: files, approach, known constraints. Test plan goes in `acceptance.md ## Test Plan`, not plan.md.

Skip full orient, grill, and impact-analysis unless the local code is unclear or a high-risk trigger appears.

### High-risk

Use the full planning pipeline when any condition applies:
- Security-sensitive behavior changes: auth, authorization, secrets, sessions, crypto, external input, file writes, API endpoints
- Irreversible or hard-to-reverse operations: deletes, sends, payments, migrations, data rewrites, publishes, deploys
- Broad audience or shared-state blast radius
- Multiple UI/API/job trigger paths reach the same behavior
- Downstream consumers react to the changed data or event
- The implementation has genuine gray areas that would materially change the design

High-risk sprints run orient, grill, impact-analysis, required mitigation tests, and wrapup.

### Demo / Docs / UX (light close)

**Orthogonal to the risk tiers above** — a user-elected close modifier, not a fifth risk level.
Set by the `tkt`-owned frontmatter flag `demo: true` on the ticket (absent = false), so it can
ride on top of a normal or high-risk sprint. It is **not** chosen at `sprint start`; it is set on
the ticket (Phase B: hand-set `demo: true`; Phase A adds `tkt demo`/board surfaces — the
New-Ticket **Demo/Docs/UX** option and Plan-tab toggle).

One light-close covers **two intents**, both explicit and user-elected:
- **Live demo** (20–30 min time-box) — trim the close so a demo isn't gated on full wrapup.
- **Docs / research / UX work** — a sprint whose entire surface is `.md`/`.pen` (+ exported
  visuals): research write-ups, feature docs, UX/screen mockups, wireframes. There is no code
  to code-review or simplify, so the heavy wrapup + advisory reviewer add little; the binding
  evaluator still earns its keep by grading the doc/mockup against its own acceptance criteria
  (research questions answered with cites; required screens present, embedded, and fresh).

For either intent, `sprint complete` runs a **fast close-path**: keep exactly
**`security-review` + the binding evaluator**, and skip the advisory reviewer plus
the rest of wrapup — a **superset** of what `bugfix` trims, additionally dropping
`code-reviewer` and `repo-check` (which `bugfix` keeps). The **evaluator
is forced to Haiku** (`security-review` runs inline on the session model — only the dispatched
evaluator takes a `model:` param; see `reference/complete.md`'s Model-tier section). It is a
user-elected `bugfix`-lite and **never drops below the binding evaluator** — so it never needs,
and must never set, `eval_override`.

**Keyword recognition at `sprint start`.** When a request reads as docs/research/UX work —
signals like *study, research, docs, documentation, UX, mockup, screen mockup, wireframe,
design* — propose the light-close (offer to set `tkt demo <id> on`) rather than a full close,
and say why. It stays user-elected: propose, don't auto-apply. A request that also touches code
is a normal/high-risk sprint, not a light-close, regardless of keywords.

Unlike `bugfix`/`trivial` (structural, decided from the diff), this reduction is driven by an
explicit **user flag, not structural risk** — the one documented place canon bends its
"only structural risk may reduce gates" invariant, justified as the same explicit/auditable
override class as `eval_override` / `Gate model:` and paid for by being loud (Demo/Docs markers on
the Wrapup Gates rows + a `summary.md` demo line). See `reference/complete.md`'s "Demo mode"
(step 1) for the full close-path and `AGENTS.md`'s north-star exception. Headless/CI never reduces
the gate set for `demo`: `sprint-headless` ignores `demo` entirely, and `sprint-headless-eval` runs
its full (eval-only) gate set but reads `demo: true` (ticket-id mode) to default the evaluator to
Haiku when no `--model` is given — a model choice, never a skipped gate.

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

Read `skills/sprint/reference/start.md` for the full protocol (steps 1-11).

## sprint complete

Read `skills/sprint/reference/complete.md` for the full protocol (trigger, confirmation, steps 1-10).

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
  mutation-report.md ← optional advisory; written by the mutation-test skill at sprint complete when logic files changed; never close-gated
  learnings.md     ← optional UNPROMOTED lessons candidate; written by `tkt learn` from this sprint's deviations + evaluator findings, for a non-builder to promote; never close-gated
  summary.md       ← plan-vs-actual table; written at sprint complete
```

## DECISIONS.md

Repo root. Records durable choices future sprints must respect. Not a session log. Write non-obvious choices only. Skip decisions obvious from code.
