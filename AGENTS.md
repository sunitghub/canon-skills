# canon: Agent Instructions

Universal instructions for AI coding agents. Loaded natively by Claude Code, Pi, and Codex CLI.

## Approach

- Non-trivial work requires an open ticket before `sprint start`. Trivial fixes (typo, single-line config) are exempt. Adding a new file, wiring into test or build infrastructure, modifying a hook, pipeline, or post-commit script, or touching more than one file with coordinated intent is **normal tier** — eval is mandatory. A `bugfix` tier (a single logic file plus its covering test) sits between trivial and normal: it is **eval-only** — keeps the binding evaluator but drops the advisory reviewer + heavy wrapup — and is a complete-time downgrade decided from the diff, never planned. See `skills/sprint/SKILL.md`'s Workflow tiers.
- Think before coding. Surface tradeoffs, don't hide confusion.
- Minimum code that solves the problem. Nothing speculative.
- Touch only what you must. Clean up only your own mess.
- When dispatching a research/reporting-only subagent that has full tool access (e.g. `general-purpose`), explicitly instruct it not to edit or write any file. Default tool access includes Edit/Write — omitting this instruction risks unauthorized side effects on files it was only meant to read.
- Subagent dispatches should return a structured report, not raw tool noise. Use `skills/sprint/reference/subagent-report.md` as the return-shape contract: Result, Output, Evidence, Learnings. Preserve context hygiene — snapshot the active working branch only, do not transform parent context into text, and exclude sibling/abandoned branches.
- Define success criteria before starting. Verify when done.
- If multiple interpretations exist, present them — don't pick silently.
- Never end a turn after only stating what you are about to do; if a sentence describes a next action, perform it in the same turn. **Exception:** canon's defined approval checkpoints — `sprint start`'s "wait for explicit approval" (before code) and `sprint complete`'s "wait for confirmation" (before close) — are deliberate stops; pausing for the user there is required, not a stall.
- Be concise in output, thorough in reasoning.
- Test before declaring done.

## Standards

See `standards/efficiency.md` for the full agent standards (code quality, security, git conventions, token efficiency).

<!-- MODEL-TIERS:BEGIN -->
## Model Tiers

Match model to the sprint work being done. `plan creation` and `grill` usually run inline
in the main session rather than as separate dispatches — the tier below still applies to
whichever session/dispatch does that work.

- `explore` → Haiku, thinking `minimal` — read-only, bounded search/mapping, no judgment calls.
- `plan creation` → Fable or Opus, thinking `medium`/`high` — needs design judgment before scope locks in.
- `implement` → Haiku/Sonnet, thinking `medium` — execution inside an approved plan. Without `advisor`
  configured on Sonnet+Opus, bump to Opus for high-risk sprints instead.
- `review` / `grill` → Opus, thinking `high` — adversarial, judgment-heavy; a weaker model would rubber-stamp.

**Exception — sprint close gates** follow their own rule (may downgrade to Haiku on a
structural low-risk check, on a `demo: true` ticket (evaluator only), or via an explicit user
`Gate model:` override) — see the
"Model tier for gates" note in `skills/sprint/reference/complete.md`, not this block.

**Cross-harness note.** Fresh-context dispatch is confirmed working under Codex
(`spawn_agent`/`wait_agent`/`close_agent`), but per-agent model selection is not — Codex's
`spawn_agent` has no `model` field, and its model picker is session-level. Don't assume the
Haiku-downgrade above works under Codex without testing live first.

**North-star (gate floor).** Only structural risk may reduce close gates, and a sprint never drops below the binding evaluator. The one documented exception is a user-set `demo: true` light-close (the evaluator still runs). The full policy — demo mode, the model tier for gates, and the north-star amendments — lives in `skills/sprint/reference/complete.md` (see also `DECISIONS.md` 2026-07-25 / 07-30 / 08-02).
<!-- MODEL-TIERS:END -->

<!-- AI-SKILLS:BEGIN -->
## Active canon skills
> Managed by `skills.sh` — use `add`/`remove` to change.

| Skill | Category | Source |
|-------|----------|--------|
| sprint | dev | /Users/sunitjoshi/Developer/canon/skills/sprint/SKILL.md |
<!-- AI-SKILLS:END -->
