---
title: When canon uses subagents
description: Where canon dispatches subagents, where it keeps work in the main loop, and how that lines up with Anthropic's "fold subagents into your main agent loop" guidance
updated: 2026-11-19
---

# When canon uses subagents

Source compared: Diane Sarkis, *Building agents: When to fold subagents into your main agent loop*
(claude.com/resources/articles/building-agents-when-to-fold-subagents-into-your-main-agent-loop, 2026-10-22).

## Article summary

**Main point:** default to one model, one context window and one tool loop. Many teams split work into
subagents that mirror the org chart: a router, a planner, and a specialist per team or problem type. That
usually makes quality worse and adds cost and delay. Folding them back into the main loop, and loading
context only when it's needed, often does better.

**Where things go when you fold a subagent:**
- **Procedure and judgment** become skills.
- **Actions, live data and hard limits** (validation, approval gates) become tools.
- **Reference material** sits behind search or lookup tools, not pasted into prompts.

**Keep a subagent only when one of these holds:**
1. The single loop measurably degrades from carrying too much context.
2. Independent tasks can run in parallel, each in a fresh window you throw away afterwards.
3. One agent picks the wrong tools (past roughly 30–50 tool definitions) or has conflicting instructions.

It also names independent verification and narrower permissions as good reasons. A good split hands the
subagent "a piece of work that needs little from the rest of the system" and gets back a compact result.
Splitting by problem type turns into a "telephone game" where each handoff loses detail.

**Costs of multi-agent setups:**
- Information lost at each handoff.
- Latency, since each subagent is a loop inside the loop.
- Hundreds of overlapping subagents with no owner.
- The "Frankenprompt": rules from many teams that contradict each other.
- Evals nobody has checked.

**How to migrate:**
1. Build a small end-to-end eval first; about 10 golden examples is enough to start.
2. As an interim step, make the subagents callable as tools that share one response format.
3. Fold one subagent at a time and run each task more than once. In one of the article's examples, a
   regression showed up in only one of two runs.
4. Compare which tasks flipped, not just the overall score.
5. Have one small central team own the system prompt and end-to-end quality.
6. Keep the tool list small with tool search and deferred loading.

**Evidence it gives:** Claude Code's system prompt for newer models shrank by over 80%. One customer saw
about 2x faster runtime with a single loop. Both are anecdotes; the article publishes no dataset.

**Its closing rule:** "Build a small end-to-end eval, fold in one subagent, and keep it as a subagent only
if the folded version scores worse."

## Where canon dispatches today

| Dispatch | Owner | Article criterion it meets | Verdict |
|---|---|---|---|
| `canon-evaluator` (binding close gate) | `skills/sprint/reference/complete.md` step 3, `agents/canon-evaluator.md` | Verification + modular permissions: no implementation history, read-only tools, writes one report | **Keep.** This is exactly the black-box verifier the article exempts. Folding it in would let the author grade their own work. |
| `canon-reviewer` (advisory close gate) | `complete.md` step 2, `agents/canon-reviewer.md` | Verification (fresh reader of the diff) | **Keep.** Measured by t-63a7: it caught a defect the evaluator likely would not have caught on 10 of 20 normal sprints. |
| `canon-spec-checker` (before plan approval) | `skills/sprint/reference/start.md` step 10, `agents/canon-spec-checker.md` | Verification of the plan by a reader with no plan-writing history | **Keep.** Same reason as the evaluator, applied to the spec. |
| `break-it` (optional, high-risk only) | `skills/sprint/reference/break-it.md` | Verification (hostile input on a history-free snapshot) | **Keep as opt-in.** It only runs where the risk pays for a third lens. |
| Parallel `Explore` research, one per subsystem | `skills/sprint/reference/orient.md` (≥ 2 independent subsystems) | Parallel, disposable work, which the article itself names as a good split ("independent research paths") | **Keep.** The trigger is already structural (no shared entry points), and the output is a citation file, not a summary. |
| `bulk-read` (large file, citation-only) | `skills/bulk-read/SKILL.md` (over a line-count threshold) | Context bloat: keeps a big file out of the main window | **Keep.** A size gate rather than a judgment call matches "measurable bloat". Under the threshold it already reads inline. |
| `skill-eval` executor + grader pairs | `complete.md` (skill-eval step), `skills/skill-eval/SKILL.md` | Verification: one fresh pair per case, dispatched from the session | **Keep.** This is the article's own eval practice. A subagent cannot start these pairs, so the session must run them. |
| `repo-workflow-audit` (4-way parallel) | `skills/repo-workflow-audit/SKILL.md` | Parallel fresh-context lenses, plus verification | **Keep.** It runs by hand and rarely. |

## Where canon already keeps work in the main loop

These match the article's "fold it" advice and should stay inline:

- **Plan creation and `grill`** run in the main session (`AGENTS.md` › Model Tiers). The model that
  writes the plan also carries it out, which is the article's single-loop design.
- **`mutation-test`** runs inline: the `mutant-sweep` tool gives each mutant its own copy and environment, so it needs no subagent (`skills/mutation-test/SKILL.md`, Isolation).
- **`security-review`** runs inline on the session model, last, on the final diff (`complete.md:37`).
- **The 8-dimension `code-reviewer`** runs inline as a cheap check (`complete.md:51`). Only the fresh
  `reviewer` is dispatched.
- **Every skill is procedure loaded into the main loop**, not an agent: "one skill, one job"
  (`CLAUDE.md` › Agent Design) is the article's "move procedure into skills".
- **Hard limits live in tools, not prompts**: `sprint gate-snapshot`, the gate scope that refuses a
  real `HOME`/`CANON_HOME`, `sprint eval-verdict`. That is the article's "approval gates and
  validation go in tools".
- **Report shape**: `skills/sprint/reference/subagent-report.md` (Result, Output, Evidence, Learnings)
  is the shared response schema the article recommends, and it keeps handoffs compact.

## Where canon and the article pull apart

1. **The `implement` tier.** `AGENTS.md` › Model Tiers lists `implement` → Haiku/Sonnet as a separate
   tier. Dispatched as a subagent inside an approved plan, that is the planner → executor handoff the
   article warns about: the executor loses the reasons behind the plan and cannot revise it mid-turn.
   **Recommendation:** read the tier as "which model the implementing session runs on", not as a
   dispatch. Dispatch implementation only for genuinely independent pieces with a clean interface.
2. **Isolation is canon's main reason; the article's is cost.** The article treats a subagent as
   something to justify against latency and lost context. Canon's gates exist for *independence* (no
   implementation history), and the north-star gate floor (`AGENTS.md`) forbids dropping the binding
   evaluator. These don't conflict: the article exempts verification. But "fold to save time" must never
   be applied to the evaluator or the spec checker.
3. **Mirrored gate prose.** Each gate doc must stand alone for a fresh reader, so canon keeps copies
   locked by `tests/doc-mirror-parity.sh` (`standards/efficiency-notes.md`). That is the price of
   isolation, and it edges toward the article's "Frankenprompt": keep the shared part in
   `shared-gate-protocol.md` and the per-gate files thin.
4. **Measurement before folding.** The article's rule is to fold one subagent, compare evals, and keep
   the subagent only if the folded version is worse. Canon has the pieces (`tools/gate-cases.sh` gate
   eval set, `.claude/subagent-runs.jsonl` with tokens and minutes per gate) but no fold experiment yet.

## Decision rule for new canon work

Before adding a dispatch, answer in order:

1. **Does the work need independence from what this session knows?** That covers grading, a spec
   check, or hostile input. → Subagent, read-only tools, one report file, snapshot before and after.
2. **Does it split into ≥ 2 pieces that need nothing from each other** and come back as citations or a
   fixed-shape result? → Parallel subagents in one message.
3. **Would it put a measured, large amount into the main window** (a file over the `bulk-read`
   threshold, a long log)? → Citation-only subagent.
4. **Is it destructive or does it dirty the tree** (mutants, probes)? → Isolate it in a scratch copy,
   preferably inside a tool, as `mutant-sweep` does. Use a subagent only when the probing itself needs judgment (`break-it`).
5. **Otherwise** → keep it in the main loop as a skill (procedure) or a tool/CLI check (hard limit). Do
   not create a specialist agent per topic.

When dispatching, follow `AGENTS.md` › Approach: a research-only subagent with full tools is told not to
edit, it gets the active branch only, and it returns the `subagent-report.md` shape.

## Model tiers: is the Balanced preset optimal?

Board › Admin › Model tiers, preset `Balanced (default)` (`tools/sprint-check-app/model-tiers.json` `presets[0]`):
plan `top`, spec check / build / reviewer / evaluator `mid`, second eval `off`, light work `cheap`.

**Which steps are sessions and which are subagents: optimal.** It matches the article.
- Plan (Opus) and Build (Sonnet) are the *same session*: `/model` switches when the turn ends, and the
  context carries over. The planner's reasons reach the builder with no handoff, which is the article's
  "the model that writes the plan carries it out". The only cost is one prompt-cache miss at the switch.
- Only checkers are fresh subagents (spec check, reviewer, evaluator, second eval). That is the
  verification exemption.
- Light work (explore, orient) on Haiku is parallel, disposable research. "Light implement" on Haiku
  is a handoff, so keep it to mechanical pieces with a clean interface.

**Which model each checker gets: not optimal.**
- **Evaluator = Build model (Sonnet).** The card says so itself ("the check runs on the model that made
  what it checks"). The binding gate is isolated for independence, and grading with the builder's model
  brings the builder's blind spots back in. `AGENTS.md` › Model Tiers also says `review` → Opus
  ("a weaker model would rubber-stamp"), so the default preset contradicts canon's own tier table.
- **Spec check (Sonnet) grades an Opus plan.** The checker is weaker than the author, on the cheapest
  gate there is: about 1.5 min and about 60k tokens per run (`.claude/subagent-runs.jsonl`, 59 runs).
- **Reviewer = Build model.** It's advisory. Either give it a different model or measure folding it
  into the inline `code-reviewer` (below).
- **Second eval off** is right as a default: it's for high-risk tickets.

The `Checker ≠ builder` preset (plan, spec check, reviewer and evaluator on `top`, build on `mid`,
second eval `mid`) fits both the article and `AGENTS.md`. Cost: the evaluator averages about 73k tokens
and 7 min per run, the reviewer about 74k and 5 min, all on Sonnet. **No gate in the log has ever run on
Opus**, so a quality gain is not yet shown. Measure before changing the default: run `tools/gate-cases.sh`
with Evaluator = Sonnet and with Evaluator = Opus, several runs each, and compare the findings that flip.
Either resolve the conflict between `AGENTS.md` and the default, or record why Balanced wins.

## Factory pipeline: is it optimal?

Board › Factory › Pipeline, a Normal ticket: Start → Plan → **Spec check** (agent) → Approve plan (you) → Build →
code-simplifier → code-reviewer → doc-audit → skill-eval → **break-it** (agent) → **Reviewer** (agent) →
security-review → mutation-test → **Evaluator** (agent) → Close.

**What fits the article:**
- Most of the gates run inline as skills or tools on the session model (code-simplifier, code-reviewer, doc-audit,
  security-review, mutation-test). Only the steps whose value is a reader without history are subagents.
- Gates run only when their condition holds (changed code, changed docs, a changed skill, high risk), and Lite and
  Manual tickets skip optional gates. That keeps cost in line with the work, the way the article's
  "progressive disclosure" does.
- The binding Evaluator comes last and grades the final commit: the article's "optional verifier after the answer".

**What doesn't:**
1. **Several review passes over the same diff.** A normal code sprint gets code-simplifier, code-reviewer, Reviewer,
   security-review and the Evaluator (and break-it when high risk). This article's measure-first rule has already
   been applied to the fresh Reviewer: t-63a7 (DECISIONS 2026-10-30) found that on the 20 newest normal sprints the
   reviewer caught a fixed defect the evaluator likely would not have caught on 10. So it stays, and the fold trial
   was not run. The inline code-reviewer is not a subagent, so its cost is small. Open follow-ups: t-1a01 (the
   Pipeline tab's Reviewer switch already makes it per project, via t-7e76; what's left is running it anyway on
   high-risk sprints, plus an explanation on the row) and t-9113 (gate insights on a cadence).
2. **Everything is sequential.** break-it and Reviewer are both read-only fresh subagents that look at the same commit
   before any fixes, but they're dispatched one after the other, each with its own `gate-snapshot` pre/post. One
   message with both dispatches, inside one snapshot window, would save a gate's runtime on high-risk sprints (the
   reviewer averages about 5 min). The cost: fixes from both land together, and `gate-snapshot` and
   `subagent-log` would need to handle two gates at once. Ticketed as t-9e7a.
3. **Labels.** skill-eval is labelled GATE, but it dispatches a fresh executor and grader pair per case. That's correct
   behavior, but the badge hides that it uses subagents.

## Candidates to measure (not changes)

- **Reviewer fold**: already measured (t-63a7: kept). Re-run `.tickets/t-63a7/measure-report.md` §5 when
  t-9113 makes the numbers routine. For end-user projects, t-1a01 decides the default.
- **Explore fan-out on small sprints**: check `subagent-runs.jsonl` for orient runs whose subsystems
  were small enough to read inline.
