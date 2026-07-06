---
name: repo-workflow-audit
description: Runs a fresh-context, 4-way parallel audit of a canon workflow's own skill/reference docs against themselves — pipeline gates, adversarial review, cross-doc consistency, stale-reference sweep. Use when asked to deep-scan, audit, or health-check the sprint/wrapup workflow docs (or another skill's own protocol files) for internal contradictions, staleness, or drift — not for auditing a whole repo's product code (use repo-audit for that).
category: agent-ops
tags: [audit, workflow, sprint, self-audit, quality]
hidden: true
---

# Repo Workflow Audit

Internal — not for direct/public invocation. Called by the maintainer when auditing canon's own workflow docs.

Audits a canon workflow's own skill/reference docs against themselves — distinct from `repo-audit`, which rates any repo's general health (uniqueness, philosophy coherence, docs, codebase quality) via a single agent. This skill is self-referential: it checks whether canon's *own* workflow machinery (sprint, wrapup, or another skill family) is internally consistent, current, and free of the contradictions that narrowly-scoped per-ticket reviewers wouldn't catch.

## When to use

Triggers: "audit the sprint workflow", "deep-scan the close pipeline", "check the wrapup docs for drift", "run the workflow audit on `<skill>`". Not for general repo health (`repo-audit`) or a single ticket's diff (sprint's own `review.md`/`eval.md` gates already cover that).

## Target scope

Default target: `skills/sprint/**` + `skills/wrapup/**` (the pair this pattern was built for, in `t-6487`) + `standards/efficiency.md` (the coding-standards doc underlying wrapup's own gates). If the user names a different skill or doc set, use that instead — the pattern generalizes to any skill family with reference/gate sub-files.

## Model

This is deliberately high-scrutiny work. Default to the strongest available model for all 4 dispatches below — do not apply any cheap-model/blast-radius shortcut a target workflow's own gates might use on themselves (e.g. `skills/sprint/reference/complete.md`'s Haiku rule). If the user asks to keep review at full tier, that instruction always applies here too — this skill's whole purpose is high scrutiny.

## The 4 dispatches

Run these as independent, fresh-context subagents in parallel — each is blind to the others' findings, so coverage doesn't collapse into one agent's blind spots.

1. **Pipeline gates.** Read `skills/wrapup/SKILL.md`'s pipeline definition, each `skills/wrapup/gates/*.md` protocol (simplifier, code-reviewer, security-review, repo-check), and `skills/doc-audit/SKILL.md` (doc-audit lives as its own standalone skill, not under `gates/`). Apply all five gates to the full current contents of the target scope — as a standing check of the target's current state, not a ticket diff. Report file:line + quoted excerpt for every finding; state explicitly what was checked even when a gate finds nothing.

2. **Adversarial review.** Read the target workflow's own review protocol (e.g. `skills/sprint/reference/review.md`) and apply the same scrutiny to the target scope's current contents as "the code under review." Look for internal contradictions, ambiguous instructions, assumptions about state/files that don't exist, and places where two files describe the same mechanism differently. Also run a lean-language pass on skill docs: flag prose bloat, unnecessary fluff, repeated wording/instructions, and wording that can be made simpler and more straight-to-the-point without losing clear, correct intent.

   For each flagged file, don't just flag — produce an actual candidate rewrite: compress prose framing to telegraphic phrasing (drop articles/filler where grammar allows), modeled on the caveman project (github.com/JuliusBrussee/caveman) and this repo's own `t-532d` prune of `standards/efficiency.md`. Byte-preserve code, paths, commands, flags, and format templates — compress only the prose around them, never the rules/cases/templates themselves. Report old/new word counts as evidence of the compression, alongside the candidate rewrite.

3. **Cross-doc consistency.** Read every file in the target scope together — plus anything outside it that describes the same mechanism (README sections, `docs/*.md`, `AGENTS.md`). Report contradictions or gaps as a set, not per-file: does one doc say something a sibling doc contradicts? Does a top-level rule (e.g. `AGENTS.md`'s Model Tiers) need to cross-reference a target-scope rule that overrides it for a specific case?

4. **Stale-reference sweep.** Repo-wide grep (not limited to the target files) for anything — other skills, `docs/`, `README.md`, `starters/`, public posts — that references the target's old or removed behavior. State the search terms/globs used so an absence-of-findings claim is verifiable, not assumed.

## Compile, don't auto-fix

Dedupe findings across all 4 reports (the same issue often surfaces from more than one angle — that's cross-confirmation, not noise). Rank by severity. Present the full compiled list to the user before applying any fix — this skill produces a report; fixing is a separate, explicit step the user scopes (all findings, a subset, or just the regressions). Log anything genuinely out-of-scope as `NOTICED:` rather than fixing silently.

If the user approves fixes, apply them directly, then re-verify with `npm test` (or the target repo's equivalent) and a fresh grep sweep for the same stale terms before considering it done — a subagent's "fixed" claim is not itself evidence; check the actual diff.

For an approved **compression** fix specifically, that re-verify step isn't enough — tests and grep don't catch a rule or case silently dropped in prose compression. Before considering a compression fix done, dispatch a fresh-context subagent (`review` purpose) to diff the old file against the applied rewrite line-by-line and report any rule, case, or format template present in the old but missing or weakened in the new — mirroring `t-532d`'s pattern. Fix any finding and re-run the diff-verification until it reports none; for a file that's live `@`-imported into other projects' contexts (broad blast radius), run this verification twice, as `t-532d` did.

## Gotchas

- Don't skip a dispatch because it seems redundant with another — the four lenses catch different failure modes (a gate the dispatching agent forgot to run vs. a doc contradiction vs. staleness outside the target scope entirely).
- A finding two dispatches independently surface is stronger evidence, not duplicate noise — note the cross-confirmation when compiling.
- If the target scope's own close gates include a cheap-model shortcut, this audit still runs full-tier regardless — auditing the shortcut itself is one of the things it should catch.
