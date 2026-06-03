---
name: skill-setup-std
description: Conventions for writing, naming, and composing skills in canon
category: agent-ops
tags: [skills, contributors, conventions]
version: 1.2.0
updated: 2026-06-03
---

# Skill Setup Standard

Rules for adding or modifying skills in canon. Follow these so every skill behaves predictably and the import graph stays clean.

## File Location

All skills live flat under `skills/`. No subdirectories. The dependency hierarchy is encoded in frontmatter and `@` imports — not in the folder structure.

## Naming

- Lowercase, hyphenated: `code-reviewer.md`, `impact-analysis.md`
- Use a prefix to signal a skill family: `sprint.md`, `sprint-check.md`
- Max ~20 characters — the name appears in `skills.sh list` output
- The `name:` frontmatter field must match the filename without `.md`

## Frontmatter

Every skill requires these fields:

```yaml
---
name: my-skill
description: One sentence — what it does and when to use it. Shown in skills.sh list.
category: dev | agent-ops | ops
tags: [tag1, tag2]
---
```

Optional fields:

| Field | When to use |
|---|---|
| `summary:` | Longer description for CATALOG.md when `description:` is too short to convey scope |
| `depends: [skill-a, skill-b]` | List skills this one imports — keeps the dependency graph queryable |
| `hidden: true` | Skill is only invoked by other skills, never registered directly by a user |

## Imports

Declare `@` imports at the top of the file, immediately after the frontmatter block. One per line. Use relative paths.

```
@./wrapup.md
@./capture.md
@../tools/handoff.md
```

The import order matters — Claude reads them top to bottom. Put broader context (standards, tools) before narrow behavior.

## Standalone vs. hidden

A skill is **standalone** if a user can register and invoke it directly. It should work without knowing what imports it.

A skill is **hidden** (`hidden: true`) if it is only ever called by another skill and has no meaningful standalone invocation. Document this clearly at the top of the file: `Called automatically by X — do not invoke directly.`

If a skill is useful both ways, make it standalone and let the parent import it.

## One job

A skill that does two things is two skills waiting to be separated. If you find yourself writing "and then" in the description, split it. `skills.sh lint` flags an "and then" in a leaf skill's description; orchestrators (skills with a `depends:` list) are exempt because composing children is their job.

Composition is fine — a parent skill imports children and orchestrates them. But each child should be coherent on its own.

## Minimal content

A skill is instructions for an agent, not a manual. Write the smallest body that makes the behavior unambiguous:

- State the job, the steps, and the stop condition. Cut everything else.
- No restating canon-wide standards — `@`-import them instead of copying.
- No motivational preamble, no "why this matters" essays, no duplicated examples.
- If a section does not change what the agent does, delete it.

Length is a smell, not a limit: a leaf skill that runs long is usually doing more than one job (see above) or repeating context it should import.

## Update vs. new skill

A nuance to address is first a decision: does it edit an existing skill or become a new one? Apply the one-job test.

- **Edit in place** when the nuance changes *how* a skill already does its single job — a sharper step, a new edge case, a corrected instruction.
- **New skill** when the nuance is a *distinct* job. If describing the change makes you write "and then," or the skill's `description` would stop being one coherent sentence, split it out.

When in doubt, prefer editing — a new skill earns its place only when it has a coherent standalone job (see "Standalone vs. hidden"). If the file carries `version:` / `updated:` frontmatter (standards do; skills usually do not), bump them in the same edit.

## Adding a new skill

1. Write the skill file in `skills/` following the conventions above
2. Run `skills.sh list` to confirm it appears with the right name and description
3. Update `CATALOG.md` by running `skills.sh catalog` (or manually if the script doesn't support it)
4. If the skill is imported by an existing skill, add it to that skill's `depends:` list
5. If it's standalone, document it in README.md if it warrants a mention
