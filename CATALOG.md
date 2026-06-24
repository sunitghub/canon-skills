# canon Catalog

> Static snapshot - run `skills.sh list` for live output.

## Standalone Skills

Register these directly into a project with `skills.sh add <name>`.

| Skill | Category | Description |
|---|---|---|
| `capture` | dev | Records non-obvious discoveries, constraints, and gotchas to HANDOFF.md. Use when something surprising is found mid-sprint. |
| `context-check` | agent-ops | Audits always-on context load for bloat, redundancy, and quality. Use when context feels heavy or periodically to keep the always-on budget lean. |
| `output-validator` | agent-ops | Validates agent-generated reports and summaries before delivery. Catches generator-evaluator collapse — where the AI summarizes data without checking if the summary is true. Run before delivering any report, status update, or data summary. |
| `skill-eval` | dev | Runs execution evals for a named skill against test cases in evals/evals.json. Use when you want to verify a skill produces correct output for known prompts, check skill quality after edits, or confirm a new skill works before registering it. |
| `skill-export` | agent-ops | Exports any flat canon skill as a clean, paste-ready prompt for use in claude.ai Project instructions, system prompts, or other LLM systems. Invoke as skill-export <skill-name>. Rejects skills with sub-skills. |
| `sprint` | dev | Manages the sprint workflow for focused changes. Use when asked to add, fix, update, implement, debug, or build anything. |

## Standards

Auto-injected / contributor reference — not registered directly.

| Standard | Category | Description |
|---|---|---|
| `agent-design` | agent-ops | Agent design principles for projects building LLM-powered software — own your prompts, context, control flow, and state. Add with skills.sh add agent-design. |
| `efficiency` | agent-ops | Coding standards, git conventions, and token-efficiency rules for AI agents |
| `skill-setup-std` | agent-ops | Validates skill files against canon standards. Use when adding a new skill or auditing existing ones. |

## Sub-skills

Imported automatically by the skills above. Do not register directly.

| Skill | Imported by |
|---|---|
