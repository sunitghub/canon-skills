# canon: Agent Instructions

Universal instructions for AI coding agents. Loaded natively by Claude Code, Pi, and Codex CLI.

## Approach

- Non-trivial work needs an open ticket before `sprint start`; trivial fixes (typo, one-line config) are exempt. A new file, test/build wiring, a hook or pipeline change, or a coordinated multi-file change is **normal tier**: eval is mandatory. `bugfix` (one logic file plus its test) is an eval-only downgrade decided at close from the diff. See `skills/sprint/SKILL.md`'s Workflow tiers.
- Think before coding. Surface tradeoffs, don't hide confusion.
- Minimum code that solves the problem. Nothing speculative.
- Touch only what you must. Clean up only your own mess.
- A research-only subagent with full tool access (e.g. `general-purpose`) must be told not to edit or write any file.
- Subagents return a structured report (Result, Output, Evidence, Learnings: `skills/sprint/reference/subagent-report.md`), not raw tool noise; give them the active branch only.
- Define success criteria before starting. Verify when done.
- User decisions and the approved plan are settled: reopen them only on new evidence or when the user does — and always surface a mistake you find in earlier work.
- If multiple interpretations exist, present them — don't pick silently.
- Never end a turn after only stating a next action: do it. The exceptions are canon's approval checkpoints (`sprint start`'s plan approval, `sprint complete`'s close confirmation), where stopping is required.
- Be concise in output, thorough in reasoning.
- Test before declaring done.
- Editing `tools/sprint-check-app/` (the board)? Read `tools/sprint-check-app/CLAUDE.md` first — board-specific gotchas (Cockpit fetch scoping, id prefixes, Playwright setup). Harnesses don't all load a nested CLAUDE.md on their own.

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

Close-gate model rules (sprint reviewer/evaluator) live in `skills/sprint/reference/complete.md`, not here.
<!-- MODEL-TIERS:END -->

## Model Tiers: canon internals (not copied to projects)

The board's `Gate model:` dropdown and its Admin registry: `tools/sprint-check-app/CLAUDE.md`.

**Close-gate effort** comes from canon's gate agent definitions (`agents/canon-reviewer.md`,
`canon-evaluator.md`: `effort: high`, a `claude-sonnet-5` model floor, read-only tools with `Bash`/`execute` shells), not from this prose.
A dispatch can set only the model, never effort (`t-c774`).

**Exception — sprint close gates** follow their own rule (may downgrade to the Admin > Model
Tiers "Review & Eval" default, applied unconditionally to every interactive close since
2026-09-23; to Haiku on a `demo: true` ticket, evaluator only; or via an explicit user
`Gate model:` override, which always wins) — see the
"Model tier for gates" note in `skills/sprint/reference/complete.md`, not this block.

**Cross-harness note.** Codex and pi dispatch differ (per-agent model only through a `~/.codex/agents/*.toml` custom agent; pi gates run on the pi session model): see `complete.md`'s "Cross-harness caveat" and pi-dispatch bullets.

**North-star (gate floor).** Only structural risk may reduce close gates, and a sprint never drops below the binding evaluator. The one documented exception is a user-set `demo: true` light-close (the evaluator still runs). The full policy — demo mode, the model tier for gates, and the north-star amendments — lives in `skills/sprint/reference/complete.md` (see also `DECISIONS.md` 2026-07-25 / 07-30 / 08-02).

<!-- AI-SKILLS:BEGIN -->
## Active canon skills
> Managed by `skills.sh` — use `add`/`remove` to change.

| Skill | Category | Source |
|-------|----------|--------|
| sprint | dev | /Users/sunitjoshi/Developer/canon/skills/sprint/SKILL.md |
<!-- AI-SKILLS:END -->
