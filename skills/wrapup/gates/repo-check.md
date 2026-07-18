---
name: repo-check
description: Check repo surface files against README intent before the close-time commit
category: agent-ops
tags: [repo-health, workflow, audit, cleanup]
hidden: true
---

# Repo Check

Called by `wrapup` before the close-time commit (`sprint complete` step 10) when repo surface files changed.

## Scope

Run this when changes touch any of:

- `README.md`, `examples/`, `docs/`
- `skills/`, `standards/`, `tools/`, `scripts/`
- `tools/skills.sh`, `CATALOG.md`, install/setup files

Skip for ordinary product-code changes that do not alter repo workflow,
documentation, setup, or agent behavior.

## Checks

1. **README intent.** Read README sections that define the product surface. List
   the commands, skills, tools, and scripts canon claims to provide.

2. **Reference consistency.** Search changed docs and workflow files for stale
   paths, removed commands, removed scripts, or old lifecycle names.

3. **Skill graph.** Run `./tools/skills.sh list`. Confirm advertised standalone skills
   appear there, and imported sub-skills remain hidden from the user-facing list.
   When any `skills/**/SKILL.md` changed, run `./tools/canon-dev.sh lint` — it enforces
   skill-setup-std deterministically (naming, frontmatter, flat location,
   resolvable imports, depends graph). Advisory beyond the linter: flag skills
   that violate one-job (an "and then" in the description) or have a vague
   `description`.

4. **Script surface.** For every script in `scripts/`, confirm it is wired by
   `./tools/skills.sh init`, referenced by an extension, or documented as manually run.
   Flag scripts with no current caller or purpose.

5. **Tool surface.** Confirm `tools/` entries support README flows:
   `sprint`, `sprint-check`, `tkt`, ticket docs, and handoff docs.

6. **sprint-check app experience.** When changes touch `tools/sprint-check`,
   `tools/sprint-check-app/`, `docs/sprint-check.md`, or README claims about
   the board, **visual verification is required — `open` alone does not count.**
   Run `/verify` (Claude-Code-only, like `/context-check` — absent under Codex/Pi/headless) or use Playwright (`npm run test:ui`) to inspect the affected
   flows in a real browser. Specifically: open a ticket that exercises the
   changed surface (tables, modals, tabs, etc.) and confirm the layout renders
   correctly. If `/verify` is unavailable or Playwright isn't set up, take a screenshot and inspect it
   before declaring the gate passed. Declaring done without visual confirmation
   is a gate failure.

7. **Generated docs.** If skills or tool frontmatter changed, run
   `./tools/canon-dev.sh catalog` and include `CATALOG.md` if it changed.

8. **Syntax checks.** Run cheap structural checks for changed executable files:
   `bash -n` for shell scripts. For Python files, run `python3 -m py_compile` only if `command -v python3`
   succeeds — some target machines (e.g. Windows without a real Python install) have no
   working `python3`; report the check as skipped with that reason rather than failing the gate.

## Report

Report only findings that need action before commit:

- stale reference
- command advertised but missing
- file present without a purpose tied to README intent
- sprint-check app flow no longer matching README/docs usability claims
- generated catalog out of date
- syntax check failure

If clean, say: `repo-check: clean`.
