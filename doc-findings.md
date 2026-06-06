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

### 2026-06-03 — Wrapup pipeline described as three passes, not five
**File:** `guides/AI-Agents-Setup.md`, `guides/context-optimization.md`
**Claim:** "runs all three in order"; SHIP block and dep list omit `repo-check` and `doc-audit`.
**Issue:** Wrapup pipeline is five steps (`code-simplifier → code-reviewer → security-review → repo-check → doc-audit`) per `wrapup.md` and the README mermaid. Guides predated the last two.
**Action:** Updated both guides to five steps (SHIP block, Layer 5, skip table, dep list). Fixed in `b480735`.

### 2026-06-03 — Wrong sprint-complete trigger phrase
**File:** `guides/AI-Agents-Setup.md`
**Claim:** "sprint complete: *sprint complete*, *approve*, *ship it*"
**Issue:** `"approve"` is the sprint-start approval, not a complete trigger; `sprint.md` lists *sprint complete* / *complete the sprint* / *ship it*.
**Action:** Replaced `"approve"` with `"complete the sprint"`. Fixed in `b480735`.

### 2026-06-03 — $SKILLS used before definition
**File:** `guides/AI-Agents-Setup.md`
**Claim:** Step 2 main path `cd ~/Developer/canon && ./skills.sh init`; Step 3+ uses `$SKILLS/skills.sh …`.
**Issue:** Primary setup path never exports `$SKILLS`, so subsequent `$SKILLS/...` commands don't run as written.
**Action:** Step 2 now defines `export SKILLS=~/Developer/canon` before later steps use it. Fixed in `b480735`.

### 2026-06-03 — CONTRIBUTING claimed CI enforcement that doesn't exist
**File:** `CONTRIBUTING.md`
**Claim:** "`skills.sh lint` runs in CI via `npm test`, so non-conforming skills are caught before merge."
**Issue:** No CI is configured yet (tracked as a future step); the claim overstates automation.
**Action:** Reworded to "runs as part of `npm test`, so running the suite catches non-conforming skills before they merge." Caught during the wrapup that added the linter.
