---
name: repo-audit
description: Audit a repo across four dimensions — uniqueness and selling point, philosophy-to-implementation coherence, setup and doc effectiveness, and codebase quality (DRY, KISS, SRP, composition). Invoke when asked to review, assess, or health-check a repo.
category: agent-ops
tags: [audit, analysis, sdlc, docs, philosophy]
hidden: true
---

# Repo Audit

A four-dimension analysis. Run from any project directory — the audit reads the repo under analysis, not canon. Produces an inline report and always writes or updates the latest report at `critique/canon-critique.md` in the repo under analysis, with the audit run DateTime as the first line.

## Before Auditing

Read these in order, stop when you have enough to answer each dimension:

1. `README.md` — value prop, install path, stated audience
2. Philosophy/design doc (`docs/how-it-works.md`, `DESIGN.md`, `ARCHITECTURE.md`, or ADRs if present)
3. Primary setup/install guide
4. `CONTRIBUTING.md` (if present)
5. 3–5 core source files (main CLI entrypoint, core logic) — skip test fixtures, generated files, `node_modules`, `dist`

Do not read everything. Read until you can answer the questions for each dimension.

---

## Dimension 1 — Uniqueness and Selling Point

**Goal**: Determine whether the repo has a clear, genuine differentiator — and whether it lands for the target user.

Questions to answer:
- What is the stated purpose? Who is the target user?
- What problem does it solve, and for whom?
- What alternatives exist? Name them. What does this repo do that they don't?
- What is genuinely novel vs. table stakes?
- Does the README earn its differentiation claim, or does it assert without showing?
- Would the target user read this and say "finally" — or "so what"?

**Rate**: Distinct / Murky / Generic

---

## Dimension 2 — Philosophy-to-Implementation Coherence

**Goal**: Verify the implementation honors the philosophy — not just in words, but in every command, tool, and convention.

Questions to answer:
- What is the repo's stated philosophy? Extract it explicitly from the docs. (If it's not stated, that's a finding.)
- Does the implementation honor it? Check: command surface size, complexity vs. claimed simplicity, patterns in core code
- Does the usage pattern (workflows, commands, default behaviors) reflect the philosophy?
- Where does the implementation contradict or silently undermine the stated philosophy?
- Are there features that have crept in and violated it?

Look for: philosophy stated but not implemented, implementation that outgrew its stated scope, or a tool that claims minimalism but adds flags for every edge case.

**Rate**: Strong / Drifting / Contradicted

---

## Dimension 3 — Setup and Doc Effectiveness

**Goal**: "Can a newcomer get from zero to working using these docs?" Focus on the user journey, not per-claim accuracy. (Per-claim accuracy → `doc-audit`.)

Questions to answer:
- Is there a clear, tested install path? Can you follow it cold, without prior knowledge?
- Are prerequisites explicit before they're needed — not buried mid-guide?
- Is the first success moment reachable without hitting a wall? How many steps?
- Do examples exist? Do they match current behavior?
- Is the docs structure navigable? Can you find what you need without reading everything?
- Are there implicit environment assumptions (OS, shell, global tools)?
- When step N fails, is there a recovery path — or does the guide end there?

**Rate**: Clear / Gaps / Broken

---

## Dimension 4 — Codebase Quality

**Goal**: Assess how well the codebase follows SDLC principles adapted for the repo's paradigm (shell, markdown, CLI, agents — not OOP).

Principles to apply (map to what's present, skip what isn't applicable):

| Principle | In shell/CLI/agent context |
|-----------|---------------------------|
| **SRP** (Single Responsibility) | Each script/tool/skill does one thing; no file with multiple unrelated jobs |
| **DRY** (Don't Repeat Yourself) | Each fact has one canonical location; logic isn't duplicated across scripts |
| **KISS** (Keep It Simple) | Scripts are as simple as they could be; no abstractions that could be a one-liner |
| **YAGNI** (You Ain't Gonna Need It) | No unused flags, config options, or features not yet needed |
| **Composition over commands** | Complex operations built from smaller composable units, not monolithic multi-step scripts |
| **CoC** (Convention over Configuration) | Conventions established and followed; explicit config only where necessary |
| **Separation of concerns** | Config vs. logic, data vs. behavior, CLI vs. agent, state vs. judgment — each in its place |
| **Context efficiency** (AI-native repos) | Always-loaded files are lean; skills have tight activation; no content duplication across imports |

Questions to answer:
- Find the 3 most significant violations. Name them as `file:line: problem. fix.`
- Is there structural complexity that compounds failure (shared mutable state, side-effects in unexpected places)?
- Does the complexity of the codebase match the complexity of the problem it solves?
- Is the separation of concerns clean, or do concerns bleed into each other?

**Rate**: Clean / Acceptable / Needs Work

---

## Report Format

Use this structure exactly. Omit sections that aren't applicable. After composing the report, ensure `critique/` exists and write the same report to `critique/canon-critique.md`, replacing the prior contents so the file is the latest critique snapshot.

The first line must always be the local DateTime when the audit ran, formatted as `MM-DD-YYYY hh:mm AM/PM`:

`Audit run: MM-DD-YYYY hh:mm AM/PM`

```
Audit run: MM-DD-YYYY hh:mm AM/PM

## Repo Audit: <repo-name>

### 1. Uniqueness / Selling Point — [Distinct | Murky | Generic]
- <finding>
- <finding>
Recommendation: <one actionable sentence>

### 2. Philosophy Coherence — [Strong | Drifting | Contradicted]
Stated philosophy: <extract — quote or paraphrase from source file>
- <specific example of coherence or drift>
- <specific example of coherence or drift>
Recommendation: <one actionable sentence>

### 3. Docs Effectiveness — [Clear | Gaps | Broken]
Zero-to-working: <yes/no + rough step count or time estimate>
- <specific friction point or win>
- <specific friction point or win>
Recommendation: <one actionable sentence>
Note: per-claim accuracy → run doc-audit

### 4. Codebase Quality — [Clean | Acceptable | Needs Work]
- file:line: problem. fix.
- file:line: problem. fix.
- file:line: problem. fix.
Recommendation: <one actionable sentence>

### Summary
Overall: [Healthy | Minor gaps | Needs attention]
Top priority: <the one thing to address first, and why>
```
