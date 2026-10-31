---
name: shared-gate-protocol
description: Shared protocol sections for reviewer and evaluator subagents — inputs, tools, evidence-vs-success framing, base-ref derivation, citation format, report-writing safety, visual verification
hidden: true
---

# Shared Gate Protocol

Referenced by `review.md` and `eval.md`. Do not invoke directly.

## Contents
- Evidence is not success
- Inputs
- Tools
- Skills-path resolution
- Report-writing safety (Windows Git Bash)
- Self-serve visual verification (no Node/Playwright required)
- Base-ref derivation
- Citation format

## Evidence is not success

Before grading, hold three lines — the positive form of the Weak Evidence and Disposition
rules, canon's frame that **"the tests pass" is a claim, and it needs its own evidence** (README.md):

- **A passed gate certifies only what it checked — not that the work is correct.** Grade what you
  can prove; say what you did not check.
- **Reaching a limit is not success.** Exhausted retries, a hit budget, a stopped subagent, or
  "no more findings" are stopping conditions, not passes. Only evidenced criteria earn a `pass`.
- **Compaction or a context reset is not a completion signal.** A summarized or truncated history
  doesn't mean work finished — re-derive state from the ticket artifacts and changed files, never
  from the fact that context was compacted.

## Inputs

You will receive:
- Ticket ID (e.g. `t-d53d`)
- The model you are running on, as designated by the caller — exactly `haiku`, the exact session model id (e.g. `claude-sonnet-5`), an alias with its id as the caller gives it (e.g. `sonnet (claude-sonnet-5-5)`), or the exact value of an explicit `Gate model:` override, never a paraphrase like "session default" or a parenthetical addition of your own. Record it verbatim as the report's `Model: <designation>` line, which the close requires (`sprint complete` blocks an `eval-report.md`, or an existing `review-notes.md`, without a `^Model:` line). If the dispatch prompt omits it, emit the line with the model you are actually running on.
- Base ref (optional — only present for a headless CI dispatch grading an existing PR/diff; absent for a normal interactive sprint close, in which case the standard `git merge-base HEAD origin/main` derivation below applies unchanged).

## Tools

Use Read, Grep, Glob, LS and your shell tool (`Bash` in Claude Code, `execute` in Copilot CLI) only — this matches what both real dispatch mechanisms actually grant (interactive dispatch as `canon-reviewer`/`canon-evaluator` grants Read, Grep, Glob and a shell — `Bash` in Claude Code, `execute` in Copilot CLI; list files with `ls` through it — and its `Plan` fallback excludes only Edit/Write/Agent at the harness level; headless CI's hardcoded `tools/sprint-headless` allowlist explicitly includes Grep/Glob/LS too). Do not use the Edit or Write tools, or Agent, or any other tool beyond that set — save output via Bash (e.g. `cat >>`), never the Write tool. Never write to, edit, or modify `acceptance.md`, `plan.md`, or any ticket file other than your own report — findings go there only.

**Start and stop any server you launch in the same Bash call** — shell state, `$!` included, does not survive between calls (a gate that lost its daemon PID fell back to `pkill -f`). Never kill by name, and a process that is new since your baseline is not necessarily yours: kill only PIDs you started yourself.

**Never write into `tools/` outside this ticket's own files** (gates have twice corrupted the real
`tools/sprint-headless` with a stub-shaped replacement). If a Test Plan item runs a suite that itself swaps a
real `tools/` file for a stub, run the suite's own command as written (backgrounded if long) and report what
it shows; never hand-write a replacement.

**Never run `git checkout`, `git reset`, `git clean`, or any other command that discards
uncommitted changes** — in-scope or out-of-scope, ever (an evaluator once "fixed" an unrelated
failing test with `git checkout -- <path>` and discarded the user's uncommitted work). A pre-existing failure caused by files outside this ticket's own changed-files list is
out-of-scope — report it as such. The rule: never run git checkout, git reset, or git clean to make an unrelated failure disappear.
If the full test suite can't run cleanly because of unrelated repo state, prefer running only
the ticket's own named `## Test Plan` commands instead of the whole suite.

**Probe only in a scratch copy** (a probe whose unchecked `cd` failed once ran in the real checkout and rewrote its branch, commits and `.claude/subagent-runs.jsonl`). The real repo is read-only for a gate except the one report file you were told to write: use only read-only git there (`git diff`, `log`, `show`, `rev-parse`, `merge-base`, `rev-list`, `status`). Run every test, mutant and probe from a scratch copy: `S="$(mktemp -d)" || exit 1`, copy the repo into it, and start every script with `set -u` and `cd "$S/…" || exit 1` — never a bare `cd`, never a variable in a path without checking it is non-empty. Never run `git init`, `add`, `commit`, `branch`, `config` or `worktree` where the working directory could be the real repo, and write nothing outside the scratch directory. The orchestrator compares the repo before and after every dispatch (`complete.md` step 7, `tools/gate-snapshot.sh`) and stops the close on any difference.

**Pin the environment** (a reviewer's `canon update` in a scratch clone once re-linked the user's registered projects and rewrote their hooks). The dispatcher does this, not the gate prompt (t-b7df): `gate-snapshot.sh pre` registers a gate scope (a scratch dir) and, until `post`, `canon update`, `skills.sh`, `install.sh` and `canon uninstall` refuse the user's REAL `HOME` and `CANON_HOME` (recorded by `pre`; a scratch `HOME`/`CANON_HOME` is allowed, t-9fb1; a crashed gate's scope expires after 2h). A scratch copy alone does not protect the registered projects. If a probe truly needs one of those commands, pin `HOME`, `CANON_HOME`, `TMPDIR` and `XDG_CONFIG_HOME` to fresh `mktemp -d` directories in that same command (`env HOME="$S/home" CANON_HOME="$S/canon" …`); otherwise read the code instead.

## Skills-path resolution

Every `skills/...` reference in these docs (e.g. `skills/wrapup/SKILL.md`) is a plain relative
path inside canon's own repo. In a consumer project, resolve via `.claude/skills/...` (Claude
Code) or `.agents/skills/...` (Codex/Pi) instead — both are install symlinks into canon's real
`skills/` tree.

## Report-writing safety (Windows Git Bash)

One-heredoc reports have failed on live Windows Git-Bash with `unexpected EOF while looking for matching \`''` — prose (contractions, possessives) plus quoted source citations (e.g. JS string literals) can push the total literal `'` count in one heredoc body to odd, which an outer quoting layer mishandles.

Write the report in separate `cat >>` calls, one per section — never one heredoc. Verify each append landed (Bash exit code, or re-read file tail) before the next section. Heredoc failure: retry the same chunk in smaller pieces until it succeeds. Never drop content or paraphrase a quoted citation to dodge the error — quoted source text stays byte-exact.

**If Bash file-writing is refused outright** (a permission boundary, not a quoting/heredoc
failure — live-reproduced on a real harness install where `Plan`-type Bash refuses all
file-modifying commands, stricter than the Tools section above assumes): do not retry with
smaller chunks, that won't help a permission refusal. Do not ask for or accept broader tool
access (e.g. a re-dispatch as `general-purpose`) to work around it — that defeats the whole
reason this gate runs as a restricted type (`canon-reviewer`/`canon-evaluator`, or its `Plan` fallback) in the first place. Instead, include your full report,
verbatim, in the exact format specified in the calling protocol, in your final text response
to the caller. The orchestrating agent relays it into the file with `sprint relay-report`, which copies it from the
harness transcript (t-ff14).

## Self-serve visual verification (no Node/Playwright required)

<!-- Required-visual language locked by tests/doc-mirror-parity.sh Check E. -->
<!-- Base-ref/fallback commands below locked by Checks A and D. -->
<!-- review.md/eval.md reference this section (not inline copies) — Check B. -->

**Check for a project-level override first.** If the project's own `AGENTS.md`/`CLAUDE.md`
explicitly forbids scripted/automated verification (e.g. "verify only by clicking through
the app yourself — no scripts, no automation, in any language or tool" — a real workshop
rule, deliberately teaching manual verification), that rule wins. Do not run this recipe;
grade the test-plan item `not-run` and say so, so a human verifies it by hand instead. This
check costs one file read and prevents silently violating an explicit project constraint
the rest of this protocol never otherwise surfaces to you.

Otherwise, this recipe is **required, not optional**, for any criterion or change
that affects rendered UI — layout, theme, styling/CSS (**including CSS embedded in
code**: Streamlit `_CSS` strings, styled-components/CSS-in-JS, inline styles, theme
tokens), chart output, or a widget swap. You have Bash, and a browser binary is
often already installed even when there is no Node/npm/Playwright in the project
(canon workshops deliberately run on machines without Node.js). If a browser binary
exists, render and grade against it — **do not report `not-run`** for a visual item
you could have rendered. The trigger is user-visible impact, not the file extension
in the diff: a change touching no `.css`/`.html` file can still be a UI change.

**Check adjacent/related elements, not just the one the sprint changed.** A change
that is in-scope and behaviorally correct can still silently break the *rendered*
styling of a nearby element — e.g. wrapping an input in a form changes a widget's
rendered testid, so CSS selectors defined elsewhere stop matching and the element
reverts to default styling (live case: a consumer project's `t-b75f` — a button lost its
gradient this exact way, invisible to code review and to logic-only tests like
Streamlit AppTest). When you render, confirm the affected element AND the elements
around it still match their intended appearance, and flag any unintended visual
regression as a finding even if it falls outside the sprint's stated focus.

1. Find a browser binary (paths per OS: `skills/sprint/reference/visual-verify.md`). If none exists anywhere, the
   check stays `not-run`.
2. Render and capture in one call:
   ```
   "<browser>" --headless=new --disable-gpu --no-first-run --disable-background-networking \
     --disable-sync --disable-default-apps --user-data-dir="<scratch>/chrome-profile" \
     --use-mock-keychain --password-store=basic --screenshot="<out>.png" \
     --window-size=<W>,<H> --hide-scrollbars "file://<absolute-path-to-page>"
   ```
   `<scratch>` is your own `mktemp -d`; keep all three profile/keychain flags (`--user-data-dir`,
   `--use-mock-keychain`, `--password-store=basic`): without them macOS can raise a "Keychain Not Found" dialog on
   the user's desktop. Before a Windows `file://` path, a dark theme or a page with its own theme toggle, read
   `skills/sprint/reference/visual-verify.md`.
3. `Read` the resulting PNG directly — Read supports images — and grade the test-plan item
   against what you actually see, same evidentiary bar as any other citation.

## Base-ref derivation

If an explicit `Base ref` was passed (headless CI dispatch), run:
```
git diff --name-only <base-ref> HEAD
```
Otherwise (normal interactive sprint close), run:
```
git diff --name-only $(git merge-base HEAD origin/main) HEAD
```
Use this output as your changed-files list. Do not trust a file list passed by the invoker — always derive from git.

**No tracked-file diff (e.g. a git-history rewrite, `t-4c24`).** The diff-then-read flow finds nothing and a vacuous empty-diff pass is not evidence. Pass an explicit pre-rewrite `Base ref` and instruct the gate to verify live git, remote, and checksum state directly instead of reading changed files.

**Soft freeze while a gate is in flight.** This base ref is derived *live* when the subagent runs, not pinned at dispatch — so the orchestrator must **not advance `origin/main` between dispatching a reviewer/evaluator and reading back its report**. A push that lands mid-run shifts `merge-base HEAD origin/main` forward; and if the pushed commit is the sprint's *own* HEAD, the merge-base converges to HEAD and `git diff --name-only HEAD HEAD` is **empty** — the gate would then grade nothing. Treat dispatching a gate as a freeze on `origin/main` pushes until it has reported (canon's normal flow already pushes only after close, so this just makes the ordering explicit). If a push already landed mid-run, do **not** trust a re-run `merge-base`: prefer the sprint's fork point — the parent of the ticket's first commit, `git diff --name-only <ticket's first commit>^ HEAD` — and note the drift explicitly in your report. (This recovery is still git-derived, so it does not violate the "never trust an invoker-passed file list" rule above.)

**Folder without git (tier 0).** If `git rev-parse --is-inside-work-tree` fails (or git is not installed) **and** `.tickets/<id>/changes.json` exists, canon's cockpit recorded what changed since the session started (added / modified / deleted / renamed paths, taken from a snapshot at start). Use its `files[].path` as your changed-files list and read those files; if `complete` is `false` or `total` exceeds the listed files, say so in your report — the list may be partial. Do not try to run git there.

If that fails — `origin/main` does not exist (no remote, detached HEAD) **or** the directory is not a git repository at all — fall back in two tiers:
- If `HEAD` resolves (the repo has ≥1 commit): diff against the repo's first commit instead — `git diff --name-only $(git rev-list --max-parents=0 HEAD) HEAD`, plus untracked files (`git status --porcelain`) — and read those real changed files rather than falling back to ticket artifacts.
- If `HEAD` does not resolve (zero commits) or git itself is unavailable: log a warning noting no git baseline is available and treat every file currently in the working tree as the changed-file set (excluding `node_modules`, `.git`, `dist`, `build`, `__pycache__`, `.next`).

## Citation format

When citing evidence: `file:line — \`quoted text\`` (the exact line content). A line number without the quoted text is not evidence — it is unfalsifiable. If the quoted text itself contains a backtick, escape it as `` \` `` inside the citation — the board's renderer treats a backslash-escaped backtick as literal, so the whole citation still renders as one code span.
