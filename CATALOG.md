# canon Catalog

> Static snapshot - run `skills.sh list` for live output.

## Standalone Skills

Register these directly into a project with `skills.sh add <name>`.

| Skill | Category | Description |
|---|---|---|
| `context-check` | agent-ops | Audit always-on context load for bloat, redundancy, and quality — invoke periodically or when context feels heavy |
| `sprint` | dev | Invoke when asked to add, fix, update, implement, debug, or build anything. Creates the ticket, runs planning (acceptance, impact analysis), builds and tests, then closes with full wrapup. |

## Standards

Auto-injected / contributor reference — not registered directly.

| Standard | Category | Description |
|---|---|---|
| `efficiency` | agent-ops | Coding standards, git conventions, and token-efficiency rules for AI agents |
| `skill-setup-std` | agent-ops | Conventions for writing, naming, and composing skills in canon |

## Sub-skills

Imported automatically by the skills above. Do not register directly.

| Skill | Imported by |
|---|---|
| `handoff` | sprint, wrapup |
| `ticket` | sprint, wrapup |
| `capture` | sprint |
| `code-reviewer` | wrapup |
| `code-simplifier` | wrapup |
| `doc-audit` | wrapup |
| `impact-analysis` | sprint |
| `orient` | sprint |
| `repo-check` | wrapup |
| `security-review` | wrapup |
| `wrapup` | sprint |
