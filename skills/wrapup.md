---
name: wrapup
description: Run code-simplifier, code-reviewer, and security-review in the right order after completing any unit of work — skips steps that don't apply
category: dev
tags: [code-quality, workflow, orchestration, refactoring, security]
depends: [code-simplifier, code-reviewer, security-review, handoff, ticket]
---
@./code-simplifier.md
@./code-reviewer.md
@./security-review.md
@../tools/handoff.md
@../tools/ticket.md

# Wrapup — Quality Pipeline

Run this after completing any unit of work — a session, a feature, a bug fix, or a ticket. It executes three steps in sequence, skipping any that don't apply to the current change.

## How to Run

```
/wrapup
```

Or: "Wrapup the changes" / "Wrapup the auth refactor" / "Wrapup ticket nw-42."

## Pipeline

```
code-simplifier → code-reviewer → security-review
```

Each step builds on the last:
- **Simplify first** — review clean code, not messy code
- **Review second** — catch logic and design issues on the simplified version
- **Security last** — focused pass with no style noise in the way

## Skip Logic

Before running each step, assess the change and skip if the criteria apply. When skipping, state why in one line.

### Skip code-simplifier if:
- Change is a single line or a trivial rename
- Change is docs, comments, or config only

### Skip code-reviewer if:
- Change is a single-line fix with no design implications
- Change is purely mechanical (rename, format, move file)

### Skip security-review if:
- No security-sensitive files or patterns changed
- Security-sensitive means: authentication, authorization, DB queries, user input handling, file I/O, API endpoints, crypto, session management, environment/secret access

---

## Step 1 — Code Simplifier

Simplify and refine recently modified code for clarity, consistency, and maintainability without changing behavior.

**Preserve functionality** — never change what the code does, only how it does it.

**Enhance clarity:**
- Reduce unnecessary nesting and complexity
- Eliminate redundant code and abstractions
- Improve variable and function names
- Consolidate related logic
- Remove comments that describe obvious code
- No nested ternaries — use `if/else` or `switch` instead
- Explicit over compact — a clear longer line beats a dense one-liner

**Do not:**
- Sacrifice readability for fewer lines
- Create clever solutions that are hard to follow
- Merge unrelated concerns into one function
- Remove abstractions that genuinely aid organization

**Scope** — only refine code touched in the current session unless explicitly asked otherwise.

**Process:**
1. Identify recently modified sections.
2. Analyze for clarity, consistency, and redundancy.
3. Apply project standards from CLAUDE.md / AGENTS.md.
4. Verify behavior is unchanged.
5. Note only changes that meaningfully affect understanding.

---

## Step 2 — Code Reviewer

Review the simplified code across seven dimensions.

**Seven Dimensions:**
1. **Correctness** — does the code fulfill its purpose without logical errors?
2. **Maintainability** — is the structure clean, modular, and pattern-consistent?
3. **Readability** — are naming, comments, and formatting clear?
4. **Efficiency** — any performance bottlenecks or unnecessary resource use?
5. **Security** — any vulnerabilities or unsafe practices? (defer details to Step 3)
6. **Edge cases** — are errors and unexpected inputs handled?
7. **Test coverage** — are tests adequate? What's missing?

**Report format:**
```
## Critical
Issues that must be fixed before merge.

## Improvements
Meaningful changes worth making.

## Nitpicks
Minor style or preference notes (optional to act on).

## Recommendations
Broader suggestions — refactors, missing tests, follow-up work.
```

Tone: constructive, professional, specific. Explain why, not just what.

---

## Step 3 — Security Review

Identify exploitable vulnerabilities. Report only high-confidence findings — skip theoretical issues and framework-mitigated patterns.

**Confidence threshold:**

| Level | Criteria | Action |
|---|---|---|
| HIGH | Vulnerable pattern + attacker-controlled input confirmed | Report with severity |
| MEDIUM | Vulnerable pattern, input source unclear | Note as "Needs verification" |
| LOW | Theoretical or best-practice only | Do not report |

**Do not flag:** test files, dead/commented-out code, constants, server-controlled config, code paths requiring prior authentication, Django settings / env vars / framework constants.

**Process:**
1. Trace data flow end-to-end before flagging anything.
2. Confirm attacker-controlled input reaches the vulnerable pattern.
3. Check for validation, sanitization, or framework mitigations.
4. Only then report — with exploitability evidence, not pattern matches alone.

**Vulnerability categories:** injection, XSS, authorization bypass, weak cryptography, unsafe deserialization, SSRF, CSRF, file security, broken authentication, business logic flaws, API security, misconfiguration, error handling leaks, sensitive data in logs.

**Severity:**
- **Critical** — direct exploit, severe impact, no auth required
- **High** — exploitable with some conditions, significant impact
- **Medium** — requires specific conditions, moderate impact
- **Low** — defense-in-depth gap, minimal direct impact

**Report format:**
```
## Findings

### [SEVERITY] Title
- **Location**: file:line
- **Pattern**: what the vulnerable code does
- **Evidence**: why attacker input reaches it
- **Impact**: what an attacker can do
- **Fix**: concrete remediation

## Needs Verification
Issues where input source is unclear — flag for human review.

## Out of Scope
Patterns reviewed and ruled out (briefly, to show coverage).
```

---

## Final Output

```
## Wrapup Report — <description of work>

### Changes
| File | What changed | Impact | Flags |
|------|-------------|--------|-------|
| path/to/file.ext | one-line description | HIGH / MEDIUM / LOW | ✓ clean / ⚠ see below |

### code-simplifier
- <what was simplified and where>

### code-reviewer
- [Critical] ...
- [Improvement] ...

### security-review
- [High] ...
```

**Changes table columns:**
- **File** — relative path
- **What changed** — one line: what the code now does differently
- **Impact** — carry forward the rating from `blueprint.md ## Impact Assessment`; use LOW if no sprint context
- **Flags** — `✓ clean` if no findings; `⚠ critical` / `⚠ improvement` if the pipeline flagged anything for that file

Address criticals before committing. Improvements and nitpicks at your discretion.

If you ran `/wrapup` directly (not via the approve workflow) and a ticket is in-progress, use the approve workflow to close it — do not call `tkt close` directly.

---

> **Migrating from `polish`?** If your project has `polish` registered, update it:
> ```bash
> skills.sh remove polish && skills.sh add wrapup
> ```
