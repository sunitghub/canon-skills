---
name: doc-audit
description: Audit user-facing docs for overstated claims, missing prerequisites, absolutes, scope inflation, and stale commands.
category: agent-ops
tags: [docs, accuracy, audit, claims]
---

# Doc Audit

Audit user-facing documentation for accuracy. Append to `doc-findings.md` (project root) only after explicit confirmation.

## Scope

- `README.md`
- `guides/*.md`
- Skill frontmatter: `description` and `summary` fields across `skills/*.md` and `standards/*.md` — only if those paths exist in the current project

## Steps

1. Read `doc-findings.md` if it exists; skip logged issues.

2. Read `README.md` and `guides/*.md`. Note claims about features, behavior, and requirements.

3. Read `description` and `summary` frontmatter in `skills/*.md` and `standards/*.md`; compare to each skill body.

4. Run these checks. Flag only high-confidence issues:

   **Overstated automation** — phrases like "automatically", "no setup needed", "just run", or "that's it" where a hidden step exists.

   **Missing prerequisites** — required tool, config, fork, or file structure not stated.

   **Absolute claims** — "always", "never", "zero", "every", "any" with likely exceptions.

   **Scope inflation** — frontmatter claims behavior not present in the body, or counts that do not match.

   **Internal consistency** — conflicting descriptions across README, guides, and skill files. Quote both.

   **Affected doc coverage** — when code, workflow, UI, command behavior, or screenshots change, search every doc surface that could describe it: README, guides, examples, tool docs, skill docs, standards, and catalog text. Do not stop at the first visible doc.

   **Command accuracy** — if `./skills.sh` exists, run `./skills.sh list`; compare to skill names in README/guides command examples.

   **Workflow gate accuracy** — distinguish UI state changes from workflow commands. Board actions such as creating tickets or moving cards update local ticket state only; do not imply they run agent workflows, wrapup, validation, or close pipelines unless the tool actually does.

   **Heading style** — user-facing README headings should be Title Case. Keep intentional brand casing, command names, and code-block comments unchanged.

   **Private content** — real names, emails, usernames, home paths, private ticket prefixes, company references, secrets. Flag; do not redact automatically.

5. When competitor docs, adjacent tools, or inspiration repos are part of the task, translate the useful input into canon's own intent:

   - Identify what works in their UX, docs, install flow, command model, and positioning.
   - Decide whether the learning belongs in README positioning, a guide, a skill, a standard, or tool behavior.
   - If the pattern should affect future agent behavior, recommend the specific skill or standard update before wrapup.
   - Preserve canon's constraints: local-first state, minimal command surface, live-reference skills, no SaaS dependency, no bloated methodology.

6. Report new findings by check type. Quote the claim and explain the issue. If none: say so and stop.

7. Ask: `Append these to doc-findings.md? (y to confirm)`. Do not write without `y`. Write to `doc-findings.md` at the project root.

## doc-findings.md entry format

```
### YYYY-MM-DD — Short title
**File:** path
**Claim:** exact quote
**Issue:** why it's inaccurate or overstated
**Action:** what was done (or "Open — no action yet")
```

Keep entries concise. When the file exceeds 60 lines, archive entries older than 6 months before appending.
