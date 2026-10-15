---
name: efficiency-notes
description: On-demand domain rules moved out of the always-loaded efficiency standard: shell, tests and guards, security gates, destructive commands, renames, parity, Windows, Go
category: agent-ops
tags: [coding, testing, security, shell, windows]
hidden: true
version: 1.0.0
updated: 2026-10-15
---

# Agent Standards: domain notes

On demand, not always loaded. `efficiency.md` (always loaded) keeps the rules every session needs and names these sections in one index line; read a section before working in its domain. Moved here from efficiency.md in t-8837 (2026-10-15), verbatim.

## Duplication exceptions

The always-on rules are "same fact in several files → one owner" and "a third copy → remove the duplication". These are their two exceptions, which `tests/doc-mirror-parity.sh` and `tests/gate-model-parity.sh` rely on.

- Same fact in multiple files → pick one owner, derive the rest. Exception: deliberately-mirrored docs/prose that must stay self-contained for separate consumers (e.g. gate docs each dispatched to a fresh subagent) — keep the copies, lock them with a parity test (`tests/doc-mirror-parity.sh`) instead of merging.
- A third copy of the same logic appears → remove the duplication, don't copy again. Exception: same logic ported across incompatible runtimes (bash/Python/Go, etc.) with no shared-code option — keep the ports, lock them with a parity test instead of merging.

## Editing

- Inserting a block mid-file: check you aren't landing between an existing comment and the code it describes.

## Shell strict mode and traps

- Under `set -euo pipefail`, `VAR=$(cmd)` exits silently if `cmd` fails — `|| fallback` on the next line never runs. Safe: `VAR=$(cmd) || VAR=fallback` on one line.
- Under `pipefail`, `! cmd | grep -q x` can pass *without checking*: `grep -q` exits at the first match and SIGPIPEs the writer, so the pipeline reports non-zero even though it matched, and `!` flips that to success. It only fires when the writer still has output buffered, so a small input hides it and a larger one makes it deterministic. Safe: `[ "$(cmd | grep -c x)" -eq 0 ]` — keep it inline; hoisting it to `n=$(cmd | grep -c x)` hits the previous trigger, since `grep -c` exits 1 on *zero* matches.
- A bare `[[ cond ]] && cmd` as a function's LAST statement returns the `[[ ]]` test's own exit status (1) whenever `cond` is false — under `set -e`, that silently aborts the *caller*, not just skips `cmd`. Easy to miss because the common/expected case (`cond` usually true) never triggers it — it only fires once the false branch becomes reachable, potentially long after the line was written. Safe: wrap in `if`/`fi`, or append `; return 0` / `|| true` after it.
- Anything a function sets inside `$(func)` (an array append, a recorded PID) dies with the subshell, so a later cleanup trap kills nothing. Guard such helpers with `[[ $BASH_SUBSHELL == 0 ]]` (bash 3.2 has no `BASHPID`).
- Shell scripts: a function called in a `||`/`&&`/`if` list runs with `set -e` off, so an unchecked `mv`/`chmod` inside it cannot abort; `mv newdir olddir` onto an existing directory nests; `$((08))` is invalid octal (use `10#$n`). Make temp files with `mktemp` outside the work tree (or gitignore them) and remove them with `trap … EXIT`, not by a call on only the branch you tested.

## Tests, guards and hermetic runs

- A test failing inside a block your diff touches is not automatically pre-existing/unrelated — diff its failing assertion and target string against the base commit byte-for-byte before excluding it from scope.
- Grade test-count/pass-rate claims (e.g. "121/121 pass") against the actual recomputed total from real command output, not the doc's own summary arithmetic — check specifically for a silently-omitted did-not-run set.
- A test asserts against a re-implementation of the logic under test → call the production function instead. A locally rebuilt sort key or a hand-copied constant list passes while the real thing is broken.
- A guard exercised only against inputs it already handles is unverified → feed it the cases it must *reject*. Include spellings it has not seen; a match inside a comment does not count. A "nothing left behind" check (process, file, port) must observe what can leak (record the pid and `kill -0` it): an `lsof` on a stub that never listens passes. Prove it with a mutant that leaks. On macOS `mktemp -d` with no template ignores `TMPDIR`, so a temp-file leak check that pins `TMPDIR` watches an empty directory: give the code a template (`mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX"`).
- Writing a parser or a gate for an existing artifact family (reports, tickets, logs) → count the shapes across all real instances and read the producer's own template first; run it on a real instance, not only fixtures shaped like the parser.
- New security/validation/race guard → ship a test that fails when the guard is reverted, and run the revert. Two causes for one symptom → prove each fix necessary by reverting it alone, plus one end-to-end test through the real client path. A revert counts only if the mutant ran and failed on its own assertion; redundant layers mask a lone revert, so test each layer separately. Run reverts only in a scratch copy, never on tracked files. A fixture equal to the default the code would produce anyway (mode 0600 from `mkstemp`) cannot fail on revert. A race fix needs a stress loop (dozens of trials) plus a deterministic test that holds the lock; a read-then-append on a shared file is check-then-act, so lock the pair.
- A green run where something didn't run proves nothing → treat "command not found", a silent skip, an early exit hidden behind a `grep` filter, or a test file missing from the entrypoint as a failure.
- Git config leaks into tests → pin `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_NOSYSTEM` and `XDG_CONFIG_HOME`. Worktrees share one hooks directory, so a hook finds its checkout with `git rev-parse --show-toplevel`, never from its own path. Ignore a symlink without a trailing slash (`/x/` matches directories only). Pin `HOME`, `TMPDIR`, `XDG_*`, `CANON_HOME` and any variable a wrapper exports (`CANON_TICKETS_DIR` from `evidence.sh`) too, and reproduce a "passes only on my machine" test under `env -i` or `scripts/test-hermetic.sh`. A test of delete/kill code plants a canary in the pinned dirs.

## Security checks and gates

- A hostile-input test must match the sink's context: escaped text in `title="…"` needs a quote-breakout payload (`a"onmouseover="x`), not just `<img onerror>`.
- Widening what a security check allows → re-validate the new value at the point of use; never lean on an earlier check you haven't read, especially for files an agent can write (`.tickets/`).
- A new check that verifies what an older gate accepts must read every line the gate reads (every `^pass:`, not `head -1`), or an extra line walks past it.
- A guard that fails closed then falls through → check what the fall-through *writes*: a transient error (git, network) must not overwrite the state the guard protects. Pin it with a file-content assertion.
- An error must not become a normal-looking result: a failed read is not "absent", a failed `git` call is not "not a repo", and `curl` without `-f` prints an error page as output. Match the one error you expect; let every other one fail.

## Destructive commands and user files

- Async lookup before a destructive action → after the `await`, re-check every precondition (identity, status, liveness), not just the one you guarded; test it by gating the request.
- Command that deletes data or stops processes → its "nothing unsaved" guard lists everywhere git keeps work (dirty tree, unpushed commits on every branch, stash, linked worktrees, skip-worktree edits) and probes each; it refuses when run inside the process it would stop; a prompt between probe and signal is an `await`, so re-verify identity at the signal. Test every rejected spelling.
- Editing a user-owned structured file (JSON/TOML) with `sed`/`awk` → guard the invariant, not the patterns: a signature of everything outside the edited member plus a validity check, and restore the original on any difference.
- Never `pkill`/`kill` by matching a process name, script path, or command-line pattern shared with anything the user might independently be running (a dev server, an agent daemon, a shared script invoked from elsewhere) — a pattern match can hit the user's own live, unrelated process and kill in-progress work with no undo. Resolve the exact PID first (a lockfile/state-file's recorded PID, the port a service publishes, or `$!` from a process this session itself started) and kill only that PID.

## Renames and doc sweeps

- Moving, changing the contract of, retiring or renaming a file or mechanism → sweep every doc surface by concept and paraphrase (cross-references, anchors, README prose, other skills), not only the known phrase; an exact-phrase grep proves only known spots; for a "nothing else" or "already in docs" claim, state the search scope and run it unrestricted (`git grep`, no file-type globs) and recompute counts. A rename by string also hits identifiers that only share the prefix: classify each hit, list the kept ones in `acceptance.md`, and exclude exactly that list from the evidence grep.

## Cross-backend parity

- Cross-backend equality: parse JSON before comparing (`json.dumps` vs `json.Marshal` differ in whitespace); compare bytes only for files. Aim parity fixtures at text edges (trim sets, lone surrogates, invalid UTF-8). For a user-edited file also use valid-but-wrong shapes (`null`, array, scalar), and CR/CRLF: run one hostile line through both ports (bash stripped every CR, PowerShell only trailing ones).

## Windows / Git Bash

- On Windows the Bash tool is Git Bash — unquoted `C:\...` backslashes are escapes (and trip Claude Code's approval prompt). Use forward-slash (`/c/Users/...`) or quoted paths. A suite that has only run on macOS hides host assumptions (real `uname`, `python3`): tests that model a platform stub it (`uname`, `cygpath`), and a skip must be loud. Git Bash spells one directory two ways (`/tmp/x` vs `C:/…/x`): never compare a shell path with a git path or `gitdir:` pointer as strings; use `git rev-parse --show-prefix` and test with a stub that spells it the Windows way.

## Go tests

- Go test with a background goroutine that writes into `t.TempDir()` → teardown waits on the WaitGroup it joins, or `go test` flakes on cleanup; a cached `ok` hides it, so reproduce with `-count=N` and read every failure message.

## Commit messages for prompt changes

- Prompt changes: log the intent (what failure/behavior it fixes), not just the diff — otherwise regression diagnosis across versions is a day of archaeology.

## The always-on context budget

- Keep CLAUDE.md and AGENTS.md concise — rules, gotchas, non-obvious conventions only.
- In Claude Code, run `/context-check` to audit the always-on context budget; it writes a `context-check-report.md` at the project root (after confirmation). The `/context-check` slash command is Claude Code-specific — under Codex, Pi, or headless runs it does not exist; audit the budget manually there.

## Canon only: competitor analysis

- Competitor or adjacent-tool analysis changes how canon should operate → capture it in a skill, standard, guide, or tool behavior before wrapup.

## Workarounds found while fixing

The always-on line keeps the rule; this is its full text.

- A workaround, rendering quirk, or undocumented constraint found while fixing → stage it in `HANDOFF.md ## Discoveries` immediately; route it to its permanent home yourself before wrapup (SKILL.md gotcha, `standards/`, DECISIONS.md, or the repo's bug-pattern log if one exists).
