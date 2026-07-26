# How canon Works

canon is a local-first agent workflow harness. No SaaS, no cloud state — everything lives in your repo.

## The CLI/Agent Split

canon separates what a CLI can do deterministically from what an agent must judge:

| Layer | Owner | Does |
|---|---|---|
| State | CLI (`sprint`, `tkt`) | Creates tickets, tracks active sprint, enforces close gates |
| Judgment | Agent | Plans work, interprets acceptance criteria, decides what passes |
| Visibility | Board (`sprint-check`) | Reads `.tickets/` and `git log`, surfaces everything locally |

Gates enforce structure; agents enforce meaning. Neither can substitute for the other.

## Live References, Not Copies

Skills are symlinked from `~/.canon/skills/` into each project's `.claude/skills/` (Claude Code) and `.agents/skills/` (Codex/Pi). Update the canon repo once — every project picks it up on the next session. No copies, no drift.

Standards (`standards/efficiency.md`, etc.) are injected via `@`-imports in `AGENTS.md`, and also listed as a row in its `AI-SKILLS` table so a table-only reader still sees them. Same live-reference model.

## Tiered Planning

Simple work stays light. canon chooses the lightest tier that still protects the work:

| Tier | When | What runs |
|---|---|---|
| **Trivial** | Single line, question, mechanical change (never a new file, test/build wiring, hook/pipeline edit, or coordinated multi-file intent) | Work directly |
| **Bugfix** | Single logic file plus its covering test, none of the not-trivial triggers — a *complete-time downgrade* decided from the actual diff | Eval-only: keeps the binding evaluator + a lighter wrapup; skips the advisory reviewer |
| **Normal** | Focused, reversible change | ticket + acceptance + plan + brief research → build → wrapup + reviewer + evaluator |
| **High-risk** | Security, irreversible ops, broad blast radius | Full pipeline: orient (parallel) + grill + impact analysis + required mitigation tests |

## Generator-Evaluator Separation

The agent that wrote the code is the worst possible reviewer of that code. canon enforces separation structurally:

1. `sprint complete` spawns a **fresh subagent** — Read and Bash only, no implementation history — to grade each acceptance criterion against the actual code.
2. The evaluator writes a machine-generated `evaluator-run-id` before grading; the orchestrating agent logs a matching entry to `.claude/subagent-runs.jsonl` via `subagent-log.sh` right after the subagent completes, and the close gate correlates the report to that run by a ±60-minute timestamp window. The run-id is a correlation handle, not a security token — the gate never validates it as `agent_id`.
3. The CLI blocks close if the field is absent, the verdict isn't `pass` (any `partial` criterion forces the verdict to `fail` — there's no separate non-blocking `partial` verdict), any acceptance or test-plan box is unchecked, `summary.md` is missing, the `## Wrapup Gates` record is absent, a referenced visual mockup was never embedded or its file never copied into the ticket's `visuals/`, or `plan.md`'s Approach or Sign-off is empty or unapproved.

Same-context review reintroduces self-evaluation bias. The protocol fails closed when fresh-context evaluation is unavailable.

## Evals vs Tests

These get conflated because both are "checks," but they sit at different layers and mean different things when they pass. The evaluator does **not** "run the tests" — tests run; the evaluator *judges*.

| | **Tests** | **Evals** |
|---|---|---|
| **Subject** | Code behaviour — given input X, does the function return Y? | Non-deterministic / agentic output — is a skill's output, or the completed work, actually correct? |
| **Runner** | Deterministic test runner (pytest, etc.), no judgment | A **fresh-context agent** with no implementation history, precisely so it can't rubber-stamp its own work |
| **What "pass" proves** | An assertion held | An independent grader re-derived the claim and agreed, with `file:line` evidence |
| **Catches** | Broken logic, regressions | What a test structurally can't: a test that can *never fail*, defensive branches nobody ran, "evidence" that quietly went stale, plausible-but-wrong output |

"Eval" covers two related things in canon:

1. **Skill evals** (`skill-eval`, cases in `skills/<name>/evals/evals.json`) — verify a *skill* produces correct output for a known set of prompts. Because the thing under test is an agent behaviour, not a pure function, they run via an **executor + grader subagent pair in fresh context** (≥3 cases: a control plus boundary / over-caution / compliance types).
2. **The evaluator gate** at `sprint complete` (`skills/sprint/reference/eval.md`) — a fresh-context adversarial agent that grades each acceptance criterion against the delivered code and writes `eval-report.md`. This is a *review gate*, not a test suite.

Both are distinct from **tests**, which are the deterministic checks that ship with the code and are exercised by a runner. The evaluator may *inspect* the tests as evidence (e.g. confirming a test can actually fail) — but grading criteria is not the same as executing a test suite.

Rule of thumb: **tests keep the code honest; evals keep the agent honest.**

## Session Continuity

`HANDOFF.md`, the active ticket, and recent closed tickets are read explicitly by `sprint start`'s context step — canon installs zero Claude Code hooks. A context reset or fresh session never loses the thread — the plan, decisions, and acceptance bar are in `.tickets/<id>/`, not the chat history.

## The Close Path

```
sprint complete
  └── Wrapup: simplify → code-review → security → repo-check → doc-audit
  └── Reviewer (fresh subagent, normal+ tier — cheaper model if changed files are structurally low-risk, or any model the user names via plan.md's Gate model: field)
  └── Evaluator (fresh subagent, normal+ tier) — adversarial, blocks on fail (same model rule)
  └── Acceptance check — CLI blocks on unchecked items
  └── summary.md — plan-vs-actual table, one row per criterion
  └── tkt close
```

The one documented way past a `fail` evaluator verdict is a human-only escape hatch: a person hand-edits `eval_override: true` in the ticket's `ticket.md` frontmatter and records a dated waiver in `acceptance.md`. No `tkt` command sets it and no agent may write it — agents must refuse even if asked — so a close override always has a human in the loop (see `standards/ticket-layout.md`; the CI equivalent is in `docs/headless-ci.md`).

Gates don't make agents smarter. They make certain failures impossible — and turn the ones that remain into data.
