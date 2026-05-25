---
name: doc-audit
description: Audit user-facing docs for overstated claims, missing prerequisites, absolute statements with exceptions, and scope inflation. Appends findings to standards/doc-findings.md on explicit confirmation.
category: agent-ops
tags: [docs, accuracy, audit, claims]
---

# Doc Audit

Audit user-facing documentation for honesty and accuracy. Catches overstated automation, missing prerequisites, absolute claims with real exceptions, and scope inflation before they mislead readers.

Maintains `standards/doc-findings.md` as a running evidence log — append only on explicit confirmation.

## Scope

- `README.md`
- `guides/*.md`
- Skill frontmatter: `description` and `summary` fields across `skills/*.md` and `standards/*.md`

## Steps

1. **Known findings.** Read `standards/doc-findings.md`. Note what's already logged — skip re-flagging in step 5.

2. **Read docs.** Read `README.md` and every file in `guides/`. Note key claims about features, behavior, and requirements.

3. **Read skill descriptions.** For each skill file in `skills/` and `standards/`, extract the `description` and `summary` frontmatter fields. Read the skill body to understand what it actually does.

4. **Run these checks — flag high-confidence issues only, skip borderline cases:**

   **Overstated automation** — phrases like "automatically", "no setup needed", "no coordination required", "just run", "that's it" where a non-obvious step is actually required. Ask: does the reader need to do something that isn't stated here?

   **Missing prerequisites** — a feature described without mentioning a dependency it silently requires (external tool, fork, config, specific file structure). Flag only when the missing prerequisite would surprise a first-time reader.

   **Absolute claims** — "always", "never", "no X required", "zero", "every", "any" that have common real-world exceptions. Skip theoretical edge cases — flag only likely ones.

   **Scope inflation** — a skill's `description` or `summary` claims it does something the skill body doesn't do, or cites a count that doesn't match (e.g., "7 dimensions" listing fewer). Compare frontmatter against actual steps.

   **Internal consistency** — the same feature described differently across README, guides, and skill files in a way that would confuse a reader. Quote both versions.

   **Command accuracy** — run `skills.sh list` and compare against every skill name referenced in `skills.sh add <skill>` or `skills.sh help <skill>` code blocks in README and guides. Flag any name not returned by `skills.sh list` — these are stale or invented references.

   **Personal or private content** — real names, email addresses, usernames, hardcoded home directory paths (`/Users/<name>/`, `/home/<name>/`), internal project names, private ticket prefixes, company-specific references, or anything that would identify the author or their private setup in a public repo. Flag; do not attempt to redact automatically.

5. **Report.** List new findings grouped by check type. Quote the exact claim and explain the issue. If no new findings: say so and stop.

6. **Confirm before writing.** Ask: "Append these to doc-findings.md? (y to confirm)." Do not write without an explicit yes.

## doc-findings.md entry format

```
### YYYY-MM-DD — Short title
**File:** path
**Claim:** exact quote
**Issue:** why it's inaccurate or overstated
**Action:** what was done (or "Open — no action yet")
```

Keep entries concise. When the file exceeds 60 lines, archive entries older than 6 months before appending.
