---
name: output-validator
description: Validates agent-generated reports and summaries before delivery. Catches generator-evaluator collapse — where the AI summarizes data without checking if the summary is true. Run before delivering any report, status update, or data summary.
category: agent-ops
tags: [validation, reports, accuracy, output-quality]
---

# Output Validator

Before delivering any report or summary: define what a valid output looks like, generate, then verify the output against that spec.

## When to use

Any time an agent produces a summary over source data: status reports, feature trackers, project dashboards, analysis outputs. Run this before handing off to the user.

## Phase 1 — Pre-generation spec

Before pulling data or rendering output, answer these three questions and write the answers as a short checklist:

1. **What counts reconcile?** Name the summary metric and how it should relate to the detail rows. Example: "Released + In Development + Ready to Release = Total features."
2. **What exceptions must always surface?** Name the categories that cannot be buried in detail regardless of the headline. Examples: security issues, blockers, items past their target date, status contradictions (a critical item marked done while work is open).
3. **What does an accurate headline look like?** Define what the top-line metric (% complete, count, status) must reflect. Example: "99% complete is only accurate if no open security issues or blockers exist in the detail."

This checklist is the validation spec. Keep it visible — it is the external anchor for Phase 2.

## Phase 2 — Post-generation checks

After the report is generated, run each check explicitly against the spec from Phase 1:

**Check 1 — Number reconciliation**
Add up the detail rows and compare to the summary counts. Quote both. If they differ, state the discrepancy and correct the summary before delivering.

**Check 2 — Exception surfacing**
Scan every detail row for the exception categories defined in Phase 1. List each hit explicitly — name, status, and why it matters. If any exception is present but absent from the summary or headline, flag it as a divergence.

**Check 3 — Headline accuracy**
Given the exceptions found in Check 2, does the headline still hold? If a security issue, blocker, or overdue item exists in the detail, the headline must acknowledge it — or be revised to accurately represent the actual state.

## Output

If all checks pass: state `output-validator: clean` then deliver.

If any check fails: state the divergence, revise the affected section, then re-run the failed check before delivering.

## Usage in claude.ai / Project instructions

This skill has no sub-skills and works in any single-model environment. To use in claude.ai without Claude Code: paste the content of this skill (below the frontmatter) into your Project's custom instructions. The agent will follow the two-phase protocol for any report task in that project.
