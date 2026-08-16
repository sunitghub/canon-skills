---
title: Agentic App Playbook
description: Practices, patterns, and steps for building grounded agentic apps — language-agnostic, living checklist
updated: 2026-08-16
---

# Agentic App Playbook

A living checklist of the patterns and practices we follow when building a **grounded agentic app** — an app where an LLM agent answers questions or takes actions over real data or a knowledge base (diagnostics, analytics, root-cause, retrieval, decision support), like `overtone-app`. Follow it when building any future such app; append to it as we learn.

It is language-agnostic (Python, TypeScript, shell — anything). Each item is a check you can hold your build against. Where canon already gives you a practice for free, a `canon:` note says how — canon is the harness you `sprint` these apps in, so its own mechanics live in canon's docs, not here.

---

## The One Idea

> Requirements define intent. Code — and the data — define reality. The gap between them is where hallucination lives.

Everything below follows from that. An agent that answers from the spec instead of the data, or reviews the diff instead of the running system, reports success confidently while being wrong.

---

## 1. Architecture & Composition

- [ ] **One agent, one job.** An agent that does two things is two agents waiting to be separated. Compose focused agents; don't build one that plans, retrieves, reasons, and writes in a single shot.
- [ ] **Compose from tools + context + prompts — not inheritance.** What it can do (tools), what it knows (context), what it's told (prompt). Resist a base-agent class; the composition is the design.
- [ ] **Scope tools to the task.** A 40-tool agent reasons worse than a 6-tool one. Give each agent only the tools its job needs.
- [ ] **Typed, structured output.** Return a typed object (answer + citations + confidence + any recommendation), not free prose — so guardrails can validate it and callers can act on it.
- [ ] **Offline-deterministic mode.** Make the agent runnable with no API key — real tools driving a deterministic stand-in model — so behavior is testable and reproducible without spend or network.
- [ ] **One agent before a pipeline.** Multi-agent complexity compounds failure modes. Only orchestrate when a single agent genuinely can't do the job; when you do, parallelize only non-conflicting work (exploration, research, reviews), never writes.

> canon: `sprint start` classifies tier and forces a plan before code, so reaching for a multi-agent pipeline is a reviewed decision, not a default.

---

## 2. Ground the Agent — deterministic signal, agent explanation

The core pattern for an analytical agent: **the deterministic layer decides; the agent explains.** A language model is a reasoning engine, not a statistics engine.

- [ ] **Compute facts in code, not the model.** Whether a value breaches a limit, whether a move is real signal or noise, whether a check passes — code decides. The agent narrates the result and never states a number a tool didn't return.
- [ ] **Declare the domain as a schema/graph contract.** Put the entities, relationships, and candidate causes/rules in data (schema or graph), not hardcoded branches. Adding a candidate is then a data edit and the reasoning stays deterministic and auditable.
- [ ] **Localize before you explain (WHERE → WHY).** First locate and rank the signal deterministically — which entity, which measure, how far out of bounds. Only then reason about cause, and only for what was localized. Walk the WHY as a bounded loop (traverse a candidate → query real evidence → keep or kill it → repeat) with a depth cap and a cycle guard.
- [ ] **Three-valued verdicts: supported / contradicted / insufficient — never guessed.** Grade each candidate from a deterministic check. Absent evidence is explicitly *insufficient*, surfaced — not silently dropped, never rounded up to a conclusion. An agent that never returns "insufficient data" is hiding its blind spots, and that is exactly where a fluent, confident, wrong answer comes from.

> canon: the CLI/agent split is this same principle at the harness level — deterministic gates own what is structurally verifiable, the agent owns judgment.

---

## 3. Trust & Guardrails

- [ ] **Every asserted fact carries a resolvable citation.** Anchor each number and verdict to a real evidence id (a source row, a `doc:line`, a node) — and verify the citation *resolves*, not merely that a citation string is present. A plausible citation pointing nowhere is worse than none: it reads as proof.
- [ ] **Approval-gate irreversible actions.** Read before write; propose before commit. A write-back, send, deploy, or migration is *proposed*, then executed only on explicit human approval behind an access check.
- [ ] **Never over-state confidence.** An inferred cause is not a measurement — keep its confidence medium or low, and put the hedge in the answer, not buried in a field.
- [ ] **Fail loudly.** Surface ambiguity instead of silently picking one interpretation and moving on.
- [ ] **Never pass a credential in argv.** A key on the command line is visible in the process table to anything that can list processes, and **no redaction layer can reach it** — log scrubbing sees output, never arguments. Prefer handing it over on **stdin** (e.g. a client's config-from-stdin mode). An env var is acceptable but weaker: it is inherited by every child and readable from the process's own environment. A temp file is the tempting middle ground and travels worst — not because Windows lacks ACLs (NTFS has them), but because `mktemp` under POSIX-emulation layers like Git Bash sets POSIX bits without a restrictive native ACL, so "0600" does not mean there what it means on Unix. stdin is the option that keeps the secret off disk on every platform.
- [ ] **Sanitise untrusted input at the boundary.** Catch PII and unsafe inputs before they reach the model (NER + regex), not after — and never capture untrusted external content into durable memory as if it were ground truth.

> canon: the close gate refuses to ship uncited/unverified work, and `sprint`'s irreversible-action rule requires confirmation before destructive steps.

---

## 4. Partition Work — code vs. prompt

- [ ] **Partition by reliability, not exhaustion.** Code owns the structurally verifiable (does this exist, does this value breach, does the verdict start with `pass:`). Prompts own judgment (is this coherent, does this finding have evidence). Assign each upfront — don't arrive at the prompt layer by elimination.
- [ ] **Gates beat instructions.** Anything the agent must never skip belongs in the deterministic layer. A gate that blocks on a missing artifact is more reliable than an instruction to produce one. If a step keeps getting skipped, that's a harness problem, not a prompt problem.
- [ ] **Always-on vs. on-demand context.** Keep the always-loaded surface minimal; load judgment-heavy instructions only when the step needs them, so a simple task doesn't pay a complex one's context cost.

> canon: `sprint complete` is the mechanical gate; injected standards are the always-on surface; sub-skills load on demand.

---

## 5. Verify

- [ ] **Ground verification in the code and data, not the diff or the spec.** Read the current file and the running behavior — the diff biases toward its own framing, and the spec describes intent, not reality.
- [ ] **Scope review to the changed surface.** Reviewing unrelated areas dilutes signal.
- [ ] **Clean-context adversarial evaluator at close.** A fresh agent with no build history — given only the acceptance criteria and the changed files — grades each criterion independently. It can't inherit the assumption that produced the bug. This is the most reliable way to catch what the author missed.
- [ ] **Evaluate at three layers.** Deterministic (format / existence / verdict parsing; fail closed) → semantic (a clean-context grader for correctness and groundedness; run each case a few times and flag variance) → behavioral (did it call the right tools, escalate when unsure, stay in scope). Each layer catches what the others can't.
- [ ] **Black-box the tests.** Assert real end-to-end behavior (prompt in, output out). Never re-derive the expected value from the code under test, and never mirror the production logic in the assertion — state the expectation independently, or the test can't fail.
- [ ] **Route new intents on disjoint signals.** When you add a question type, make its trigger unambiguous and disjoint from the existing ones, then regression-lock the old paths — a broad keyword can silently hijack an existing flow.
- [ ] **Never promote a security boundary on mocks alone.** A credential path, sandbox, or isolation boundary must be exercised against a live provider before you trust it or reuse it elsewhere. A mock asserts whatever its author assumed, so it confirms the design you already believed — the failures that matter (a secret that still crosses the boundary, a value that never arrives on the far side, a teardown that silently no-ops) surface only against the real thing. A live run that *contradicts* your acceptance criteria is the gate working, not a setback.

> canon: `sprint complete` dispatches a fresh reviewer (advisory) and evaluator (binding) with clean context, and the evaluator's `pass:` verdict is required to close.

---

## 6. Durable State

- [ ] **Decisions outlive the session.** Record non-obvious choices and rejected alternatives — the *why*, not the *what* — where they survive a context reset.
- [ ] **Session state is handed off, not remembered.** Keep current focus, in-progress, and next-steps in a durable handoff artifact a fresh agent can reconstruct from.
- [ ] **Binary done-criteria, gated before ship.** "Done" is a checklist of verifiable conditions, not "looks good" — and something mechanical should refuse to ship while a box is unchecked.

> canon: `DECISIONS.md` (why), `HANDOFF.md` (state), `.tickets/<id>/acceptance.md` (done criteria), and the close gate enforce all three; the board's Why mode surfaces the decision behind any file.

---

## Common Failure Modes

- **Hallucinated facts.** The agent states a number the data didn't produce. Fix: compute in code; cite a resolvable id.
- **Answer from the spec, not the system.** Validating what *should* happen, not what *does*. Fix: ground validation in the actual code and data.
- **Biased self-review.** The author grades its own work and finds it good. Fix: clean-context adversarial evaluator.
- **Silent insufficiency.** The agent guesses where evidence is missing instead of saying "insufficient." Fix: three-valued verdicts.
- **A test that can't fail.** The assertion re-derives its expectation from the code it tests. Fix: state the expectation independently.
- **Routing hijack.** A new broad trigger swallows an existing prompt. Fix: disjoint signals + regression-lock.
- **Premature abstraction.** Three similar cases merged into a helper that breaks on the fourth. Fix: three similar lines beat a premature helper.
- **One agent, too many jobs.** Context collapses; later steps lose fidelity. Fix: split into focused agents with explicit handoffs.
- **Context anxiety.** As the window fills, the agent wraps up prematurely — declaring done, skipping steps. Fix: a context reset with a structured handoff, not just compaction.

---

## Living Doc

This is a checklist we grow. When a build teaches a new practice — or a failure mode we had no guard for — add it here, with a one-line `canon:` note if canon supports it. The goal: the next grounded agentic app starts from everything the last one taught us.
