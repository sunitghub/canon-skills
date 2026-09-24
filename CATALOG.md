# canon Catalog

> Static snapshot - run `skills.sh list` for live output.

## Standalone Skills

Register these directly into a project with `skills.sh add <name>`.

| Skill | Category | Description |
|---|---|---|
| `ai-audit` | agent-ops | Audits an AI/LLM codebase across nine surfaces using the SCAN method and returns a ship/conditional/hold verdict. Use when asked to review, audit, or security-check an AI agent, LLM app, RAG pipeline, or prompt/tool-calling system for AI-specific risks. Static analysis only. |
| `bulk-read` | agent-ops | Size-gated citation-only reading for large files — checks line count, reads directly under the threshold, dispatches a fresh-context Haiku subagent that returns only file:line citations over it. Use when exploring/understanding a large file (not editing it) in any sprint tier, not just high-risk orient research. |
| `capture` | dev | Records non-obvious discoveries, constraints, and gotchas to HANDOFF.md. Use when something surprising is found mid-sprint. |
| `context-check` | agent-ops | Audits always-on context load for bloat, redundancy, and quality. Use when context feels heavy or periodically to keep the always-on budget lean. |
| `context-doctor` | agent-ops | Audits a repo's agent context — system prompt, CLAUDE.md/AGENTS.md, skills, and references — against context-engineering lessons for Claude 4/5 models (model detected from the running session, or set via --model), then writes claude-optimization.md with a Summary table. Use to right-size an agent setup, cutting over-constraint, redundancy, always-upfront context, and conflicting instructions. |
| `dead-code-cleanup` | dev | Scans a repo for likely-unreferenced top-level symbols (JS/TS exports, Python def/class, Go exported func), reports them as removal candidates, and writes a structured `dead-code-report.md` (summary + high/low-confidence candidate tables). Use when asked to find dead code, unused exports, or unreferenced functions, or to clean up a codebase. Advisory-first — never deletes without explicit confirmation. |
| `learnings-sweep` | agent-ops | Aggregates per-ticket UNPROMOTED .tickets/<id>/learnings.md candidates into a single capped root LEARNINGS.md index, without promoting any of them. Use after `tkt learn <id>` confirms a candidate (single-ticket mode, called from sprint complete), or run `--full` by hand to backfill/reconcile the whole repo. |
| `promote-learnings` | agent-ops | Reviews LEARNINGS.md's UNPROMOTED rows as a fresh, no-implementation-history reader and proposes where each durable one belongs. Report-only, except that in a consumer project it writes the proposals you confirm to PROMOTED.md. Use as one of Upkeep's four report-only checks, or by hand when the UNPROMOTED queue needs triage. |
| `sdlc-audit` | agent-ops | Audits a repo's development workflow against Anthropic's AI-Native SDLC Playbook (twenty practices across plan, design, build, test, deploy, maintain) and rates each Covered, Partial, or Gap with file:line evidence. Use when asked to check a repo's dev process maturity, compare a workflow to the AI-native SDLC playbook, or assess how "AI-native" a team's build/test/deploy pipeline is. |
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
| `wrapup` | sprint |
