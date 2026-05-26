---
name: doc-audit
description: Audit user-facing docs for overstated claims, missing prerequisites, absolutes, scope inflation, and stale commands.
category: agent-ops
tags: [docs, accuracy, audit, claims]
---

# Doc Audit

Audit user-facing documentation for accuracy. Append to `standards/doc-findings.md` only after explicit confirmation.

## Scope

- `README.md`
- `guides/*.md`
- Skill frontmatter: `description` and `summary` fields across `skills/*.md` and `standards/*.md`

## Steps

1. Read `standards/doc-findings.md`; skip logged issues.

2. Read `README.md` and `guides/*.md`. Note claims about features, behavior, and requirements.

3. Read `description` and `summary` frontmatter in `skills/*.md` and `standards/*.md`; compare to each skill body.

4. Run these checks. Flag only high-confidence issues:

   **Overstated automation** — phrases like "automatically", "no setup needed", "just run", or "that's it" where a hidden step exists.

   **Missing prerequisites** — required tool, config, fork, or file structure not stated.

   **Absolute claims** — "always", "never", "zero", "every", "any" with likely exceptions.

   **Scope inflation** — frontmatter claims behavior not present in the body, or counts that do not match.

   **Internal consistency** — conflicting descriptions across README, guides, and skill files. Quote both.

   **Command accuracy** — run `skills.sh list`; compare to skill names in README/guides command examples.

   **Private content** — real names, emails, usernames, home paths, private ticket prefixes, company references, secrets. Flag; do not redact automatically.

5. Report new findings by check type. Quote the claim and explain the issue. If none: say so and stop.

6. Ask: `Append these to doc-findings.md? (y to confirm)`. Do not write without `y`.

## doc-findings.md entry format

```
### YYYY-MM-DD — Short title
**File:** path
**Claim:** exact quote
**Issue:** why it's inaccurate or overstated
**Action:** what was done (or "Open — no action yet")
```

Keep entries concise. When the file exceeds 60 lines, archive entries older than 6 months before appending.
