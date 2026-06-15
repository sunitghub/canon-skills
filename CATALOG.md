# canon Catalog

> Static snapshot - run `skills.sh list` for live output.

## Standalone Skills

Register these directly into a project with `skills.sh add <name>`.

| Skill | Category | Description |
|---|---|---|
| `handoff` | tools | Session context handoff protocol using repo-local HANDOFF.md |
| `ticket` | tools | Bundled minimal ticket system (tkt) for creating, tracking, and closing tasks. Used by sprint and sprint-check. |
| `capture` | dev | Record a non-obvious discovery, constraint, or gotcha to HANDOFF.md — invoke when something surprising is found mid-sprint |
| `context-check` | agent-ops | Audit always-on context load for bloat, redundancy, and quality — invoke periodically or when context feels heavy |
| `doc-audit` | agent-ops | Audit user-facing docs for overstated claims, missing prerequisites, absolutes, scope inflation, and stale commands. |
| `sprint` | dev | Start, plan, and ship a focused change — invoke when asked to add, fix, update, implement, debug, or build anything |
| `wrapup` | dev | Run quality checks, review, and commit after completing a feature, fix, or session — invoke when work is done and ready to ship |

## Standards

Auto-injected / contributor reference — not registered directly.

| Standard | Category | Description |
|---|---|---|
| `efficiency` | agent-ops | Coding standards, git conventions, and token-efficiency rules for AI agents |
| `skill-setup-std` | agent-ops | Conventions for writing, naming, and composing skills in canon |
| `ticket-layout` | dev | Canonical ticket structure contract — folder layout, frontmatter fields, sprint doc lifecycle, board rendering, and migration rules |

## Sub-skills

Imported automatically by the skills above. Do not register directly.

| Skill | Imported by |
|---|---|
