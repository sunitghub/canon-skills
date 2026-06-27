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

Standards (`standards/efficiency.md`, etc.) are injected via `@`-imports in `AGENTS.md`. Same live-reference model.

## Tiered Planning

Simple work stays light. canon chooses the lightest tier that still protects the work:

| Tier | When | What runs |
|---|---|---|
| **Trivial** | Single line, question, mechanical change | Work directly |
| **Normal** | Focused, reversible change | ticket + acceptance + plan → build → wrapup + eval |
| **High-risk** | Security, irreversible ops, broad blast radius | Full pipeline: orient (parallel) + grill + impact analysis + required mitigation tests |

## Generator-Evaluator Separation

The agent that wrote the code is the worst possible reviewer of that code. canon enforces separation structurally:

1. `sprint complete` spawns a **fresh subagent** — Read and Bash only, no implementation history — to grade each acceptance criterion against the actual code.
2. The evaluator writes a machine-generated `evaluator-run-id` before grading; a `SubagentStop` hook logs the real `agent_id` to `.claude/subagent-runs.jsonl`, making the field auditable.
3. The CLI blocks close if the field is absent, the verdict is `fail`, or any acceptance box is unchecked.

Same-context review reintroduces self-evaluation bias. The protocol fails closed when fresh-context evaluation is unavailable.

## Session Continuity

`HANDOFF.md`, the active ticket, and recent closed tickets are injected at session start via hooks. A context reset or fresh session never loses the thread — the plan, decisions, and acceptance bar are in `.tickets/<id>/`, not the chat history.

## The Close Path

```
sprint complete
  └── Wrapup: simplify → review → security → repo-check → doc-audit
  └── Reviewer (fresh subagent, normal+ tier)
  └── Evaluator (fresh subagent, normal+ tier) — adversarial, blocks on fail
  └── Acceptance check — CLI blocks on unchecked items
  └── summary.md — plan-vs-actual table, one row per criterion
  └── tkt close
```

Gates don't make agents smarter. They make certain failures impossible — and turn the ones that remain into data.
