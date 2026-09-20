---
name: subagent-report
description: Structured report format for dispatched subagents — Result, Output, Evidence, Learnings. Used by review.md and eval.md subagent prompts.
category: dev
tags: [subagent, dispatch, report, sprint]
hidden: true
---

# Subagent Report Format

For dispatched subagents (reviewer, evaluator, explore, implement, advisory). Loaded by
dispatch prompts — not invoked directly.

## Contents
- Why
- Four-section structure (Result · Output · Evidence · Learnings)
- Assembly rules
- Context hygiene

## Why

Subagents burn context on exploration — reads, dead ends, searches, command output,
dropped hypotheses. Little of it belongs in the parent's window. This format returns the
decision-useful residue in one read.

## Four-section structure

Exactly these four headings, this order. Right-size each independently.

### Result

What happened, fewest useful bullets — usually 1–5. Only what applies:
- Status: complete / partial / blocked / failed.
- Outcome: answer, recommendation, root cause, plan, or changed behavior.
- Changes: files changed, or "no changes made".
- Confidence: high / medium / low, when useful.
- Caveat: uncertainty, blocker, unvalidated assumption.
- Material assumption: only if it would change the outcome.

Examples:
- Complete. No changes made. Found where the behavior is implemented.
- Partial. Identified the likely root cause, but did not implement a fix.
- Blocked. Could not validate because the local service would not start.
- Complete. Changed the implementation and updated the relevant tests.

No background, task restatement, or process narration.

### Output

The substance — dense bullets, enough to use the conclusion without reconstructing the work.

- Exploration — entry points, important files/symbols, key flow, surprising behavior.
- Option analysis — recommendation, strongest arguments, tradeoffs, deciding assumptions.
- Implementation — changed files, behavior changed, affected callers/surfaces, blast radius (what
  changes, what stays untouched, compatibility notes).
- Planning/spec — steps, requirements, acceptance criteria, non-goals, sequencing.
- Debugging — root cause, repro condition, trace, ruled-out causes, fix point.
- Review/validation — verdict, issues by severity, checked surface, affected/unaffected surfaces when that changes review scope, blind spots.
- Research/docs — answer, source constraint, version/API caveat, implication here.

No full inventories, no every-observation logging, no tool-by-tool narration, nothing that
doesn't change a decision.

### Evidence

Only anchors needed to trust, verify, or continue: path + symbol, command + result, test
name, doc/source, config key, error message, short snippet. Label interpretation as such.

Evidence can be longer when exact grounding prevents re-reading or a bad decision. Expand for
debugging, architecture, security/data risk, subtle behavior, failed validation, complex flow;
shrink to paths, symbols, commands, and short anchors when those are enough. When a conclusion
depends on code, config, tests, errors, or runtime behavior, include enough raw evidence to make
it independently checkable — prefer decisive snippets and exact anchors over paraphrase; do not
summarize away the code shape when the code shape is the point.

**Snippet rules:**
- Prefer 3–12 lines.
- Path + symbol before the snippet.
- One sentence on why it matters.
- Trim unrelated lines aggressively.
- 1–3 snippets normally; more only for debugging, architecture, security/data risk, or complex flow.

Code-shape decisions carry a tiny evidence packet:
- Source of truth: <path and symbol>
- Decisive anchor: <test, call site, config key, error, or short snippet>
- Why it matters: <one sentence>

For validation, state what the check proves and what it does not. Add ruled-out anchors —
checked path, what was ruled out, why — when they prevent rediscovery.

No full command logs, no full read/search history, no long snippets unless necessary, no
snippet that only proves a file was opened, no full files/boilerplate/imports/generated
code/long blocks unless exact text is the point, no repeating the same fact without adding
trust.

### Learnings

Not optional cleanup. Extract reusable knowledge even on small tasks — anything that would
change what someone later searches, trusts, tests, avoids, tries first, or treats as risky.

**Compact shape for each learning:**
- Learning: <one compact lesson>
  Evidence: <path, command, error, source, or exact observation>
  Reuse when: <future trigger>

Good types: plausible dead end; failed attempt and why; corrected assumption; stale
doc/comment/name; command/tool gotcha and recovery; hidden coupling or side effect;
source-of-truth discovery; reusable mental model.

No generic advice, no "I read X", no obvious facts, no one-off lessons.

## Assembly rules

- Always the four headings; right-size Result, Output, Evidence independently.
- A section may be one line, one bullet, many bullets, dense prose, or snippets depending on the task.
- Learnings is special — hunt for lessons before writing "No reusable learnings found."
- Nothing to say in a section → "Nothing material." Never pad; never trim important evidence for brevity.
- Expand for edits, debugging, architecture, security/data risk, failed validation,
  surprises, tradeoffs, decision-critical detail. Shrink for simple, mechanical, low-risk, or
  already fully answered work.
- Sections may grow without limit when the extra detail improves trust, continuation, or
  decision quality — prefer detailed substance over summary for non-trivial work.
- Detail earns its place when it preserves reasoning, code shape, validation meaning,
  tradeoffs, or lessons; it is waste when it repeats the task, narrates tools, lists
  everything inspected, gives a high-level summary of decision-critical details, or proves effort.
- Do not include all examples; choose only relevant details.
- Snippets are optional and should be short unless exact code shape is the point.
- "No changes made" once, if nothing changed. Unrun validation that matters goes in Result
  or Evidence. Risks and open questions go in Result or Output — no extra section.
- Report what changes future decisions, trust, or behavior.

## Context hygiene

When dispatching a subagent, preserve this constraint:

> Snapshot the active working context only. Do not transform parent context into
text or resolved messages. Sibling, abandoned, or unrelated historical branches
are not copied. The subagent starts from the same working path, does the noisy
work elsewhere, and returns this dense report instead of raw tool noise.

This keeps the expensive prefix stable — system prompt and session context — with only the
final task message changing per dispatch.
