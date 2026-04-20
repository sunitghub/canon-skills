---
name: polish
description: Run code-simplifier, code-reviewer, and security-review in the right order after completing a task — skips steps that don't apply
category: skills
tags: [code-quality, workflow, orchestration, refactoring, security]
---

# Polish — Quality Pipeline

Run this after completing any task or closing a ticket. It executes three skills in sequence, skipping steps that don't apply to the current change.

## Getting Started

**Step 1 — Register all four skills in your project** (polish + the three it orchestrates):
```bash
for s in code-simplifier code-reviewer security-review polish; do
  ~/Developer/AI-Skills/skills.sh add $s /path/to/your/project
done
```

**Step 2 — Verify:**
```bash
~/Developer/AI-Skills/skills.sh status /path/to/your/project
```

**Step 3 — Use it after completing a task:**
- **Claude**: "Polish" or "Polish the changes for ticket nw-42."
- **Codex**: "Polish" or "Polish my changes."

The agent decides which of the three steps to run or skip based on what changed — you don't need to think about it. See **Skip Logic** below for the rules.

## Pipeline

```
code-simplifier → code-reviewer → security-review
```

Each step builds on the last:
- **Simplify first** — review clean code, not messy code
- **Review second** — catch logic and design issues on the simplified version
- **Security last** — focused pass with no style noise in the way

## Skip Logic

Before running each step, assess the change and skip if the criteria apply:

### Skip code-simplifier if:
- Change is a single line or a trivial rename
- Change is docs, comments, or config only

### Skip code-reviewer if:
- Change is a single-line fix with no design implications
- Change is purely mechanical (rename, format, move file)

### Skip security-review if:
- No security-sensitive files or patterns changed
- Security-sensitive means: authentication, authorization, DB queries, user input handling, file I/O, API endpoints, crypto, session management, environment/secret access

When skipping a step, state why in one line so the user knows it was considered, not missed.

## How to Run

Invoke after closing or completing a ticket:

```
/polish
```

Or tell the agent:
> "Polish the changes for ticket nw-42."

## Step-by-Step Scenario

**Setup**: you've just implemented a login rate-limiter (ticket `nw-42`). Changed files: `auth/rate_limiter.py`, `auth/views.py`, `tests/test_rate_limiter.py`.

---

**Step 1 — code-simplifier**

Agent scans recently modified files. Finds:
- Nested conditionals in `rate_limiter.py` that can be flattened
- A redundant dict lookup happening twice in `views.py`

Simplifies both. Functionality unchanged. Reports what changed and why.

---

**Step 2 — code-reviewer**

Agent reviews the now-simplified code across seven dimensions:

- **Correctness**: rate limit counter resets on the right boundary? ✓
- **Maintainability**: limiter is self-contained, easy to extend ✓
- **Readability**: variable names clear ✓
- **Efficiency**: Redis call happening inside a loop — flags as improvement
- **Security**: deferred to Step 3
- **Edge cases**: what if Redis is unavailable? — flags as critical
- **Tests**: happy path covered, no test for Redis failure — flags as missing

Produces a structured report: 1 critical, 1 improvement, 1 missing test.

---

**Step 3 — security-review**

`auth/` files changed → security-sensitive, not skipped.

Agent traces data flow:
- User IP → rate limit key: is IP spoofable via `X-Forwarded-For`? Checks validation. Finds no sanitization → **HIGH: IP spoofing bypasses rate limit**
- Login attempt count stored in Redis: any race condition allowing burst? Traces to atomic `INCR` → safe, not flagged

Reports 1 critical finding with location, evidence, and fix.

---

**Final output summary:**

```
## Polish Report — nw-42

### code-simplifier
- Flattened nested conditionals in rate_limiter.py:34
- Removed duplicate lookup in views.py:18

### code-reviewer
- [Critical] Redis unavailable: no fallback — auth/views.py:52
- [Improvement] Move Redis call outside loop — auth/rate_limiter.py:67
- [Missing test] Redis failure path uncovered

### security-review
- [High] X-Forwarded-For not validated — IP spoofing bypasses limiter (auth/views.py:29)
```

Address criticals before committing. Improvements and nitpicks at your discretion.

## Prerequisites

All four skills must be registered in the project:

```bash
for s in code-simplifier code-reviewer security-review polish; do
  ~/Developer/AI-Skills/skills.sh add $s /path/to/repo
done
```

Verify:
```bash
~/Developer/AI-Skills/skills.sh status
```
