# canon Catalog

> Static snapshot — run `skills.sh list` for live output.

## Standalone Skills

Register these directly into a project with `skills.sh add <name>`.

| Skill | Category | Description |
|---|---|---|
| `efficiency` | agent-ops | Coding standards, git conventions, and token-efficiency rules for AI agents |
| `skill-setup-std` | agent-ops | Conventions for writing, naming, and composing skills in canon |
| `context-check` | agent-ops | Audit always-on context, hooks, memory, and imported markdown quality. Append findings only on explicit confirmation. |
| `sprint` | dev | The sprint CLI creates/starts tickets, tracks active state, scaffolds files, and validates close. The agent maps the subsystem, resolves gray areas, rates impact, builds, tests, and runs wrapup. |

## Sub-skills

Imported automatically by the skills above. Do not register directly.

| Skill | Imported by |
|---|---|
| `capture` | sprint |
| `code-reviewer` | wrapup, sprint |
| `code-simplifier` | wrapup, sprint |
| `doc-audit` | wrapup, sprint |
| `handoff` | wrapup, sprint |
| `impact-analysis` | sprint |
| `orient` | sprint |
| `security-review` | wrapup, sprint |
| `ticket` | wrapup, sprint |
| `wrapup` | sprint |
