---
name: efficiency
description: Coding standards, code review feedback, git conventions, behavioral triggers, and token-efficiency rules for AI agents
category: agent-ops
tags: [coding, security, git, efficiency, tokens]
inject: true
version: 1.0.5
updated: 2026-09-22
---

# Agent Standards

## Code

- Prefer editing existing files over creating new ones; add a new file only when the task needs one.
- Delete dead code you orphan — no commented blocks, no `_unused` renames. Leave pre-existing dead code unless asked.
- No feature flags or backwards-compat shims — change the code directly.
- Match the surrounding code's comment density, naming, and idiom — add a comment only where the WHY isn't clear from the code.
- Don't reformat, rename, or add type hints to adjacent code — fix only what was asked.
- Out-of-scope issues found while working: `NOTICED: <what>` — don't fix silently.
- Never introduce OWASP Top 10 vulnerabilities or commit secrets, credentials, or `.env` files.
- No new dependencies for problems existing tools solve.
- Test at system boundaries; don't mock what's cheap to integration-test.
- Passing tests verify code correctness, not feature correctness — test both.
- A test failing inside a block your diff touches is not automatically pre-existing/unrelated — diff its failing assertion and target string against the base commit byte-for-byte before excluding it from scope.
- Grade test-count/pass-rate claims (e.g. "121/121 pass") against the actual recomputed total from real command output, not the doc's own summary arithmetic — check specifically for a silently-omitted did-not-run set.

## Code Review Feedback

Format: `file:line — <problem>. <fix>.` — no hedging prose, no preamble, no restating what the code does. A `[severity: … · confidence: …]` tag on a finding is not hedging — that's calibration, not padding.
Explain only when the fix isn't self-evident; security/architectural issues get full explanation.
- Ground review in base code, not the PR diff — the diff biases toward the PR's own framing; base code is what actually exists.
- Scope to the change — no frontend notes on backend-only work, no unrelated coverage.
- A committed binary that changed alongside its source file (e.g. a rebuilt `.exe` beside the `.go` it's built from) is scope, not creep, when repo history shows the pairing predates this ticket — check `git log` on the binary's path before flagging a file-list criterion violated for it; disclose it as an ungraded artifact instead of failing the criterion.

## Git

- Commits: imperative mood, 50-char target / 72-char hard limit, no trailing period.
- Type prefix: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, `build`, `ci`, `style`, `revert`.
- Focus on WHY — no self-referential language ("This commit...", first-person).
- Prompt changes: log the intent (what failure/behavior it fixes), not just the diff — otherwise regression diagnosis across versions is a day of archaeology.
- Sprint-backed change: `Closes: t-xxxx` in the commit body — the ticket holds the full reasoning, constraints, and acceptance criteria the commit message can only summarize.
- Add a body for breaking changes, non-obvious reasoning, or migration instructions.
- Branches: `feat/short-description`, `fix/short-description`. Never force-push main/master.
- PRs: one concern each, title under 70 chars, body = summary bullets + test plan.
- Never `git add -A` — stage specific files.

## Triggers

Act on these when you see them — don't wait to be told.

- Same fact in multiple files → pick one owner, derive the rest. Exception: deliberately-mirrored docs/prose that must stay self-contained for separate consumers (e.g. gate docs each dispatched to a fresh subagent) — keep the copies, lock them with a parity test (`tests/doc-mirror-parity.sh`) instead of merging.
- One change needs edits in many unrelated places → fix the missing boundary first.
- Structural edits mixed with behavior changes in one commit → split them.
- Unclear behavior before touching it → characterize current behavior first.
- A third copy of the same logic appears → remove the duplication, don't copy again. Exception: same logic ported across incompatible runtimes (bash/Python/Go, etc.) with no shared-code option — keep the ports, lock them with a parity test instead of merging.
- Tests need excessive setup → the dependency structure is the problem, not the tests.
- Refactor spreading into unrelated areas → cut back to the smallest change that makes the requested edit safe.
- Error surfaces without context → preserve diagnostic info at the boundary, don't swallow it.
- Spec conflicts with existing code → surface it — what each says, the options — and ask; don't silently pick one.
- Non-trivial decision about to be committed → name what you're asserting and what would falsify it before it stands.
- Competitor or adjacent-tool analysis changes how canon should operate → capture it in a skill, standard, guide, or tool behavior before wrapup.
- A workaround, rendering quirk, or undocumented constraint found while fixing → stage it in `HANDOFF.md ## Discoveries` immediately; route it to its permanent home yourself before wrapup (SKILL.md gotcha, `standards/`, DECISIONS.md, or the repo's bug-pattern log if one exists).
- Under `set -euo pipefail`, `VAR=$(cmd)` exits silently if `cmd` fails — `|| fallback` on the next line never runs. Safe: `VAR=$(cmd) || VAR=fallback` on one line.
- Under `pipefail`, `! cmd | grep -q x` can pass *without checking*: `grep -q` exits at the first match and SIGPIPEs the writer, so the pipeline reports non-zero even though it matched, and `!` flips that to success. It only fires when the writer still has output buffered, so a small input hides it and a larger one makes it deterministic. Safe: `[ "$(cmd | grep -c x)" -eq 0 ]` — keep it inline; hoisting it to `n=$(cmd | grep -c x)` hits the previous trigger, since `grep -c` exits 1 on *zero* matches.
- A bare `[[ cond ]] && cmd` as a function's LAST statement returns the `[[ ]]` test's own exit status (1) whenever `cond` is false — under `set -e`, that silently aborts the *caller*, not just skips `cmd`. Easy to miss because the common/expected case (`cond` usually true) never triggers it — it only fires once the false branch becomes reachable, potentially long after the line was written. Safe: wrap in `if`/`fi`, or append `; return 0` / `|| true` after it.
- A test asserts against a re-implementation of the logic under test → call the production function instead. A locally rebuilt sort key or a hand-copied constant list passes while the real thing is broken.
- A guard exercised only against inputs it already handles is unverified → feed it the cases it must *reject*.
- Never `pkill`/`kill` by matching a process name, script path, or command-line pattern shared with anything the user might independently be running (a dev server, an agent daemon, a shared script invoked from elsewhere) — a pattern match can hit the user's own live, unrelated process and kill in-progress work with no undo. Resolve the exact PID first (a lockfile/state-file's recorded PID, the port a service publishes, or `$!` from a process this session itself started) and kill only that PID.

## Token Efficiency

- Most token spend is re-reading history, not generating output — verbose replies compound across every future turn. Keep it tight.
- Before planning: catalog existing files, patterns, and prior implementations. Name what's reusable before writing new code.
- Read a file before editing it. Grep for callers before modifying a function.
- Reference exact file paths and line numbers — don't re-read files already in context.
- Skip `node_modules`, `.git`, `dist`, `build`, `__pycache__`, `.next` unless asked.
- Use targeted bash commands — avoid ones that dump large output for a narrow query.
- Keep CLAUDE.md and AGENTS.md concise — rules, gotchas, non-obvious conventions only.
- Summarizing or rewriting: preserve code blocks, inline code, paths, URLs, commands, version numbers, and technical terms exactly.
- In Claude Code, run `/context-check` to audit the always-on context budget; it writes a `context-check-report.md` at the project root (after confirmation). The `/context-check` slash command is Claude Code-specific — under Codex, Pi, or headless runs it does not exist; audit the budget manually there.
