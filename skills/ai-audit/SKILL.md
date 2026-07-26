---
name: ai-audit
description: Audits an AI/LLM codebase across nine surfaces using the SCAN method and returns a ship/conditional/hold verdict. Use when asked to review, audit, or security-check an AI agent, LLM app, RAG pipeline, or prompt/tool-calling system for AI-specific risks. Static analysis only.
category: agent-ops
tags: [audit, ai, llm, security, agents]
---

# AI Audit

Static audit of an AI/LLM codebase across nine AI-specific surfaces, producing a
`ship | conditional | hold` verdict. Human-facing name: **AI System Audit**.

A **composition overlay**, not a replacement. It delegates general vulnerabilities to
`security-review` (`skills/wrapup/gates/security-review.md`) and does not re-implement `repo-audit`
(code quality), `doc-audit` (doc accuracy), or `context-check` (context load). It adds the nine
AI-specific surfaces those skills don't cover.

## When to use

Triggers: "audit this AI agent", "review our LLM app for security", "is this RAG pipeline safe to
ship", "check our prompt/tool-calling code". Not for general repo health (`repo-audit`), a single
sprint diff (sprint's own `review`/`eval` gates), or governance/compliance sign-off (out of scope —
see below).

## Operating constraints

- **Static analysis only.** Read the code. **Never run the system, call the model API, or execute
  the agent.** No dynamic probing.
- **Evidence, not theory.** Report a finding only at **HIGH or MEDIUM confidence** — an identified
  sink plus a plausible attacker-controlled (or unbounded) path. Do not flag worst-case speculation.
  Same bar as `security-review`.
- **No numeric score.** A single number hides which surface is weak. Report per-surface ratings and
  one verdict, never a percentage or grade.
- **No OWASP `LLMxx` numbering** in the report. Use the canon surface names below. (The mapping
  exists for the auditor's reference only.)
- **Input is a directory or a file list**, not a single file — AI systems span prompt templates,
  tool/function definitions, agent orchestration, retrieval/RAG config, and deployment manifests.

## SCAN

Apply four phases in order:

1. **Scope.** Define the system boundary before checking anything: what the AI does, which tools it
   can call, what data it reads/writes, and what trust/permissions it's granted. List the files that
   make up each (prompts, tool defs, orchestration, retrieval config, deploy manifests). If the
   target has no LLM/agent code at all, say so and stop with a limited-scope note — do not invent
   AI findings for a non-AI repo.
2. **Check.** Evaluate each of the nine surfaces below against its risk patterns. Classify every
   finding as **blocking**, **conditional**, or **advisory**. Cite `file:line` for each.
3. **Anchor.** Map findings to the highest-leverage fix points — the single change that removes the
   most risk (e.g. one output-sanitization boundary covering many sinks). Group findings by fix,
   not just by surface.
4. **Note.** Produce the verdict with rationale, and surface any gap that needs a human decision
   before shipping (including the out-of-scope items below).

## The nine surfaces

Priority reflects severity × how reviewable it is in static code. Check P0 first.

### P0 — check first

**`input-trust`** — all untrusted input reaching the model: user prompts, retrieved documents, tool
outputs, agent-to-agent messages, file/email/web content.
- Check: is retrieved/tool/third-party content concatenated into a prompt without a trust boundary
  or delimiting? Are system and user roles separated? Is there any indirect-injection path (RAG doc
  or tool output that can carry instructions)?
- Blocking if: attacker-controllable text reaches the prompt with no separation and the model's
  output drives a privileged action.

**`agency-scope`** — how much the model can do autonomously: tool permissions, action scope,
human-in-the-loop gates, irreversibility controls.
- Check: read the tool/function definitions. Are destructive/irreversible tools (delete, send,
  pay, deploy, write) gated by a human confirmation or a scope limit? Is tool access least-privilege,
  or does the agent hold broad credentials? Can one model turn chain multiple state-changing calls?
- Blocking if: the model can trigger an irreversible/external-effect action with no human gate and
  no scope bound.

**`secret-surface`** — what the model can expose: system prompts, PII, credentials, internal config.
- Check: are system prompts / keys hardcoded where the model or logs can echo them? Are prompts and
  completions logged or cached with secrets/PII in them? Is there an instruction that assumes the
  system prompt is confidential (it is not — treat as extractable)?
- Blocking if: a credential or PII is reachable in a context window, log, or cache the model or an
  external caller can read.

### P1

**`output-handling`** — LLM output passed to downstream systems, shells, `eval`, DB, or a UI.
- Check: is model output used unsanitized in a shell command, SQL string, `eval`/`exec`, file path,
  or rendered as HTML/markdown without escaping? Are model-proposed actions validated before
  execution?
- Blocking if: model output reaches a code/command/markup sink with no validation or escaping.

**`resource-control`** — token budgets, rate limits, retry caps, cost alerts, per-feature spend.
- Check: are there max-token / max-turn / timeout bounds on model calls? Rate limiting on
  user-facing endpoints? A cost/quota guard or alert? Unbounded loops that call the model?
- Blocking if: a user-reachable path can drive unbounded model calls/tokens with no cap (DoS / cost
  runaway).

**`retry-idempotency`** — retry logic and state-changing tool calls.
- Check: are retries bounded with backoff? Is transient-vs-semantic failure routed differently (a
  bad-output retry shouldn't hammer)? Are state-changing tool calls idempotent / deduplicated so a
  retry doesn't double-execute? Is there a hard stop to human review on repeated failure?
- Blocking if: a retried state-changing call can double-execute, or retries are unbounded.

### P2 — read-and-reason (config understanding, not just grep)

**`data-integrity`** — provenance and access control of everything that feeds the model: RAG
sources, embedding stores, fine-tune/training data, model artifacts, dependencies. (Collapses
supply-chain + poisoning + RAG/embeddings — one fix space.)
- Check: are RAG sources validated/trusted, or can any writer inject retrievable content? Is the
  embedding/vector store access-controlled? Are model artifacts and AI dependencies pinned and from
  a trusted source?
- Blocking if: untrusted writers can insert content that is later retrieved into a prompt, or model
  artifacts load from an unpinned/untrusted source.

**`observability`** — can you see what the system did? structured logging, tracing, cost dashboards,
quality-drift detection, incident classification.
- Check: are prompts/completions/tool calls logged in a structured, traceable way (without leaking
  secrets — cross-check `secret-surface`)? Is there cost/latency instrumentation? Any drift or
  quality monitoring?
- Advisory/conditional (rarely blocking): absent observability is a ship risk, not usually an
  exploit — rate conditional when an incident would be undiagnosable.

**`deployment-gates`** — feature flags, canary/staged rollout, rollback paths (prompt, model,
retrieval config), post-launch review.
- Check: can a prompt/model/retrieval-config change be rolled back without a redeploy? Is there a
  flag/canary for risky AI features? Is there a post-launch review path?
- Conditional if: no rollback path exists for the prompt/model/config that most affects behavior.

## Delegation and out of scope

- **Delegate** general vulnerabilities (injection, auth, SSRF, deserialization, hardcoded secrets in
  non-AI code) to `security-review` — reference its findings; do not re-run or duplicate them.
- **Out of scope — report as human-review items, never as code findings or a fabricated pass:**
  - **Governance / policy** (accountability, EU AI Act, model cards, decommissioning) — not
    inferable from code.
  - **Fairness / bias** — requires training data and output distribution analysis, not code review.

  Name these in the Note as "requires human review" so their absence isn't mistaken for a clean pass.

## Verdict

| Verdict | Criteria |
|---|---|
| **ship** | No blocking findings on any surface. Advisory/conditional items documented and triaged. |
| **conditional** | One or more blocking findings, but each has a concrete, scoped fix. Safe to ship once the fixes are verified. |
| **hold** | Blocking findings whose fix needs an architectural change, an external dependency, or a human governance decision first. |

Any surface with an unresolved **blocking** finding forces at least **conditional**; a blocking
finding with no scoped fix forces **hold**.

## Report

Write the report inline and to `critique/ai-audit.md` in the audited repo (create `critique/` if
absent), with the run DateTime as the first line. Match `repo-audit`'s shape, plus a **`file:line`
evidence path on every finding** — AI findings are non-obvious and the evidence link is what makes
them trustworthy.

```
AI audit run: MM-DD-YYYY hh:mm AM/PM

## AI Audit: <repo-name>
Scope: <what the AI does; files/areas reviewed>

### <surface-name> — [pass | conditional | blocking] (P0|P1|P2)
- file:line — <finding>. <why it matters>. [blocking|conditional|advisory]
Recommendation: <one actionable sentence, anchored to the highest-leverage fix>

<... one section per surface actually in scope ...>

### Out of scope (human review)
- Governance/policy: <not assessed — why>
- Fairness/bias: <not assessed — why>

### Summary
Delegated to security-review: <verdict/pointer, or "not run">
Top priority: <the one fix to make first, and why>

ai-audit verdict: ship | conditional | hold
```

Omit surface sections that don't apply to the target (say which and why in Scope). The final
`ai-audit verdict:` line is required.

## Gotchas

- **Non-AI repo:** if there's no model/agent code, do not manufacture findings — report a
  limited-scope Scope note and stop. A clean small surface is a real result.
- **Theoretical risk is not a finding.** No identified sink + plausible path → don't report it.
  This skill's credibility is the HIGH/MEDIUM bar.
- **Don't double-count with `security-review`.** A generic hardcoded secret is its finding;
  `secret-surface` is specifically about what the *model/prompt/context* can expose.
- **Observability/deployment-gates rarely block.** Their absence is usually a ship *risk*
  (conditional), not an exploit — don't inflate to blocking without an incident-impact argument.
- **No score, no OWASP numbers.** If you're tempted to write "8/10" or "LLM01", stop — use surface
  names and the three-tier verdict.
