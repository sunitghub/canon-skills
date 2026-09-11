---
name: context-doctor
description: Audits a repo's agent context — system prompt, CLAUDE.md/AGENTS.md, skills, and references — against context-engineering lessons for Claude 4/5 models (model detected from the running session, or set via --model), then writes claude-optimization.md with a Summary table. Use to right-size an agent setup, cutting over-constraint, redundancy, always-upfront context, and conflicting instructions.
category: agent-ops
tags: [context, prompt, skills, audit, optimization]
---

# Context Doctor

Static audit of a repository's **agent context** — everything a coding agent loads before it sees a
user prompt: `CLAUDE.md`/`AGENTS.md`, skill and command files, tool descriptions, and referenced
specs/mockups. Rates each of seven lenses, prints a **Summary table**, and writes
`claude-optimization.md` at the repo root. Human-facing name: **Context Doctor**.

The seven lenses come from Anthropic's guidance on context engineering for modern Claude models:
https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models — the
same lessons behind removing ~80% of Claude Code's system prompt. This skill is a portable checkup
against those lessons.

**Self-contained.** It depends on nothing outside this folder — no build tools, no other skills, no
network. Drop it into any repo's `.claude/skills/` or upload it to Claude Desktop and run it.

## When to use

Triggers: "audit my agent setup", "is my CLAUDE.md bloated", "right-size my skills", "check my
context for over-constraint / conflicting instructions", "run context-doctor". Run it periodically,
or after a CLAUDE.md/skills grow large.

Not for: running or testing the target app (static read only), general code review, or a single
sprint diff.

## Target model

Two checkup modes, gating which Fable-5-specific checks run:

- **`5`** (default) — full checkup: the seven lenses below, plus four Fable-5-specific checks
  (reasoning-extraction avoidance, effort-default guidance, checkpoint/pause discipline,
  progress-claim grounding).
- **`4`** — the seven lenses only, plus the two checks that are model-agnostic (checkpoint/pause
  discipline, progress-claim grounding). Skip reasoning-extraction avoidance and effort-default
  guidance — those are Fable-5-only failure modes and would be false positives for a repo targeting
  Opus 4.8.

Detect the default from the running session's own model identity (stated in the system prompt).
Override with `--model 4` or `--model 5` when the repo's target differs from the session model —
e.g. auditing on Sonnet 5 a repo whose skills are written for an Opus 4.8 production deploy. State
which mode was used, and how it was determined (detected vs. `--model` override), in the report
header.

## Operating constraints

- **Static analysis only.** Read the context files. Never run the repo, execute skills, or call a
  model. No dynamic probing.
- **Judgement, not a checklist score.** Report a per-lens status and one overall verdict — **never a
  numeric score or percentage**. A number hides which lens is weak.
- **Evidence, not theory.** Cite `file:line` (or `file` + a short quote) for every finding. Flag a
  lens `action`/`advisory` only with a concrete instance, not a hypothetical.
- **Repo-agnostic + graceful.** If an artifact is absent (`CLAUDE.md`, `.claude/skills/`, etc.), say
  so and continue — an absent file is a valid result, not a finding.
- **Read, don't rewrite.** This skill diagnoses and recommends. It does not edit the audited files;
  it only writes the one report.

## What to inspect

Gather the context artifacts that exist in the target repo (skip any that are absent, note which):

- `CLAUDE.md` (repo root and any nested), `AGENTS.md`, `.cursorrules`/other agent-instruction files
- `.claude/skills/` (or `skills/`) — each `SKILL.md`, plus any `reference/`/`gates/` sub-files
- Tool/command definitions and their descriptions
- `@`-imported or referenced standards/config injected into every session
- Referenced specs, plans, mockups (are they prose, or code/HTML/tests?)

Line counts are a proxy for context weight, not exact tokens.

## The seven lenses

Rate each: **aligned** (follows the lesson), **advisory** (minor drift, worth trimming), or
**action** (clear instance to fix). Cite evidence.

1. **Rules → judgement.** Blanket prohibitions/mandates a capable model handles via judgment.
   - Check for absolute rules that are wrong in some cases: "never write comments", "always
     do X", rigid formatting dictates. Prefer judgment-framed guidance ("match the surrounding
     code's comment density, naming, and idiom").
   - `action` when a blanket rule would produce wrong behavior for a reasonable subset of tasks.

2. **Examples → interface design.** Over-reliance on usage examples where an expressive interface
   would guide better.
   - Check tool/command definitions: do they lean on long "here's how to call it" examples, or do
     clear parameter names, enums, and defaults make correct use obvious?
   - `advisory` when examples substitute for a self-describing interface.

3. **Upfront → progressive disclosure.** Context injected on every session that is only
   conditionally needed.
   - Check for always-loaded content used by a minority of tasks (verification/review steps, rare
     workflows, deep references). Recommend moving it behind on-demand skills/reference files loaded
     when needed. Note oversized always-on files (a long root `CLAUDE.md`, a monolithic SKILL.md).
   - `action` when a large block is always injected but rarely used.

4. **Repeat yourself → simple descriptions.** The same instruction duplicated across places.
   - Check for guidance repeated in the system prompt/`CLAUDE.md` *and* a tool/skill description, or
     the same rule copied across files. Recommend one owner; put tool usage in the tool description.
   - `advisory`/`action` per how much duplication and drift risk exists.

5. **Memory: manual → durable.** How cross-session knowledge is captured.
   - Check for heavy manual "save this to memory" instructions. Note that modern harnesses can
     auto-capture relevant memory. Portable, repo-native memory (decision logs, handoff notes) is a
     legitimate deliberate choice — flag only redundant manual bookkeeping, not durable records.
   - Usually `advisory`.

6. **Simple specs → rich references.** Fidelity of the references the agent works from.
   - Check whether specs/designs are prose or screenshots where a higher-fidelity reference exists:
     a code file to port, a test suite as the spec, an HTML mockup instead of a description or
     screenshot, or a rubric a verifier can check against. Recommend code/HTML/test references.
   - `advisory`/`action` when a prose/screenshot reference could be a code/HTML/test artifact.

7. **Conflicting instructions.** Contradictory directives across the loaded context.
   - Cross-read the artifacts for clashes (e.g. "leave documentation as appropriate" vs "DO NOT add
     comments"; "keep it minimal" vs "be thorough"). Contradictions force the model to spend
     reasoning reconciling them. Quote both sides.
   - `action` for any direct contradiction; `advisory` for tension worth clarifying.

## Model-agnostic checks (both `4` and `5`)

8. **Checkpoint/pause discipline.** Instructions that make Claude stop or ask permission more than
   the task needs.
   - Check for guidance that would block on "Want me to…?"/"Shall I…?" for reversible, in-scope
     actions, or that omits when pausing is actually warranted (destructive/irreversible actions,
     real scope changes, input only the user can provide).
   - `action` when a skill/CLAUDE.md lacks any checkpoint guidance for a long-running or autonomous
     workflow; `advisory` when guidance exists but is vague.

9. **Progress-claim grounding.** Long-run status reporting that isn't tied to verifiable evidence.
   - Check whether workflows that report progress (multi-step skills, autonomous loops) instruct
     grounding each claim in a tool result from the session, and stating explicitly what wasn't
     verified.
   - `advisory` unless the repo has evidence of prior fabricated status reports, then `action`.

## Fable-5-specific checks (`5` only)

10. **Reasoning-extraction avoidance.** Instructions that ask Claude to echo, transcribe, or explain
    its internal reasoning as response text.
    - Check skills/CLAUDE.md for "explain your reasoning", "show your work", or similar asked of the
      *response* (not `thinking` blocks). This can trigger Fable 5's `reasoning_extraction` refusal
      category, causing fallbacks to Opus 4.8.
    - `action` when found — do not raise this check in `4` mode; it is not a failure mode for
      Opus 4.8.

11. **Effort-default guidance.** Whether effort-level usage matches Fable 5's cost/latency curve.
    - Check for blanket `xhigh` usage on routine work, or no effort guidance at all on a repo doing
      capability-sensitive work. Recommend `high` as default, `xhigh` for the most
      capability-sensitive workloads, `medium`/`low` for routine work.
    - `advisory` — these are tuning recommendations specific to Fable 5, not a correctness bug; do
      not raise this check in `4` mode, since Opus 4.8's effort/quality tradeoff differs.

## Summary and verdict

Open the report with a Summary table — one row per lens:

| Lens | Status | Evidence | Recommendation |
|---|---|---|---|

Then an overall posture verdict:

| Verdict | Criteria |
|---|---|
| **lean** | No `action` lenses; at most minor `advisory` notes. Context is well right-sized. |
| **trim** | One or more `action` lenses, each with a concrete, scoped fix. Worth a cleanup pass. |
| **overloaded** | Multiple `action` lenses or a structural problem (large always-on context, several conflicts) needing a deliberate restructure. |

No numeric score. Any lens rated `action` forces at least **trim**.

## Report

Print the Summary table inline. Then ask: `Write claude-optimization.md to the repo root? (y to confirm)`.
Do not write without `y`. On confirmation, write `claude-optimization.md` at the repo root (overwrite
— it is a point-in-time snapshot, not a log):

```
context-doctor run: MM-DD-YYYY hh:mm
Audited against: Claude <4|5> context-engineering guidance (<detected from session | --model override>)

## Context optimization: <repo-name>
Scope: <artifacts inspected; which were absent>

| Lens | Status | Evidence | Recommendation |
|---|---|---|---|
| Rules → judgement | <status> | <file:line or quote> | <one-line fix> |
| Examples → interfaces | ... | ... | ... |
| Upfront → progressive disclosure | ... | ... | ... |
| Repeat → simple descriptions | ... | ... | ... |
| Memory: manual → durable | ... | ... | ... |
| Specs → rich references | ... | ... | ... |
| Conflicting instructions | ... | ... | ... |
| Checkpoint/pause discipline | ... | ... | ... |
| Progress-claim grounding | ... | ... | ... |
| Reasoning-extraction avoidance (5 only) | ... | ... | ... |
| Effort-default guidance (5 only) | ... | ... | ... |

Omit the last two rows entirely in `4` mode — don't print them as "n/a".

### Details
<one short paragraph per lens rated advisory/action, each with file:line evidence>

### Not inspected
- <artifact absent — why it was skipped>

context-doctor verdict: lean | trim | overloaded
```

The final `context-doctor verdict:` line is required.

## Gotchas

- **No context artifacts found?** If the repo has no `CLAUDE.md`/`AGENTS.md`/skills/agent config,
  say so and stop with a limited-scope note — do not invent findings. A repo with no agent context
  is a valid, clean result.
- **Durable memory is not clutter.** A decision log or handoff file is deliberate cross-session
  memory, not the manual-bookkeeping the memory lens flags. Don't recommend deleting durable records.
- **Don't over-apply "rules → judgement".** Constraints that guard genuinely dangerous or
  irreversible actions (destructive commands, security boundaries, mandatory review gates) should
  stay explicit — the lesson is to relax *advisory* over-constraint, not safety-critical rules.
- **No numeric score.** If tempted to write "7/10" or a percentage, stop — use per-lens status plus
  the lean/trim/overloaded verdict.
- **Optional canon companion.** In a repo that uses canon, `context-check` gives a deeper always-on
  *budget* audit (line-by-line size/redundancy). context-doctor does not require it and never calls
  it — mention it only as a follow-up if present.
