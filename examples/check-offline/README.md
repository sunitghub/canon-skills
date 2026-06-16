# check-offline — Example Skill with Evals

A worked example showing how to write a canon skill and pair it with execution evals.

**The skill:** scans HTML prototype files for external CDN dependencies that would fail in an offline or locked-down environment.

**Use this example to learn:**
- How to structure a `SKILL.md` (frontmatter, steps, gotchas)
- How to write `evals/evals.json` with varied case types
- How to cover control, compliance, boundary, and over-caution cases

## Files

```
check-offline/
  SKILL.md          ← the skill definition
  evals/
    evals.json      ← 5 eval cases across 4 case types
```

## Try it

To run the evals against the skill (requires `skill-eval` registered in your project):

```bash
/skill-eval check-offline
```

To register and use the skill in a project:

```bash
skills.sh add examples/check-offline /path/to/your/project
```

## Eval coverage

| id | case_type | What it tests |
|----|-----------|---------------|
| 1 | control | All-local file → passes clean |
| 2 | compliance | CDN script + stylesheet + Google Fonts preconnect → all flagged |
| 3 | boundary | Commented-out CDN URL → not flagged |
| 4 | over-caution | data: URI and JS string literal URL → not flagged |
| 5 | compliance | `@import url()` inside `<style>` block → flagged |

See [skill-authoring guide](../../guides/skill-authoring.md) for the full authoring workflow.
