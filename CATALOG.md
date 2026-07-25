# canon Catalog

> Static snapshot - run `skills.sh list` for live output.

## Standalone Skills

Register these directly into a project with `skills.sh add <name>`.

| Skill | Category | Description |
|---|---|---|
| `capture` | dev | Records non-obvious discoveries, constraints, and gotchas to HANDOFF.md. Use when something surprising is found mid-sprint. |
| `context-check` | agent-ops | Audits always-on context load for bloat, redundancy, and quality. Use when context feels heavy or periodically to keep the always-on budget lean. |
| `mikado` | dev | Maps the dependency tree for a refactor before changing code, using the Mikado Method — attempt the goal, revert on breakage, record prerequisites, execute leaves-first. Use when a refactor is likely to cascade into prerequisite changes or touch interdependent modules. |
| `skill-eval` | dev | Runs execution evals for a named skill against test cases in evals/evals.json. Use when you want to verify a skill produces correct output for known prompts, check skill quality after edits, or confirm a new skill works before registering it. |
| `sprint` | dev | Manages the sprint workflow for focused changes. Use when asked to add, fix, update, implement, debug, or build — see the Workflow tiers section for what's out of scope. |

## Standards

Auto-injected / contributor reference — not registered directly.

| Standard | Category | Description |
|---|---|---|
| `efficiency` | agent-ops | Coding standards, code review feedback, git conventions, behavioral triggers, and token-efficiency rules for AI agents |
| `skill-setup-std` | agent-ops | Validates skill files against canon standards. Use when adding a new skill or auditing existing ones. |

## Sub-skills

Imported automatically by the skills above. Do not register directly.

| Skill | Imported by |
|---|---|
