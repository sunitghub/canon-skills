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
- Test before declaring done, with only the tests that matter: add or keep a test only when it protects a prod path (a shipped command, a board or daemon route, the release or a close gate) and names it, never for an unused feature or to repeat another test (`skills/sprint/reference/start-checklist.md` step 6). While building, run only the suites that cover the change; run the full suite once, for the stamp.
- Editing `tools/sprint-check-app/` (the board)? Read `tools/sprint-check-app/CLAUDE.md` first — board-specific gotchas (Cockpit fetch scoping, id prefixes, Playwright setup). Harnesses don't all load a nested CLAUDE.md on their own.

## Standards

See `standards/efficiency.md` for the full agent standards (code quality, security, git conventions, token efficiency).

<!-- MODEL-TIERS:BEGIN -->
## Model Tiers
Models per step come from Admin > Model Tiers on the board (Plan, Spec check, Build, Reviewer, Evaluator, Simple / Light work); the close applies the gate models (`skills/sprint/reference/complete.md`). A read-only search or explore subagent you start yourself runs on the Light work model (Haiku by default).
<!-- MODEL-TIERS:END -->

## Model Tiers: canon internals (not copied to projects)

Gate models, effort and the Codex/pi caveats: `skills/sprint/reference/complete.md` ("Model tier for gates", "Cross-harness caveat") and `agents/canon-reviewer.md` / `canon-evaluator.md`; the `Gate model:` dropdown and the Admin registry: `tools/sprint-check-app/CLAUDE.md`.

**North-star (gate floor).** Only structural risk may reduce close gates, and a sprint never drops below the binding evaluator. The documented exceptions are two user-set ticket options that only skip optional gates, `demo: true` (Lite) and `manual: true` (Manual, the user's recorded testing is the evidence): the evaluator still runs (read-only on Manual) and no locked row is skipped. The full policy — demo mode, the model tier for gates, and the north-star amendments — lives in `skills/sprint/reference/complete.md` (see also `DECISIONS.md` 2026-07-25 / 07-30 / 08-02).

<!-- AI-SKILLS:BEGIN -->
## Active canon skills
> Managed by `skills.sh` — use `add`/`remove` to change.
> Platforms: run canon's commands (sprint, tkt, skills, canon) exactly as written, never piped into head, Select-Object, a pager or a filter, never with output dropped: their output is your next step. On Windows they run from any shell through their .cmd shims, which start Git Bash; .sh scripts need Git Bash. Details: standards/efficiency-notes.md › Platforms (canon install).

| Skill | Category | Source |
|-------|----------|--------|
| sprint | dev | skills/sprint/SKILL.md |
<!-- AI-SKILLS:END -->
