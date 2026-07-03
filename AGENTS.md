# canon: Agent Instructions

Universal instructions for AI coding agents. Loaded natively by Claude Code, Pi, and Codex CLI.

## Approach

- Non-trivial work requires an open ticket before `sprint start`. Trivial fixes (typo, single-line config) are exempt. Any new file, hook/build-script modification, or test-infrastructure change is **normal tier** — eval is mandatory.
- Think before coding. Surface tradeoffs, don't hide confusion.
- Minimum code that solves the problem. Nothing speculative.
- Touch only what you must. Clean up only your own mess.
- Define success criteria before starting. Verify when done.
- If multiple interpretations exist, present them — don't pick silently.
- Never end a turn after only stating what you are about to do; if a sentence describes a next action, perform it in the same turn.
- Be concise in output, thorough in reasoning.
- Test before declaring done.

## Standards

See `standards/efficiency.md` for the full agent standards (code quality, security, git conventions, token efficiency).

<!-- MODEL-TIERS:BEGIN -->
## Model Tiers

Match model to the sprint work being done. `explore`, `implement`, and `review` are sub-agent dispatch purposes tagged per `skills/sprint/SKILL.md`'s `## Dispatch purposes`; `plan creation` and `grill` are sprint steps that typically run inline in the main session, not separate dispatches — the model choice below still applies to whichever session/dispatch is doing that work.

- `explore` → Haiku — read-only, bounded search/mapping, no judgment calls.
- `plan creation` → Fable or Opus — needs design judgment before scope locks in.
- `implement` → Haiku/Sonnet — execution inside an approved plan.
- `review` / `grill` → Opus — adversarial, judgment-heavy work a weaker model would rubber-stamp.

**Advisor graceful-degradation:** if the session has the `advisor` tool configured with Sonnet+Opus, `implement` can stay Haiku/Sonnet — Opus-level judgment is already reachable via `advisor()`. Otherwise, bump `implement` to Opus for high-risk sprints (no advisor safety net).

**Exception — sprint close gates:** the `review`-purpose dispatches at sprint close (reviewer, evaluator) follow `skills/sprint/reference/complete.md`'s own model-tier rule instead of the `review → Opus` default above: Opus/session-model unless a structural, file-path-only check finds every changed file low-risk (docs/skill-reference/standards, no security-sensitive markers), in which case they run on Haiku. This is a mechanical downgrade, never the dispatching agent's own risk judgment, and an explicit user request for full-tier review always overrides it. See `complete.md`'s "Model tier for gates" section for the exact rule.
<!-- MODEL-TIERS:END -->

<!-- AI-SKILLS:BEGIN -->
## Active canon skills
> Managed by `skills.sh` — use `add`/`remove` to change.

| Skill | Category | Source |
|-------|----------|--------|
| sprint | dev | /Users/sunitjoshi/Developer/canon/skills/sprint/SKILL.md |
<!-- AI-SKILLS:END -->
