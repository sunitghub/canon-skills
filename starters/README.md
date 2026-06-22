# starters

Copy-paste scaffolding for new agent projects. Drop these into a new repo and adapt.

## Files

| File | What it gives you |
|---|---|
| `CLAUDE.md` | Agent instructions template — conventions, key files, gotchas |
| `AGENTS.md` | Active skills table + approach rules |
| `standards/efficiency.md` | Code quality, git conventions, token efficiency rules (set `inject: true`) |
| `skills/my-skill/SKILL.md` | Skill anatomy template with all required sections |
| `skills/my-skill/evals/evals.json` | Eval scaffold with all four case types |

These are a one-time copy — the starting point for a new project. Once you run `skills.sh add sprint`, canon's live-reference model takes over and your skills stay in sync with `~/.canon` without further copying.

## Quick start

1. Copy the files you need into your new project root
2. Replace `<project>`, `<name>`, `my-skill`, and placeholder text throughout
3. Set `inject: true` in `standards/efficiency.md` if your harness supports always-on context
4. Read `docs/agent-playbook.md` in the canon repo for the design rationale behind each file

## What you still need to add

- `DECISIONS.md` — create empty at project start, append as you make non-obvious choices
- `HANDOFF.md` — current session state; refresh at end of each session
- `.tickets/` — sprint tickets (optionally gitignore this directory)
