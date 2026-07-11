# Repo Map

Quick orientation for arriving agents. One line per directory.

| Directory | Purpose |
|---|---|
| `bin/` | CLI entry points — `sprint`, `sprint-check`, `tkt` symlinks for PATH install |
| `docs/` | User-facing documentation (how-it-works, sprint-check, agent-playbook, guides index) |
| `examples/` | Worked examples — `restaurant-bill-split` (prompt-driven sprint walkthrough), `slugify` (skill-eval demo) |
| `extensions/` | Runtime-specific integrations — Pi agent handoff extension |
| `guides/` | Standalone how-to guides for specific setups (AI agents, Windows, etc.) |
| `meta/` | Repo meta-assets — screenshots, demo GIF recorder (`meta/package.json`); gitignored output |
| `posts/` | Long-form writing and blog drafts |
| `scripts/` | Lifecycle shell scripts — `pre-commit-hook-template.sh` (git-native pre-commit hook body), `test.sh` |
| `skills/` | On-demand agent skills — each in `skills/<name>/SKILL.md`; loaded via `skills.sh add` |
| `standards/` | Always-injected agent standards — `efficiency.md` (code/git/token rules), `skill-setup-std.md` |
| `starters/` | Reserved starter/eval scaffolding area; currently no tracked starter templates |
| `tests/` | Shell + Playwright test suite — `npm test` runs shell suite; `npm run test:ui` runs Playwright |
| `tools/` | CLI tools and the sprint-check app — `tkt`, `sprint`, `skills.sh`, `canon-dev.sh`, `sprint-check-app/` |
