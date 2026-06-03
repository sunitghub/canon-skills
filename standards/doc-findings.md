---
name: doc-findings
description: Running evidence log of documentation accuracy findings — overstated claims caught, fixed, and open items.
category: agent-ops
tags: [docs, accuracy, audit]
hidden: true
---

# Doc Findings

Evidence log for documentation accuracy. Run `/doc-audit` to generate new findings. Append only on explicit confirmation.

---

### 2026-05-23 — "Columns update in real time" — no polling in sprint-check
**File:** `README.md`
**Claim:** "Columns update in real time."
**Issue:** sprint-check has no polling, EventSource, or setInterval — it loads once.
**Action:** Removed the claim.

### 2026-05-23 — Team propagation overstated
**File:** `README.md`
**Claim:** "Update it once, every teammate picks it up on the next session start. No coordination required."
**Issue:** Requires a team fork and `git pull` — not automatic.
**Action:** Reworded to specify fork requirement and `git pull`.

### 2026-05-23 — $SKILLS undefined in hero code block
**File:** `README.md`
**Claim:** `$SKILLS/skills.sh add sprint`
**Issue:** `$SKILLS` is never defined for the reader at that point.
**Action:** Replaced with `~/Developer/canon/skills.sh add sprint`.

### 2026-05-23 — code-reviewer dimensions count vs list mismatch
**File:** `README.md`
**Claim:** "Structured review across 7 dimensions: correctness, maintainability, security, edge cases, coverage."
**Issue:** Claims 7, lists 5. Missing: readability, efficiency.
**Action:** Listed all 7 dimensions explicitly.

### 2026-05-23 — brew install rtk as upfront prerequisite
**File:** `guides/AI-Agents-Setup.md`
**Claim:** Prominent callout with `brew install rtk` / `cargo install rtk` as a setup step.
**Issue:** RTK is optional — presenting it as a setup step implies it's required.
**Action:** Replaced with "wired automatically if already installed."

### 2026-06-03 — Release checklist omitted core tests
**File:** `CONTRIBUTING.md`
**Claim:** Release checklist went from standards updates directly to committing/tagging/publishing.
**Issue:** `npm test` now verifies the core CLI workflow; publishing docs should require running it.
**Action:** Added `npm test` before the release commit step.
