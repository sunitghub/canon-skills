---
title: Production Incident Playbook
description: Five-stage response protocol for AI agent incidents in production
updated: 2026-06-21
---

# Production Incident Playbook

Most teams have a deployment plan. Almost nobody has an incident plan.

When an AI agent misbehaves in production — wrong outputs, regression in accuracy, silent failures — the difference between a two-day fix and a week of chaos is whether you have a protocol before the incident happens. This playbook gives you that protocol.

---

## The Five Stages

Each stage has a distinct goal, a tool that owns it, and a clear boundary with the next stage. Do not collapse stages — containment is not a fix.

### 1. Detect

**Goal:** Catch the failure before a user reports it.

**Tool:** Eval dashboard with automated alerting. Set thresholds on your key metrics (accuracy, refusal rate, latency, tool-call error rate). When a metric drops below threshold, the alert fires — not after a user complaint arrives, not after a human happens to check.

**What it is NOT:** Reactive monitoring. If you only know something broke because a user told you, your detection layer is absent.

### 2. Diagnose

**Goal:** Determine the root cause category — data problem, prompt problem, or model drift.

**Tool:** Distributed tracing. Pull traces for the failing conversations. Find where the output went from correct to wrong. A trace that captures intent classification, tool calls, retrieved context, reasoning chain, and guardrail checks in one view makes root cause obvious. Without traces, diagnosis is guesswork.

**Key question:** Is this a data problem (stale knowledge base, missing context), a prompt problem (behaviour changed when you didn't intend it to), or a model drift problem (new model version behaving differently)?

**What it is NOT:** Asking users to describe what went wrong.

### 3. Contain

**Goal:** Reduce blast radius before fixing anything.

**Tool:** Prompt versioning with rollback. Route affected query types to human reviewers. Roll back to the last known-good prompt version if the failure is prompt-related.

**Critical constraint:** Containment is not a fix. Rolling back a prompt stops the bleeding — it does not address the root cause. Do not close the incident at this stage.

**What it is NOT:** A hotfix pushed at 3am. Containment buys time for a proper fix.

### 4. Fix

**Goal:** Resolve the root cause correctly.

**Tool:** Test case library. Write a targeted fix and add a new test case covering this exact failure before shipping. The fix goes through your normal promotion process (test → staging → production) — not a direct prod push. If the incident exposed a gap in your eval suite, that gap must be closed as part of the fix, not as a follow-up that gets deprioritised.

**What it is NOT:** Reverting and calling it done. The revert was containment; the fix adds a test case and ships a real correction.

### 5. Prevent

**Goal:** Make the eval suite better so this class of failure is caught earlier next time.

**Tool:** Eval suite expansion. Run a retrospective: what eval coverage would have caught this before it reached production? Add those cases. The suite grows with every incident — this is compounding defence, not overhead.

**The principle:** Every incident makes your eval suite better. A system that started with 20 test cases and never has incidents isn't safer — it's less observable. Teams that treat incidents as suite expansion events end up with coverage that money can't buy: real failures, anonymised, with pass/fail criteria written by people who know what broke.

---

## Stage Summary

| Stage | Tool | What it does | What it is NOT |
|---|---|---|---|
| Detect | Eval dashboard | Automated alert when metric drops | Waiting for user reports |
| Diagnose | Distributed tracing | Find where correct → wrong | Guessing from logs |
| Contain | Prompt versioning + rollback | Reduce blast radius | The fix |
| Fix | Test case library + promotion | Targeted fix + new test case | A 3am hotfix |
| Prevent | Eval suite expansion | Close the coverage gap | Optional follow-up |

---

## Prerequisites

This playbook only works if you have:

1. **Numeric success metrics defined before launch** — you can't detect a drop if you don't have a baseline threshold.
2. **Distributed tracing wired at build time** — traces can't be retrofitted easily; they need to be part of the original instrumentation.
3. **Prompt versioning with rollback capability** — knowing which version is live is not enough; you need to be able to revert in minutes.
4. **A test case library with an owner** — a library with no owner drifts silently. Assign a human. Put test case review in the sprint.
