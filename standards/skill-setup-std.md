---
name: skill-setup-std
description: Validate skill files against canon standards — invoke when adding a new skill or auditing existing ones
category: agent-ops
tags: [skills, contributors, conventions]
version: 1.4.0
updated: 2026-06-15
---

# Skill Setup Standard

Rules for adding or modifying skills in canon. Follow these so every skill behaves predictably and the import graph stays clean.

## Validation

Run `./tools/canon-dev.sh lint` to validate all skills against these conventions. Fix any reported violations before committing. The linter checks: required frontmatter fields, `hidden` flag consistency, resolvable `depends` entries, and description quality.

## File Location

Skills follow a two-tier layout under `skills/`:

- **Standalone skills**: `skills/<name>/SKILL.md` — one directory per skill.
- **Internal/hidden skills**: `skills/internal/<name>.md` — flat files inside `skills/internal/`.

Standards, tools, and other non-skill files remain flat in their own top-level directories (`standards/`, `tools/`). The dependency hierarchy is encoded in frontmatter and `@` imports, not in deeper folder nesting.

## Naming

- Lowercase, hyphenated directory name: `skills/sprint/`, `skills/context-check/`
- Use a prefix to signal a skill family: `sprint/`, `sprint-check/`
- Max ~20 characters — the directory name appears in `skills.sh list` output
- The `name:` frontmatter field must match the directory name (for `SKILL.md`) or the filename without `.md` (for internal flat files)
- The skill file is always named `SKILL.md` for standalone skills

## Frontmatter

Every skill requires these fields:

```yaml
---
name: my-skill
description: One sentence — what it does and when to use it.
category: dev | agent-ops | ops
tags: [tag1, tag2]
---
```

**Write descriptions for models, not just humans.** The `description` field is the primary signal Claude uses to decide when to invoke a skill. Include the action verbs and user intents that should trigger it. Compare:

- Weak: "Handles code quality tasks" — no trigger signal
- Better: "Review, simplify, and audit code after completing a fix or feature — invoke when work is done and ready to commit"

Standalone skills need this most. Hidden skills (only called by parents) can use a simpler description since a human never selects them directly.

Optional fields:

| Field | When to use |
|---|---|
| `summary:` | Longer description for CATALOG.md when `description:` is too short to convey scope |
| `depends: [skill-a, skill-b]` | Informational dependency list — queryable by `skills.sh lint`; not an injection mechanism |
| `hidden: true` | Skill is only invoked by other skills, never registered directly by a user |

## Loading dependencies

Load sub-skills on demand rather than at invocation time. At the step that first needs a dependency, add an explicit instruction:

```
Read `skills/internal/orient.md`, then run the orient protocol: ...
```

This keeps the always-on context budget proportional — a trivial sprint doesn't pay for wrapup, orient, or impact-analysis.

`@` imports (formerly declared after frontmatter) are retired. Do not add new `@` lines to skill files.

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

## Gotchas

Add a `## Gotchas` section to any skill where real usage has revealed failure patterns — edge cases, footguns, or non-obvious constraints that caused problems. This is the highest-signal section a skill can have; keep it growing.

Format: one bullet per gotcha, led by the condition and followed by what to do instead.

```markdown
## Gotchas

- If `sprint start` reports the wrong ticket ID, `.tickets/` state may be out of sync — run `tkt ls` to inspect before retrying.
- `sprint complete` refuses if any `- [ ]` remain in `acceptance.md` — check boxes manually or waive with a documented reason.
```

Start with zero entries and add as problems surface. A skill without gotchas isn't wrong — it just hasn't been used enough yet.

## On-demand hooks

For skills that need to restrict agent behavior (block dangerous commands, lock edits to specific paths), implement the restriction as a hook that is only active while the skill is running — not always-on.

Pattern: the skill registers a `PreToolUse` hook on entry and removes it on exit, or the user invokes the skill explicitly and the hook fires only within that scope.

Examples:
- A "careful mode" skill that blocks `rm -rf`, `DROP TABLE`, and destructive git commands while active.
- A "lock" skill that restricts file edits to a specific directory during a sensitive operation.

Document the hook behavior clearly at the top of the skill so users know what is being restricted and for how long.

## Update vs. new skill

A nuance to address is first a decision: does it edit an existing skill or become a new one? Apply the one-job test.

- **Edit in place** when the nuance changes *how* a skill already does its single job — a sharper step, a new edge case, a corrected instruction.
- **New skill** when the nuance is a *distinct* job. If describing the change makes you write "and then," or the skill's `description` would stop being one coherent sentence, split it out.

When in doubt, prefer editing — a new skill earns its place only when it has a coherent standalone job (see "Standalone vs. hidden"). If the file carries `version:` / `updated:` frontmatter (standards do; skills usually do not), bump them in the same edit.

## Adding a new skill

1. Create a directory `skills/<name>/` and write the skill as `skills/<name>/SKILL.md`; for internal skills, write directly to `skills/internal/<name>.md`
2. Run `skills.sh list` to confirm it appears with the right name and description
3. Update `CATALOG.md` by running `skills.sh catalog` (or manually if the script doesn't support it)
4. If the skill is imported by an existing skill, add it to that skill's `depends:` list
5. If it's standalone, document it in README.md if it warrants a mention
