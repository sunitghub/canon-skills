---
title: Agent Development Playbook
description: Portable distillation of canon's agent design knowledge — language-agnostic, self-contained
updated: 2026-06-16
---

# Agent Development Playbook

Distilled from building and iterating on canon. Language-agnostic — applies whether you're writing agents in Python, TypeScript, shell, or anything else.

---

## The One Idea

> Requirements define intent. Code defines reality. The gap between them is where hallucination lives.

Everything below follows from that. An agent that reviews the PR diff instead of the actual code, or validates requirements against a spec instead of the running system, will confidently report success while the system is broken.

---

## Agent Design Principles

**One agent, one job.** An agent that does two things is two agents waiting to be separated. Composing two focused agents is easier to debug, test, and replace than one agent doing both.

**Compose from tools + context + prompts — not inheritance.** An agent is a combination of: what it can do (tools), what it knows (context injected at session start), and what it's told to do (its prompt). Resist abstracting a base-agent class; the composition is the design.

**Request only the tools the current task needs.** Bloated tool schemas degrade reasoning. An agent with 40 available tools makes worse decisions than one with 6 relevant ones.

**Prefer reversible actions. Confirm before irreversible ones.** Read before write. Dry-run before delete. Confirm before send, publish, deploy, migrate. The cost of one extra confirmation is low; the cost of an unwanted action is high.

**Fail loudly.** Surface ambiguity rather than guessing silently. An agent that picks one interpretation of an ambiguous instruction and doesn't say so is worse than one that stops and asks.

**Solve with one agent before building a multi-agent pipeline.** Multi-agent complexity compounds failure modes. Every additional agent is another surface that can misinterpret, hallucinate, or silently drop information. Only reach for orchestration when a single agent genuinely can't do the job.

---

## Multi-Agent Orchestration Patterns

When a single agent genuinely can't do the job, these are the three patterns worth knowing. Each has a distinct trigger condition and a failure mode that trips teams who don't expect it.

### Orchestrator-Worker

**When:** Complex workflows with distinct subtasks that can be delegated — data gathering, code generation, review, summarisation — each requiring different context or tools.

**How:** One coordinator agent breaks the task down and dispatches specialist worker agents. Results bubble back to the orchestrator for synthesis.

**Failure mode:** The orchestrator becomes a bottleneck as task volume grows. Workers operate blind to each other's context — if they need to coordinate mid-task, the pattern breaks.

### Choreography

**When:** Independent subtasks where latency matters and each step can proceed without a central coordinator — parallel document processing, fan-out search, event-driven pipelines.

**How:** Multiple agents subscribe to events from a shared message bus. Each agent reacts to its event type and produces its own output independently.

**Failure mode:** Observability must be solid from day one. Without distributed tracing across agents, a silent failure in one subscriber is invisible. Things get messy fast.

### Human-in-the-Loop

**When:** Regulated environments, high-stakes decisions, or cases where the confidence threshold for autonomous action is genuinely uncertain.

**How:** The agent handles queries up to a confidence threshold and routes above it to a human reviewer.

**Failure mode:** Threshold calibration is hard and consequential in both directions. Too high: humans never see anything, defeating the purpose of the gate. Too low: humans are flooded, defeating the purpose of the agent. Calibrate with real data — don't guess.

---

## Skill Anatomy

A skill is a markdown document that tells an agent what to do when triggered. It is not code — it is structured context.

### Minimal SKILL.md structure

```markdown
---
name: skill-name
description: One sentence — what this skill does and when to invoke it.
category: dev | ops | research | ...
tags: [keyword, keyword]
depends: []       # other skills this one reads
inject: false     # true = always loaded into context
---

# Skill Name

Brief one-line summary.

## Trigger

When to use this skill: what user input or condition activates it.

## Steps

1. Step one. Be specific about what to read, what to check, what to do.
2. Step two.

## Output Format

What the agent should produce: file writes, console output, structured data.

## Gotchas

Non-obvious constraints, failure modes, or edge cases.
```

### What makes a skill good

- **One job.** If the description requires "and", split it.
- **Explicit triggers.** The agent must know without ambiguity when to invoke this skill vs. a different one.
- **Steps that reference the actual files.** "Read `tools/handoff.md`, then..." beats "review the handoff state."
- **Concrete output format.** A skill that produces unstructured prose is hard to grade and hard to compose.
- **Gotchas section.** This is where hard-won knowledge lives. If something surprised you during development, it belongs here.

---

## Eval Methodology

Evals verify that a skill produces correct output for known inputs. They catch regressions and validate new skills before deployment.

### evals.json schema

```json
{
  "skill_name": "my-skill",
  "evals": [
    {
      "id": 1,
      "case_type": "control | compliance | boundary | over-caution",
      "prompt": "The exact input that triggers the skill",
      "expected_output": "Human-readable description of correct output",
      "expectations": [
        "Specific, binary-graded assertion about the output",
        "Another assertion"
      ]
    }
  ]
}
```

### Case types

| Type | Purpose |
|---|---|
| `control` | Happy path — skill should succeed cleanly |
| `compliance` | Tests that the skill follows a specific rule |
| `boundary` | Edge case — input near the boundary of what the skill handles |
| `over-caution` | Tests that the skill doesn't flag false positives |

Every skill needs at least one `control` and one `compliance` case. Add `boundary` and `over-caution` cases as you discover failure modes.

### Executor + Grader pattern

Run evals with two subagents in clean contexts:

1. **Executor** — gets only the skill's SKILL.md and the eval prompt. No implementation history. Reports what steps it took and what output it produced.

2. **Grader** — gets the executor's output, the `expected_output`, and the `expectations` list. Grades each expectation `pass`, `fail`, or `partial` with a one-line evidence citation.

The key is **clean context on both sides**. An evaluator that saw the implementation will be biased toward the implementation's framing — it will find ways to call things passing that aren't. A fresh context grades what actually happened.

### G-Eval criteria (for LLM-as-judge)

When writing grading criteria for LLM judges, make each criterion:
- **Binary or near-binary** — "flags the CDN URL" is gradable; "provides good advice" is not
- **Evidence-anchored** — the grader must cite which part of the output justifies the grade
- **Failure-closed** — if the evidence is absent or ambiguous, grade `fail`, not `pass`

---

## Verification Principles

These apply when an agent checks whether work is done, whether a requirement is met, or whether a change is correct.

**Read base code, not the diff.** The PR diff shows what changed, but it biases the agent toward the PR's own framing. The base code shows what actually exists. When validating that a requirement is implemented, read the current file — not the change set.

**Scope review to relevant areas.** Reviewing across unrelated surfaces introduces noise and dilutes signal. A backend-only feature change doesn't need frontend review. Explicit scoping produces sharper findings.

**Adversarial evaluator at close.** The agent that wrote the code has ~170k tokens of "I built this, so it must work" bias. A fresh agent with no implementation history — given only the acceptance criteria and the changed files — grades from an independent perspective. This is the most reliable way to catch what the author missed.

---

## Sprint Workflow

A sprint is a focused unit of work with a defined start state, done criteria, and close gate.

### Tiers

Choose the lightest tier that still protects the work:

| Tier | When | Overhead |
|---|---|---|
| **Trivial** | Single-line fix, rename, typo | No sprint — work directly |
| **Normal** | Focused reversible change | Ticket + `acceptance.md` + `plan.md` |
| **High-risk** | Auth, payments, migrations, broad blast radius | Full: orient, impact analysis, research, human checkpoint |

### Sprint files

```
.tickets/<id>/
  ticket.md        ← created by CLI
  acceptance.md    ← done criteria (binary, checkable) + test plan
  plan.md          ← files to touch, approach, decisions, tier reason
  eval-report.md   ← adversarial grader output at close
  summary.md       ← plan-vs-actual table at close
```

### Acceptance criteria rules

- Each criterion must be binary: either it's met or it isn't
- No "the code looks good" or "it seems to work" — specific, verifiable conditions only
- Include a test plan with concrete commands and expected outcomes
- The close gate should refuse to proceed while any box is unchecked

### Durable state files

| File | Purpose |
|---|---|
| `DECISIONS.md` | Non-obvious architectural choices, explicit tradeoffs. The WHY, not the what. |
| `HANDOFF.md` | Current focus, what's in progress, what's next. Refreshed every session. |
| `AGENTS.md` / `CLAUDE.md` | Agent instructions: conventions, non-obvious file relationships, gotchas |

### Memory hygiene

Prefer many small focused memory files over few large ones. A file that covers one concern (a user preference, a single project constraint, a reference pointer) stays relevant across sessions. A file that covers everything becomes noise — the agent reads it all to get the one sentence it needs, and that cost compounds across every future turn.

`user` and `feedback` memories are reference material: they describe stable facts about the user or confirmed behavioral patterns. Update them deliberately — when a preference demonstrably changed or feedback was explicitly confirmed — not reflexively mid-sprint. `project` and `reference` memories are more likely to need in-session updates.

Do not capture content derived from untrusted external sources (fetched web pages, third-party tool output, user-supplied content from outside the codebase) into memory. Captured content becomes trusted ground truth for all future sessions — a prompt injection in a web fetch that gets captured will be treated as fact by every agent that reads the memory store afterward.

---

## Prompt Engineering Patterns

### Ground agents in the code, not the spec

When asking an agent to validate a feature, point it at the code that implements the feature — not the ticket that described it. Requirements drift; code is the truth of what the system does.

### Give subagents clean context

Subagents inherit the biases of whoever briefed them. When you need independent judgment — evaluation, adversarial review, verification — spawn the subagent with only what it needs to do the job: the acceptance criteria, the relevant files, and the task. No implementation history.

```
# Good subagent brief
Read acceptance.md and the files listed in plan.md.
Grade each acceptance criterion: met / not met / uncertain.
Cite evidence for each.

# Bad subagent brief
Based on what we just built, verify it's working.
```

### State the output format explicitly

Agents produce better output when the format is specified upfront. A grader given a rubric produces structured findings; a grader asked to "assess quality" produces prose. Structured output is easier to parse, grade, and act on.

### Scope tool access to the task

An agent asked to review code doesn't need write access. An agent asked to generate a report doesn't need deployment tools. Narrow tool schemas produce more focused reasoning.

---

## Harness Architecture

A common framing: *extract deterministic actions as rule-based code helpers for token efficiency; when you've exhausted rule-based possibilities, move to the system prompt.* This is a useful starting point but stops short of describing a mature harness.

The problem with "exhaustion" framing is that it treats the prompt layer as a fallback — what you reach for when code runs out. In practice, both layers are first-class and should be designed simultaneously. The decision isn't "have we run out of rules?" — it's "which layer handles this more reliably?"

**Three principles for a well-architected harness:**

**1. Partition by reliability, not exhaustion.**
Code owns what is structurally verifiable — does this file exist, does this checkbox have content, does the verdict line start with `pass:`. Prompts own what requires judgment — is this plan coherent, does this finding have evidence, is this change high-risk. Assign upfront; don't arrive at the prompt layer by elimination.

**2. Gates beat instructions.**
Anything the agent should never skip belongs in the deterministic layer. A CLI gate that blocks close without a verified file is more reliable than any instruction telling the agent to write one. Instructions set intent; gates enforce it. If a step keeps getting skipped, that's a harness problem, not a prompt problem.

**3. The prompt layer has its own efficiency architecture.**
The split between code and prompt is the first partitioning decision. Within the prompt layer, a second decision applies: what is always loaded vs. loaded on demand. Always-on context is a fixed cost paid every turn regardless of the task. On-demand loading makes that cost proportional — a simple task doesn't pay for the context a complex one needs. A harness that nails the code/prompt split but ignores this will still accumulate bloat as skills grow.

The corrected framing: **design the layers simultaneously. Assign work to whichever layer handles it more reliably. Within the prompt layer, keep the always-on surface minimal and load judgment-heavy instructions only when the step needs them.**

**Three evaluation layers.** A mature harness evaluates at three levels:

- **L1 — Deterministic**: CLI gates and rule-based checks. Format validation, PII detection (NER + regex), output length bounds, file existence checks, `^pass:` anchored verdict parsing. Fail closed on structural gaps. Fast, cheap, run first.
- **L2 — Semantic**: An evaluator subagent launched with clean context and a grading rubric. Correctness, groundedness, safety. Catches what structure cannot verify: fabricated evidence that satisfies a checkbox, a plan that is internally consistent but wrong, a security finding with no supporting file path. Non-determinism fix: run each test case 3× and flag variance above threshold rather than accepting a single pass.
- **L3 — Behavioural**: Did the agent call the right tools in the right order? Did it escalate when confidence was low? Did it stay within scope? Requires replaying full agent runs — expensive at scale. Budget for L3 coverage early; retrofitting it after you have hundreds of test cases is the wrong order.

All three layers are necessary and complementary. L1 enforces structure reliably. L2 catches quality failures that pass structural checks. L3 catches orchestration failures that semantic grading can't see. Treating any one as "real" evaluation misses the others' failure surface.

---

## Common Failure Modes

**Hallucinating implementation details.** The agent validates that a feature *should* work based on the spec, not that it *does* work based on the code. Fix: ground validation in the actual files.

**Biased evaluation.** The agent that wrote the code reviews its own work and finds it satisfactory. Fix: adversarial subagent with clean context.

**Premature abstraction.** Three similar cases get merged into a helper before the pattern is clear. The abstraction breaks on the fourth case. Fix: three similar lines beats a premature helper.

**Scope creep in review.** The agent flags issues across unrelated surfaces. Findings multiply; signal is buried in noise. Fix: explicit scope restriction at the start of review.

**One agent, too many jobs.** The agent is asked to plan, implement, test, review, and document in one shot. Context collapses; later steps lose fidelity. Fix: split into focused agents with explicit handoffs.

**Silent failure.** The agent encounters ambiguity and picks one interpretation without disclosing it. The user discovers the wrong choice was made after it's been built. Fix: fail loudly — surface the ambiguity and ask.

---

## Starting a New Project

Minimum viable setup for a new agent project:

```
project/
  CLAUDE.md          ← agent instructions (conventions, gotchas, non-obvious rules)
  AGENTS.md          ← active skills table + workflow notes
  standards/
    efficiency.md    ← code quality, git conventions, agent design rules
  skills/
    my-skill/
      SKILL.md
      evals/
        evals.json
  .tickets/          ← sprint tickets (optionally gitignored)
  DECISIONS.md       ← durable architectural choices
  HANDOFF.md         ← current session state
```

See `canon/starters/` for copy-paste templates for each file.

The `standards/efficiency.md` file should be marked `inject: true` (or equivalent in your harness) so it's always in context without being explicitly invoked.

---

## What to Put Where

| Information type | Home |
|---|---|
| How to do a specific task | Skill SKILL.md |
| Project-wide conventions | CLAUDE.md / AGENTS.md |
| Code quality rules | standards/efficiency.md |
| Why a design decision was made | DECISIONS.md |
| What's in progress right now | HANDOFF.md |
| Done criteria for current work | .tickets/<id>/acceptance.md |
| Approach for current work | .tickets/<id>/plan.md |
