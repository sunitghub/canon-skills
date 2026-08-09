---
name: subagent-report
description: Structured report format for dispatched subagents — Result, Output, Evidence, Learnings. Used by review.md and eval.md subagent prompts.
category: dev
tags: [subagent, dispatch, report, sprint]
hidden: true
---

# Subagent Report Format

Reference for dispatched subagents (reviewer, evaluator, explore, implement,
advisory). Not invoked directly — loaded by dispatch prompts that need a
structured return shape.

## Contents
- Why
- Four-section structure
  - Result
  - Output
  - Evidence
  - Learnings
- Assembly rules
- Context hygiene

## Why

Subagents spend most of their context on exploration: file reads, dead ends,
broad searches, command output, partial hypotheses. That information matters,
but most of it does not belong in the main agent's context window. The report
format moves noise into a dense, decision-useful structure the parent can
consume in one read.

## Four-section structure

Always use exactly these four headings, in this order. Each section can grow or
shrink independently — right-size to the task.

### Result

Say what happened in the fewest bullets that are still useful. Usually 1–5
bullets; use more only when the outcome has multiple important parts.

Pick only relevant details:
- Status: complete / partial / blocked / failed.
- Outcome: answer, recommendation, root cause, plan, or changed behavior.
- Changes: files changed, or "no changes made".
- Confidence: high / medium / low, only if useful.
- Caveat: important uncertainty, blocker, or unvalidated assumption.
- Material assumption: only if it would change the outcome or recommendation.

Examples:
- Complete. No changes made. Found where the behavior is implemented.
- Partial. Identified the likely root cause, but did not implement a fix.
- Blocked. Could not validate because the local service would not start.
- Complete. Changed the implementation and updated the relevant tests.

Keep out:
- Long background.
- Full task restatement.
- Generic process narration.

### Output

Give the useful substance of the task. Adapt this section to the work.

Output can be short or long depending on the task. For simple tasks, use a few
bullets. For complex exploration, debugging, architecture, planning,
implementation, or review, include enough detail to make the conclusion usable
without reconstructing the work. Prefer dense bullets or short paragraphs over
vague summaries.

For exploration, include:
- Entry points.
- Important files/symbols.
- Key flow or relationship.
- Surprising behavior.

For debate or option analysis, include:
- Recommendation.
- Strongest arguments.
- Tradeoffs.
- Deciding assumptions.

For implementation, include:
- Changed files.
- Behavior changed.
- Affected callers/surfaces.
- Blast radius: what changes, what remains untouched, and compatibility notes.

For planning/spec work, include:
- Plan steps.
- Requirements.
- Acceptance criteria.
- Non-goals.
- Sequencing constraints.

For debugging, include:
- Root cause.
- Repro condition.
- Trace.
- Ruled-out causes.
- Fix point.

For review/validation, include:
- Verdict.
- Issues by severity.
- Checked surface.
- Affected or unaffected surfaces when that changes review scope.
- Important blind spots.

For research/docs, include:
- Answer.
- Source constraint.
- Version/API caveat.
- Implication for this project.

Keep out:
- Full inventories.
- Every observation.
- Tool-by-tool narration.
- Anything that does not change a decision.

### Evidence

Include only anchors needed to trust, verify, or continue the work. For each
important conclusion, include concrete grounding: path + symbol, command + result,
test name, doc/source, config key, error message, or short snippet.

Prefer anchors over long explanation. If a conclusion is interpretation rather
than direct evidence, say so.

Evidence can be longer when exact grounding prevents re-reading or prevents a
bad decision. Expand it for debugging, architecture, security/data risk, subtle
behavior, failed validation, or complex flow. Shrink it to paths, symbols,
commands, and short anchors when those are enough.

When a conclusion depends on code, config, tests, errors, or runtime behavior,
include enough raw evidence to make the conclusion independently checkable.
Prefer decisive snippets and exact anchors over paraphrase. Do not summarize
away the code shape when the code shape is the point.

**Snippet rules:**
- Prefer 3–12 lines.
- Include path + symbol before the snippet.
- Explain why it matters in one sentence.
- Trim unrelated lines aggressively.
- Use 1–3 snippets for normal tasks.
- Use more only for debugging, architecture, security/data risk, or complex flow.

For decisions that depend on code shape, include a tiny evidence packet:
- Source of truth: <path and symbol>
- Decisive anchor: <test, call site, config key, error, or short snippet>
- Why it matters: <one sentence>

For validation, include what the check proves and what it does not prove when
that matters.

Include ruled-out anchors when they prevent repeated rediscovery:
- Checked path/symbol.
- What was ruled out.
- Why it matters.

Keep out:
- Full command logs.
- Full read/search history.
- Long snippets unless necessary.
- Snippets that only prove a file was inspected.
- Full files, boilerplate, imports, generated code, or long blocks unless exact
text is the point.
- Repeating the same fact without adding trust.

### Learnings

Treat this section as important. Actively extract reusable knowledge from the
work, even for small tasks. Do not treat Learnings as optional cleanup.

Include anything that would prevent repeated work or change what someone later
would:
- Search.
- Trust.
- Test.
- Avoid.
- Try first.
- Consider risky.

**Compact shape for each learning:**
- Learning: <one compact lesson>
  Evidence: <path, command, error, source, or exact observation>
  Reuse when: <future trigger>

Good learning types:
- Dead end that looked plausible.
- Failed attempt and why it failed.
- Wrong assumption corrected.
- Stale or misleading doc/comment/name.
- Command/tool gotcha and recovery.
- Hidden coupling or side effect.
- Source-of-truth discovery.
- Project mental model worth reusing.

Keep out:
- Generic advice.
- "I read X."
- Obvious facts from the task.
- Lessons unlikely to recur.

## Assembly rules

- Always use exactly these four headings: Result, Output, Evidence, Learnings.
- Right-size Result, Output, and Evidence independently.
- Learnings is special: actively look for reusable lessons before writing "No
  reusable learnings found."
- A section may be one line, one bullet, many bullets, dense prose, or snippets
  depending on the task.
- Expand when the task involved edits, debugging, architecture, security/data
  risk, failed validation, surprising findings, complex flow, important
  tradeoffs, or decision-critical details.
- Shrink Result, Output, and Evidence when the task was simple, mechanical,
  low-risk, or already fully answered.
- If Result, Output, or Evidence has no useful content, write a brief line such
  as "Nothing material."
- Do not pad short sections to match long ones.
- Do not shorten important evidence just to keep the report brief.
- Prefer detailed substance over summary when the task was non-trivial.
- Sections may grow without a fixed limit when the extra detail improves trust,
  continuation, or decision quality.
- Detail is valuable when it preserves reasoning, code shape, validation meaning,
  tradeoffs, or reusable lessons.
- Detail is waste when it repeats the task, narrates tools, lists everything
  inspected, or proves effort.
- Do not compress away important evidence just to make the report short.
- Do not give a high-level summary when the task produced decision-critical
  details.
- Do not include all examples; choose only relevant details.
- Do not narrate every tool call.
- Snippets are optional and should be short unless exact code shape is the point.
- If no files changed, say "No changes made" once.
- If validation was not run and that matters, mention it in Result or Evidence.
- If there are risks or open questions, mention them in Result or Output; do not
  create a separate section.
- Report what changes future decisions, trust, or behavior.

## Context hygiene

When dispatching a subagent, preserve this constraint:

> Snapshot the active working context only. Do not transform parent context into
text or resolved messages. Sibling, abandoned, or unrelated historical branches
are not copied. The subagent starts from the same working path, does the noisy
work elsewhere, and returns this dense report instead of raw tool noise.

This keeps the expensive prefix stable — the subagent's system prompt and
session context — and only the final task message changes per dispatch.
