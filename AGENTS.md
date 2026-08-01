# canon: Agent Instructions

Universal instructions for AI coding agents. Loaded natively by Claude Code, Pi, and Codex CLI.

## Approach

- Non-trivial work requires an open ticket before `sprint start`. Trivial fixes (typo, single-line config) are exempt. Adding a new file, wiring into test or build infrastructure, modifying a hook, pipeline, or post-commit script, or touching more than one file with coordinated intent is **normal tier** — eval is mandatory. A `bugfix` tier (a single logic file plus its covering test) sits between trivial and normal: it is **eval-only** — keeps the binding evaluator but drops the advisory reviewer + heavy wrapup — and is a complete-time downgrade decided from the diff, never planned. See `skills/sprint/SKILL.md`'s Workflow tiers.
- Think before coding. Surface tradeoffs, don't hide confusion.
- Minimum code that solves the problem. Nothing speculative.
- Touch only what you must. Clean up only your own mess.
- When dispatching a research/reporting-only subagent that has full tool access (e.g. `general-purpose`), explicitly instruct it not to edit or write any file. Default tool access includes Edit/Write — omitting this instruction risks unauthorized side effects on files it was only meant to read.
- Define success criteria before starting. Verify when done.
- If multiple interpretations exist, present them — don't pick silently.
- Never end a turn after only stating what you are about to do; if a sentence describes a next action, perform it in the same turn.
- Be concise in output, thorough in reasoning.
- Test before declaring done.

## Standards

See `standards/efficiency.md` for the full agent standards (code quality, security, git conventions, token efficiency).

<!-- MODEL-TIERS:BEGIN -->
## Model Tiers

Match model to the sprint work being done. `plan creation` and `grill` usually run inline
in the main session rather than as separate dispatches — the tier below still applies to
whichever session/dispatch does that work.

- `explore` → Haiku — read-only, bounded search/mapping, no judgment calls.
- `plan creation` → Fable or Opus — needs design judgment before scope locks in.
- `implement` → Haiku/Sonnet — execution inside an approved plan. Without `advisor`
  configured on Sonnet+Opus, bump to Opus for high-risk sprints instead.
- `review` / `grill` → Opus — adversarial, judgment-heavy; a weaker model would rubber-stamp.

**Exception — sprint close gates** follow their own rule (may downgrade to Haiku on a
structural low-risk check, or an explicit user `Gate model:` override) — see the
"Model tier for gates" note in `skills/sprint/reference/complete.md`, not this block.

**Cross-harness note.** Fresh-context dispatch is confirmed working under Codex
(`spawn_agent`/`wait_agent`/`close_agent`), but per-agent model selection is not — Codex's
`spawn_agent` has no `model` field, and its model picker is session-level. Don't assume the
Haiku-downgrade above works under Codex without testing live first.

**North-star exception — `demo` mode.** canon's governing invariant is *only structural risk
may reduce close gates, and a sprint never drops below the binding evaluator* (`DECISIONS.md`
2026-07-25). `demo: true` is the **one documented exception to the first clause**: it reduces
the close to `security-review` + the binding evaluator (the **evaluator** forced to Haiku;
`security-review` runs inline on the session model), skipping the advisory reviewer + rest of
wrapup — driven by an explicit **user flag rather than structural risk**.
Justified as the same class of explicit, human-set, auditable override as `eval_override` /
`Gate model:`, and paid for by being loud (Demo-mode markers on the Wrapup Gates rows + a
`summary.md` demo line). It **honors the second clause unconditionally** — the evaluator always
runs. See `skills/sprint/reference/complete.md`'s "Demo mode" step and the 2026-07-30
north-star-amendment entry in `DECISIONS.md`.
<!-- MODEL-TIERS:END -->

<!-- AI-SKILLS:BEGIN -->
## Active canon skills
> Managed by `skills.sh` — use `add`/`remove` to change.

| Skill | Category | Source |
|-------|----------|--------|
| sprint | dev | /Users/sunitjoshi/Developer/canon/skills/sprint/SKILL.md |
| mikado | dev | /Users/sunitjoshi/Developer/canon/skills/mikado/SKILL.md |
<!-- AI-SKILLS:END -->
