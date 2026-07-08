# canon: Agent Instructions

Universal instructions for AI coding agents. Loaded natively by Claude Code, Pi, and Codex CLI.

## Approach

- Non-trivial work requires an open ticket before `sprint start`. Trivial fixes (typo, single-line config) are exempt. Adding a new file, wiring into test or build infrastructure, modifying a hook, pipeline, or post-commit script, or touching more than one file with coordinated intent is **normal tier** — eval is mandatory.
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

Match model to the sprint work being done. `explore`/`implement`/`review` are sub-agent
dispatch purposes (`skills/sprint/SKILL.md`'s `## Dispatch purposes`); `plan creation` and
`grill` are sprint steps that usually run inline in the main session, not separate
dispatches — the tier below still applies to whichever session/dispatch does that work.

- `explore` → Haiku — read-only, bounded search/mapping, no judgment calls.
- `plan creation` → Fable or Opus — needs design judgment before scope locks in.
- `implement` → Haiku/Sonnet — execution inside an approved plan.
- `review` / `grill` → Opus — adversarial, judgment-heavy; a weaker model would rubber-stamp.

**Advisor graceful-degradation.** With `advisor` configured on Sonnet+Opus, `implement` can
stay Haiku/Sonnet — Opus-level judgment is reachable via `advisor()`. Without it, bump
`implement` to Opus for high-risk sprints (no advisor safety net).

**Exception — sprint close gates.** Reviewer/evaluator dispatches at sprint close don't use
the `review → Opus` default above — they follow `skills/sprint/reference/complete.md`'s own
rule:

- Session model, downgraded to Haiku only when a structural, file-path-only check finds
  every changed file low-risk (docs/skill-reference/standards, no security-sensitive
  markers). Mechanical only — never the dispatching agent's own risk judgment.
- An explicit user request for a specific model (including full-tier) always overrides the
  downgrade, and is persisted verbatim as `plan.md`'s `## Sign-off` `Gate model:` field so
  it survives a compaction before the gates actually dispatch.
- `acceptance.md`/`plan.md` content is never read for the *classification itself* — only
  file paths, plus one narrow exception: a `Gate model:` value on the Sign-off line, which
  is read back only as a literal fact the user set (conversationally or by hand-editing the
  file), never as a risk signal inferred from surrounding prose. Everything else in
  `acceptance.md`/`plan.md` is what reviewer/evaluator read as ground truth (`eval.md`'s own
  framing: "what was promised, what approach was approved"); letting the classification
  itself take a cue from that prose would be a self-referential trust hole, not a
  convenience.

See `complete.md`'s "Model tier for gates" section for the exact rule.

**Cross-harness note.** This section assumes an `Agent`-tool-shaped primitive: spawn a
fresh-context subagent, optionally on a different model, in one call.

- **Confirmed under Codex:** fresh-context dispatch works (Codex's real `spawn_agent`/
  `wait_agent`/`close_agent` tools, namespace `multi_agent_v1`) — it successfully ran a
  canon evaluator gate in a prior session, so the self-review-bias guarantee holds on
  both harnesses.
- **Not confirmed under Codex:** per-agent **model selection** — the observed `spawn_agent`
  call takes `agent_type`/`fork_context`/`message`, no `model` field. The Haiku-downgrade
  above is Claude-Code-confirmed only; don't assume it works under Codex without testing
  live first.
- **Bigger risk than the lost cost optimization:** Codex's model picker is session-level,
  not per-dispatch — a Codex session run on a cheap model **silently** loses the
  model-strength floor on `review`/`grill`'s close-gate Opus bump too, with no escalation
  path.
- Fresh-context isolation (the primary self-review-bias protection) still holds regardless
  of any of the above — but it's real, and worth knowing before trusting a Codex-run
  review on a mini model the way you'd trust one under Claude Code.
<!-- MODEL-TIERS:END -->

<!-- AI-SKILLS:BEGIN -->
## Active canon skills
> Managed by `skills.sh` — use `add`/`remove` to change.

| Skill | Category | Source |
|-------|----------|--------|
| sprint | dev | /Users/sunitjoshi/Developer/canon/skills/sprint/SKILL.md |
<!-- AI-SKILLS:END -->
