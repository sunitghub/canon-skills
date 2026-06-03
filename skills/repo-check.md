---
name: repo-check
description: Check repo surface files against README intent before wrapup commits
category: agent-ops
tags: [repo-health, workflow, audit, cleanup]
hidden: true
---

# Repo Check

Called by `wrapup` before commit when repo surface files changed.

## Scope

Run this when changes touch any of:

- `README.md`, `guides/`, `examples/`
- `skills/`, `standards/`, `tools/`, `scripts/`
- `skills.sh`, `CATALOG.md`, install/setup files

Skip for ordinary product-code changes that do not alter repo workflow,
documentation, setup, or agent behavior.

## Checks

1. **README intent.** Read README sections that define the product surface. List
   the commands, skills, tools, and scripts canon claims to provide.

2. **Reference consistency.** Search changed docs and workflow files for stale
   paths, removed commands, removed scripts, or old lifecycle names.

3. **Skill graph.** Run `./skills.sh list`. Confirm advertised standalone skills
   appear there, and imported sub-skills remain hidden from the user-facing list.
   When any `skills/*.md` changed, run `./skills.sh lint` — it enforces
   skill-setup-std deterministically (naming, frontmatter, flat location,
   resolvable imports, depends graph). Advisory beyond the linter: flag skills
   that violate one-job (an "and then" in the description) or have a vague
   `description`.

4. **Script surface.** For every script in `scripts/`, confirm it is wired by
   `./skills.sh init`, referenced by an extension, or documented as manually run.
   Flag scripts with no current caller or purpose.

5. **Tool surface.** Confirm `tools/` entries support README flows:
   `sprint`, `sprint-check`, `tkt`, ticket docs, and handoff docs.

6. **Generated docs.** If skills or tool frontmatter changed, run
   `./skills.sh catalog` and include `CATALOG.md` if it changed.

7. **Syntax checks.** Run cheap structural checks for changed executable files:
   `bash -n` for shell scripts, `python3 -m py_compile` for Python files.

## Report

Report only findings that need action before commit:

- stale reference
- command advertised but missing
- file present without a purpose tied to README intent
- generated catalog out of date
- syntax check failure

If clean, say: `repo-check: clean`.
