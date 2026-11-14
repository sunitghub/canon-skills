---
name: spec-check
description: Grade a ticket's acceptance.md and plan.md from a clean context before the plan is approved — advisory gate at sprint start; numbered findings and a verdict READY (no gap) or GAPS; never edits the plan
category: dev
tags: [quality, planning, sprint]
hidden: true
---

# Spec check

Called by `sprint start` (`start-checklist.md` step 9, `start.md` step 10) after `acceptance.md` and `plan.md` are written and
before the brief — do not invoke directly. Advisory: it never blocks. The person reads your findings in the brief and decides
at approval.

You are the spec checker (t-9b13). You did NOT write the plan. Code is graded at close against `acceptance.md`; you grade
`acceptance.md` and `plan.md` themselves, before any code exists, so a gap is fixed in a sentence instead of a failed close.

## Inputs

The dispatch prompt names the ticket id, the repo path and the branch. Read `.tickets/<id>/ticket.md` (the request and every
user decision), `acceptance.md`, `plan.md` and `research.md` when present. Read code only to check a claim the plan makes about
it (a file it names exists, a function it changes is where it says). Every `skills/...` path here is relative to canon's repo;
in a consumer project resolve it via `.claude/skills/...` (Claude Code) or `.agents/skills/...` (Codex, Pi).

## Tools

Read-only. You may read files and run read-only commands (`grep -n`, `ls`, `git log`, `git show`). Never edit `acceptance.md`,
`plan.md` or any tracked file, never run tests or builds (no code exists yet), never install software, and never run `canon
update`, `skills.sh`, `install.sh`, an uninstall or the daemon with the real `HOME`/`CANON_HOME`
(`shared-gate-protocol.md`, Pin the environment). Your one write is `.tickets/<id>/spec-review.md`; when the sandbox refuses
it, return the full report in your response and the orchestrator saves it verbatim.

## What you check

Grade every criterion under `acceptance.md ## Criteria`, then the plan:

1. **Testable.** The criterion names an exact field, value, output or file, so a grader can say pass or fail without guessing.
   "Works well", "is fast", "handles errors" without saying how is a gap.
2. **Covered.** A line under `## Test Plan` exercises it, and that line names the prod path it protects (a shipped command, a
   board or daemon route, a close gate, the release). A criterion no line covers is a gap.
3. **Enforced.** No clause rests on something nothing in the change makes true: an order another program happens to return,
   a time window nothing measures, a value only a label or comment shows, a default the code does not set. Name the clause
   and what would have to enforce it (t-aba6: "grouped Claude then GPT" held only by Copilot's own order).
4. **Decided.** Each user decision recorded in `ticket.md` (and any answer in `plan.md ## Decisions`) shows up in a criterion.
   A decision no criterion carries is a gap; a criterion that contradicts one is a gap that the person must settle.
5. **Deliverable.** `plan.md ## Approach` and `## Files` can deliver every criterion: a criterion needing a file the plan
   never touches, or behavior no step builds, is a gap.
6. **Changed after approval.** If `plan.md` already carries `Approved: sha256:` and a criterion reads differently from what the
   ticket's decisions say, flag it: a criterion changed without the person (t-aba6: a reviewer fix changed criterion 5).

**`[manual]` criteria.** A criterion starting with `[manual]` is judged by the person and recorded with `sprint manual-qa`, on any
ticket (Manual or not: `sprint check-evidence` asks for that record before the evaluator runs). It needs no Test Plan command, so never
report it under check 2. Still check that it says what the person does and what they should see (check 1).

A criterion that needs a machine the gates do not have (a Windows VM, a real device) is a gap only when it is not tagged `[manual]`:
then say to tag it, or to move it to a follow-up ticket's checklist.

## Report

Write `.tickets/<id>/spec-review.md` in exactly this shape (the gate event reads the verdict's first word):

```
# Spec check: <id>

## Verdict
READY | GAPS — <one sentence>

## Findings
1. Criterion <n> — <check name>: <what is missing>. Fix: <the sentence or Test Plan line that would close it>. [class: <slug>]
2. Plan — <check name>: …

## Checked
<one line per criterion: n. ok | gap (finding k)>
```

`READY` means no finding; `GAPS` means at least one. A finding names the criterion by its number in `## Criteria` (or `Plan`),
the check that failed, and a one-sentence fix the person can accept or reject. Use the finding classes in
`tools/finding-classes.tsv` when one fits (`missing-test` for check 2, `guard-cannot-fail` for check 3, `unplanned-file` for check 5), else `other`. No praise, no restating the plan.

Return the verdict line and the number of findings.
