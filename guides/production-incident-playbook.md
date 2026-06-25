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

Each stage has a distinct goal, a tool that owns it, and a clear boundary with the next stage. Do not collapse stages — isolation is not a resolution.

### 1. Surface

**Goal:** Catch the failure before a user reports it.

**Tool:** Signal monitor with automated alerting. Set thresholds on your key metrics (accuracy, refusal rate, latency, tool-call error rate). When a metric drops below threshold, the alert fires — not after a user complaint arrives, not after a human happens to check. (Requires the signal monitor prerequisite — see [Prerequisites](#prerequisites) below.)

**What it is NOT:** Reactive monitoring. If you only know something broke because a user told you, your signal layer is absent.

### 2. Trace

**Goal:** Determine the root cause category — data problem, prompt problem, or model drift.

**Tool:** Conversation tracer. Pull traces for the failing conversations. Find where the output went from correct to wrong. A tracer that captures intent classification, tool calls, retrieved context, reasoning chain, and guardrail checks in one view makes root cause obvious. Without it, investigation is guesswork.

**Key question:** Is this a data problem (stale knowledge base, missing context), a prompt problem (behaviour changed when you didn't intend it to), or a model drift problem (new model version behaving differently)?

**What it is NOT:** Asking users to describe what went wrong.

### 3. Isolate

**Goal:** Reduce blast radius before resolving anything.

**Tool:** Prompt rollback. Route affected query types to human reviewers. Revert to the last known-good prompt version if the failure is prompt-related.

**Critical constraint:** Isolation is not a resolution. Rolling back a prompt stops the bleeding — it does not address the root cause. Do not close the incident at this stage.

**What it is NOT:** A hotfix pushed at 3am. Isolation buys time for a proper resolution.

### 4. Resolve

**Goal:** Fix the root cause correctly.

**Tool:** Failure registry. Write a targeted fix and add a new entry covering this exact failure before shipping. The fix goes through your normal promotion process (test → staging → production) — not an unreviewed direct prod push. If the incident exposed a gap in your eval suite, that gap must be closed as part of the resolution, not as a follow-up that gets deprioritised.

**What it is NOT:** Reverting and calling it done. The revert was isolation; resolution adds a test case and ships a real correction.

### 5. Harden

**Goal:** Make the eval suite better so this class of failure is caught earlier next time.

**Tool:** Coverage retrospective. Ask: what eval coverage would have caught this before it reached production? Add those cases. The suite grows with every incident — this is compounding defence, not overhead.

**The principle:** Every incident makes your eval suite stronger. A system that started with 20 test cases and never has incidents isn't safer — it's less observable. Teams that treat incidents as suite expansion events end up with coverage that money can't buy: real failures, anonymised, with pass/fail criteria written by people who know what broke.

---

## Stage Summary

| Stage | Tool | What it does | What it is NOT |
|---|---|---|---|
| Surface | Signal monitor | Automated alert when metric drops | Waiting for user reports |
| Trace | Conversation tracer | Find where correct → wrong | Guessing from logs |
| Isolate | Prompt rollback | Reduce blast radius | The resolution |
| Resolve | Failure registry + promotion | Targeted fix + new failure entry | A 3am hotfix |
| Harden | Coverage retrospective | Close the coverage gap | Optional follow-up |

---

## Prerequisites

This playbook only works if you have:

1. **Numeric success metrics defined before launch** — you can't surface a drop if you don't have a baseline threshold.
2. **Conversation tracer wired at build time** — tracing can't be retrofitted easily; it needs to be part of the original instrumentation.
3. **Prompt rollback capability** — knowing which version is live is not enough; you need to be able to revert in minutes.
4. **A failure registry with an owner** — a registry with no owner drifts silently. Assign a human. Put registry review in the sprint.
