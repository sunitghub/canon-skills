# canon Catalog

> Static snapshot - run `skills.sh list` for live output.

## Standalone Skills

Register these directly into a project with `skills.sh add <name>`.

| Skill | Category | Description |
|---|---|---|
| `ai-audit` | agent-ops | Audits an AI/LLM codebase across nine surfaces using the SCAN method and returns a ship/conditional/hold verdict. Use when asked to review, audit, or security-check an AI agent, LLM app, RAG pipeline, or prompt/tool-calling system for AI-specific risks. Static analysis only. |
| `capture` | dev | Records non-obvious discoveries, constraints, and gotchas to HANDOFF.md. Use when something surprising is found mid-sprint. |
| `context-check` | agent-ops | Audits always-on context load for bloat, redundancy, and quality. Use when context feels heavy or periodically to keep the always-on budget lean. |
| `mikado` | dev | Maps the dependency tree for a refactor before changing code, using the Mikado Method — attempt the goal, revert on breakage, record prerequisites, execute leaves-first. Use when a refactor is likely to cascade into prerequisite changes or touch interdependent modules. |
| `mutation-test` | dev | Applies small logic mutations to a sprint's changed logic files and asserts the test suite fails on each — a surviving mutant is a test that cannot fail. Use when asked to mutation-test, check whether tests have teeth, or find tests that pass no matter what the code does. Advisory, not a close gate. |
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
