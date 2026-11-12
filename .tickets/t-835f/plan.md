# Plan

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-835f`
<!-- Keep this doc under ~500 words — it is injected at every session start. -->

## Sign-off
<!-- Fill in: Tier: <tier> | Risk: <blast radius / key risks, one line> -->
<!-- Optional, append: | Gate model: <value> -- forces the sprint-close reviewer/evaluator onto that model, overriding the automatic Admin Review & Eval default. Valid values (case-insensitive): a model id (e.g. haiku, sonnet, opus), or the literal "session" to force full session-model review. Omit entirely for automatic behavior -- there is no separate "auto" value; absence already means automatic. -->

Tier: normal | Risk: advisory output in a pipeline script; no exit-code change, shell only

- [x] Plan approved — proceed to implementation
Approved: sha256:ca2113797e5e3112f24e990c462b7d0ddf9a631678b282d68e55384539f729e4 2026-11-12T00:08:44Z
Pipeline: sha256:1de8c9fc6b17 off=- wrapup=code-simplifier,code-reviewer,doc-audit

## Approach
<!-- Describe how you will implement this. Keep this heading unchanged. -->
Extend `tools/pre-gate-check.sh` (the one owner; it already stamps into `pre-gate.log`) with an advisory `size_report` step beside the dead-code one:
1. `git diff --numstat $base HEAD` (minus `.tickets/`, binary rows `-` count as 0) gives added/removed per file.
2. Read plan.md from the ticket dir (`PRE_GATE_ID` passed from the outer call into `--run`); take the `## Files` section text; a changed file is planned when its path, or a listed `dir/`, appears in it.
3. Limits come from a new `tools/size-caps.tsv` (`file-net 400`, `total-net 1000`; lower, never raise). Flags: `unplanned:`, `large:`, `total`, `no test:` (new non-test/non-doc file, no test file in the diff).
4. Append `| size (advisory): planned N files, changed M, +A/-D; <flags or none>` to the line. Never touches `rc`. No plan.md or base: `size: skipped | reason`.
5. One line in `complete-checklist.md` Pre-gate step (stay under its 900-word cap), a CHANGELOG line.
Number moved: pre-gate gains one field; target is a reviewer who quotes the stamped size instead of estimating it.

## Files
tools/pre-gate-check.sh; tools/size-caps.tsv; tests/pre-gate-check.sh; skills/sprint/reference/complete-checklist.md; CHANGELOG.md.

## Decisions
<!-- Record non-obvious tradeoffs and why. Answer each item under the ticket's ## Open questions here, or write "carried forward: <question>". Keep this heading unchanged. -->
- Folded into pre-gate-check.sh, not a sibling script: it already owns the stamp and the changed-file list (no second diff walk).
- Own table `tools/size-caps.tsv`, not caps.tsv: caps.tsv units live in Go, so a new unit would force a daemon release for an advisory number.
- Starting limits 400 per file / 1000 total net are a guess from recent sprints; falsified if more than about one in three closes flag. Advisory because line count is not quality.
- Tier: normal (hook/pipeline script plus test, new data file). Shell only: no daemon release. Tower score feed stays in t-2ce4.
