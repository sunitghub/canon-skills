# How canon Works

canon's whole design follows from one idea: **your agent forgets between sessions; your repo shouldn't.** Everything below is a consequence of taking that seriously.

## Live references, not copies

Your standards, skills, and workflow live in one place — the canon checkout — and your projects point at it with `@`-imports instead of copying it in. Update canon once and every project picks up the change on its next session: no per-project copies, no drift, no re-setup ritual. The same imports load natively in Claude Code, Codex, and Pi, so a single definition keeps every agent in sync.

## The CLI owns state; the agent owns judgment

canon splits the work along a hard line:

- **The CLI is a deterministic state machine.** It enforces what shouldn't depend on a model's mood — one active sprint at a time, and a `sprint complete` that refuses to close while any acceptance or test-plan box is still unchecked. These are checks in code, not judgment calls.
- **The agent supplies the judgment.** Orientation, resolving gray areas, rating impact, verifying that tests actually pass, deciding a criterion is truly met — the parts that need reasoning.

The gate checks the boxes; the agent is trusted to check a box only when the work behind it holds. Determinism where correctness is mechanical, judgment where it isn't — and neither pretends to be the other.

## Planning scales to the risk

A one-line rename and a payment-writing endpoint shouldn't carry the same ceremony, so `sprint start` first classifies the work and the agent takes the lightest tier that still protects it:

- **Trivial** changes skip the sprint entirely.
- **Normal** changes get a ticket, acceptance criteria, and a brief plan.
- **High-risk** changes earn more — subsystem mapping, gray-area resolution, a five-dimension impact rating, any required human checkpoint, and mitigation tests the close gate then enforces.

Overhead shows up only where the risk justifies it, so the process stays proportional instead of uniform.

## Local-first state

A ticket is a folder in your repo (`.tickets/<id>/`), not a card in someone's cloud. Each sprint has two docs: `acceptance.md` for done criteria and tests, and `plan.md` for approach and decisions. Durable choices can land in `DECISIONS.md`; cross-session context lives in `HANDOFF.md`. All of it is markdown on disk, with no account, no remote, and no SaaS.

Because the state is just files, it survives context resets and fresh sessions: the agent re-reads the ticket folder and `HANDOFF.md` and resumes where it left off, and `sprint-check` renders those same files as a local board. Projects can choose whether to track that local workflow state in git; canon itself keeps `.tickets/`, `HANDOFF.md`, and `DECISIONS.md` ignored so release docs stay separate from working state.

## Why this shape

Three constraints, held together:

- **Minimal** — two commands and a board, not a methodology to learn.
- **Durable** — the work outlives any single session because it lives in your repo.
- **Portable** — one definition, every agent, no lock-in.

Every choice above trades cleverness for one of those three. That's canon.
