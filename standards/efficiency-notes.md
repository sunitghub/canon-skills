---
name: efficiency-notes
description: On-demand domain rules moved out of the always-loaded efficiency standard: shell, tests and guards, security gates, destructive commands, renames, parity, Windows, Go
category: agent-ops
tags: [coding, testing, security, shell, windows]
hidden: true
version: 1.0.2
updated: 2026-10-21
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
- Under `pipefail`, `! cmd | grep -q x` can pass *without checking*: `grep -q` exits at the first match and SIGPIPEs the writer, so the pipeline reports non-zero even though it matched, and `!` flips that to success. It only fires when the writer still has output buffered, so a small input hides it and a larger one makes it deterministic. The same holds for `awk '…{exit}'` and `head`: let the reader open the file (`awk … file`), and test with an input larger than the pipe buffer (`t-fef7`, `t-4718`). Safe: `[ "$(cmd | grep -c x)" -eq 0 ]` — keep it inline; hoisting it to `n=$(cmd | grep -c x)` hits the previous trigger, since `grep -c` exits 1 on *zero* matches. A positive `cmd | grep -q x` fails the same way at random under load, which is why the full test run failed suites that passed alone; `tests/pipefail-grep-q.sh` refuses a `| grep -q` written on one line in tests; a pipe split across lines or `| xargs grep -q` is not caught (`t-bcb8`).
- A bare `[[ cond ]] && cmd` as a function's LAST statement returns the `[[ ]]` test's own exit status (1) whenever `cond` is false — under `set -e`, that silently aborts the *caller*, not just skips `cmd`. Easy to miss because the common/expected case (`cond` usually true) never triggers it — it only fires once the false branch becomes reachable, potentially long after the line was written. Safe: wrap in `if`/`fi`, or append `; return 0` / `|| true` after it.
- Anything a function sets inside `$(func)` (an array append, a recorded PID) dies with the subshell, so a later cleanup trap kills nothing. Guard such helpers with `[[ $BASH_SUBSHELL == 0 ]]` (bash 3.2 has no `BASHPID`).
- Shell scripts: a function called in a `||`/`&&`/`if` list runs with `set -e` off, so an unchecked `mv`/`chmod` inside it cannot abort; `mv newdir olddir` onto an existing directory nests; `$((08))` is invalid octal (use `10#$n`). Make temp files with `mktemp` outside the work tree (or gitignore them) and remove them with `trap … EXIT`, not by a call on only the branch you tested.
- A child started under `set -m` (its own process group, so an interrupt can stop all of it) no longer gets the terminal's hangup: trap HUP with INT and TERM. Under `set -e` a trap's last cleanup command can fail (killing an already-dead group) and end the trap before its message: end each cleanup with `|| true`. A script backgrounded from a non-interactive shell inherits SIGINT ignored, so test an interrupt with TERM (`t-bad4`).
- bash 3.2 (macOS): `"${arr[@]}"` on an empty array is an unbound-variable error under `set -u`; use `${arr[@]+"${arr[@]}"}` (`t-1465`). A bare false `[[ … ]]` under `set -e` does not exit there either, so an assert written that way never fails: write `[[ … ]] || fail "…"` (`t-b62a`). `bash -n a b c` checks only `a` (`t-2633`).
- Concurrent `printf >> file` writers tear lines over about 1 KB: append a shared log with one write per line (Go `O_APPEND`) or under a lock (`t-f182`). A flag parser that reads `${2:-}` takes a trailing bare `--tokens` as "not given": check `$# -ge 2` and fail (`t-5ef3`).

## Tests, guards and hermetic runs

- A test failing inside a block your diff touches is not automatically pre-existing/unrelated — diff its failing assertion and target string against the base commit byte-for-byte before excluding it from scope.
- Grade test-count/pass-rate claims (e.g. "121/121 pass") against the actual recomputed total from real command output, not the doc's own summary arithmetic — check specifically for a silently-omitted did-not-run set. Quote a timing only from a run that exited 0 with every suite run (`t-b792`); before cutting tests for speed, measure time per suite (`scripts/test.sh` prints it) and check each "duplicate" an inventory flags against the code, since most tested different behaviour (`t-dd2f`).
- A test asserts against a re-implementation of the logic under test → call the production function instead. A locally rebuilt sort key or a hand-copied constant list passes while the real thing is broken. The same holds for a gate: compare against the real writers' output (replay them), not a copy of their format (`t-52f0`). A check that normalises (indentation, order) cannot see a bug in that dimension: pair it with an exact check on what must not change, and mutate each (`t-565f`).
- A guard exercised only against inputs it already handles is unverified → feed it the cases it must *reject*. Include spellings it has not seen; a match inside a comment does not count. A guard over a list (triggers, patterns) is tested by deleting each entry in turn; a "nothing reads/uses X" scan is proven by planted readers in each spelling (`$ROOT/…`, a variable dir, a JS path) (`t-278d`, `t-0b14`). A "nothing left behind" check (process, file, port) must observe what can leak (record the pid and `kill -0` it): an `lsof` on a stub that never listens passes. Prove it with a mutant that leaks. On macOS `mktemp -d` with no template ignores `TMPDIR`, so a temp-file leak check that pins `TMPDIR` watches an empty directory: give the code a template (`mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX"`).
- A stub must evaluate its input the way the real tool does (a fake `python` that exits 1 on any code hides a dropped version test) and have a mode for each branch the code takes, the fallback included; a stub that returns already-processed output (a `gh` stub returning TSV) never runs the real query or `jq`, so back it with one live read-only run. A per-candidate timeout bounds the wait for one candidate only: two hanging candidates take twice as long (`t-a5f6`, `t-1465`, `t-4cd8`). In a PATH dir of symlinks to real tools, put stubs first and skip their names when linking: `cp` onto a link writes through it into the real binary (`t-90a3`).
- Where PID 1 does not reap orphans (a Claude cloud container), `kill -0` answers alive for a zombie: count a zombie as dead (`ps -o stat=`), falling back to `kill -0` where `ps` has no `-o` (`t-90bc`). Code that runs in a sandbox is tested under the sandbox's limits: a Claude cloud session's GitHub proxy allows REST only, so cloud-side `gh` calls are `gh api` and the test stub refuses GraphQL and the network on that side (`t-35d2`).
- Writing a parser or a gate for an existing artifact family (reports, tickets, logs) → count the shapes across all real instances and read the producer's own template first; run it on a real instance, not only fixtures shaped like the parser. A filter that drops boilerplate must name the boilerplate, not whitelist one content shape (keeping only list items dropped table sections); a line filter over Markdown (`# `, `<!--`, `## `) tracks code fences and position, with one fence rule on both sides of a round trip. Test it against every section shape real files use (lists, tables, prose, fenced code), and test a reader with the writer's real output (`t-a059`, `t-8543`, `t-554c`). A second reader of a field reuses the first reader's normalisation (strip bold: `**YES**`) instead of parsing the raw word (`t-f13a`).
- New security/validation/race guard → ship a test that fails when the guard is reverted, and run the revert. Two causes for one symptom → prove each fix necessary by reverting it alone, plus one end-to-end test through the real client path. A revert counts only if the mutant ran and failed on its own assertion; redundant layers mask a lone revert, so test each layer separately. Run reverts only in a scratch copy, never on tracked files. A fixture equal to the default the code would produce anyway (mode 0600 from `mkstemp`) cannot fail on revert. A "no leak" test of an environment pin also asserts the values that must pass through (`GOMODCACHE`), not only the absence of the pinned ones (`t-eb40`). A race fix needs a stress loop (dozens of trials) plus a deterministic test that holds the lock; a read-then-append on a shared file is check-then-act, so lock the pair.
- A green run where something didn't run proves nothing → treat "command not found", a silent skip, an early exit hidden behind a `grep` filter, or a test file missing from the entrypoint as a failure.
- Git config leaks into tests → pin `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_NOSYSTEM` and `XDG_CONFIG_HOME`. Worktrees share one hooks directory, so a hook finds its checkout with `git rev-parse --show-toplevel`, never from its own path. Ignore a symlink without a trailing slash (`/x/` matches directories only). Pin `HOME`, `TMPDIR`, `XDG_*`, `CANON_HOME` and any variable a wrapper exports (`CANON_TICKETS_DIR` from `evidence.sh`) too, and reproduce a "passes only on my machine" test under `env -i` or `scripts/test-hermetic.sh`. A test of delete/kill code plants a canary in the pinned dirs. A test that runs git in a temp dir unsets `GIT_DIR`, `GIT_INDEX_FILE` and `GIT_WORK_TREE`: a hook hands them down, and `GIT_DIR` only from a linked worktree; a hook cleans only the child it starts. A test that writes under its own root runs on a scratch copy with a canary (`t-1cfc`, `t-ce0b`, `t-65c9`).
- A fixture named for a kind (a worktree, a CRLF file, a subfolder project) is a real one (`git worktree add`, not a plain folder); git-aware code is tested from a linked worktree and from a project subdirectory, and asks the caller's worktree, not the main checkout (`t-21f7`, `t-1b74`).
- Changing a test's expected value to match new code → name which user's answer changed; if it is the common case, it is a regression (`t-12f8`).
- A test wait that hits its deadline fails loudly rather than continuing, and a "no new flakes" criterion needs a run on the base commit first (`-race` was already red on main) (`t-67a6`).
- Write assertions that can see the bug: a command that publishes is checked against the source of truth (origin's merged head), not the local copy; a captured exit code is asserted with the output; an event test asserts right after the transition that must cause it, and that the event is absent before (`t-24b1`, `t-1cf5`, `t-8854`).
- A test that locks wording anchors each phrase to the line that prints it (echo, die, throw), not help text or comments, and asserts every clause, verb and condition included; a mutant removes or flips exactly one fact (`t-153f`, `t-ce0b`, `t-1cf4`).
- A new ignore rule for a path that may already be tracked: `git rm --cached` it, and add a check that fails when a tracked path matches (`git ls-files -ci --exclude-standard`) (`t-fc00`).

## Security checks and gates

- A hostile-input test must match the sink's context: escaped text in `title="…"` needs a quote-breakout payload (`a"onmouseover="x`), not just `<img onerror>`.
- Widening what a security check allows → re-validate the new value at the point of use; never lean on an earlier check you haven't read, especially for files an agent can write (`.tickets/`). A flag that supplies a fact (`--pr N`) still passes the check that fact stood for (the ticket was imported): the check reads the ticket, not the flag. An allow-list of names admits by name only, so also check the type (a symlink under an allowed name), scope it to the one subject (`.tickets/<id>/`), and refuse dotfile parts (`t-c259`, `t-fdb1`).
- A new check that verifies what an older gate accepts must read every line the gate reads (every `^pass:`, not `head -1`), or an extra line walks past it.
- A guard that fails closed then falls through → check what the fall-through *writes*: a transient error (git, network) must not overwrite the state the guard protects. Pin it with a file-content assertion.
- An error must not become a normal-looking result: a failed read is not "absent", a failed `git` call is not "not a repo", and `curl` without `-f` prints an error page as output. Match the one error you expect; let every other one fail.
- Text from a clone, an issue or a pushed branch is untrusted input to a local command: validate any id before building a path from it, refuse to write through symlinks under the target, and check repo visibility before pushing notes. When a filter admits untrusted input (a label), take the admission fact and the content from one read: a label check then a second body fetch is a TOCTOU gap. Strip C0, DEL and UTF-8 C1 control bytes from anything echoed (`t-554c`, `t-4cd8`). Refuse input a parser could misread (a log name `z exit=0 y.log`) rather than parsing around it (`t-a3d7`).
- Running a project's tests on a PR is running the PR's code: ask before it, and take the test command from the base branch so the PR cannot switch its own gate off. For an irreversible action, re-check the outcome on failure (`gh` can error after GitHub merged) (`t-4718`).
- Put a gate where every route passes (a hook), not in one command, and list the routes around it (push by URL, a child that reads the hook's stdin). A guard that cannot run (script missing, older checkout) refuses, and it judges the commit being published, not the working tree (`t-4ea4`, `t-b6b6`).
- Before tightening a shared escaper, list callers that escape a whole document and then parse it (`md()`'s image pass), and decode what they extract; a "none left" sweep searches the whole pattern, not only the same-expression form (`t-d2e1`).
- Before publishing, look at every image (blurs leak a private tab); a guard that bans a string builds it from parts, so the guard file does not reintroduce it (`t-afe2`).

## Destructive commands and user files

- Async lookup before a destructive action → after the `await`, re-check every precondition (identity, status, liveness), not just the one you guarded; test it by gating the request.
- Command that deletes data or stops processes → its "nothing unsaved" guard lists everywhere git keeps work (dirty tree, unpushed commits on every branch, stash, linked worktrees, skip-worktree edits) and probes each; it refuses when run inside the process it would stop; a prompt between probe and signal is an `await`, so re-verify identity at the signal. Test every rejected spelling.
- Before an irreversible delete, check the keep-rule against the shapes real data uses (docs cite evidence as a folder or a wildcard, not only a path): a dry run that shares the real run's rule cannot reveal that rule's gaps. A "nothing else was lost" claim comes from checking every affected item, not from one search pattern (`t-2fb6`).
- Editing a user-owned structured file (JSON/TOML) with `sed`/`awk` → guard the invariant, not the patterns: a signature of everything outside the edited member plus a validity check, and restore the original on any difference. A managed-block edit (BEGIN/END markers) changes only lines between them, matches the markers with a trailing `\r` stripped, and says "added" only when the file changed; its tests include a user line outside the block and a CRLF file (`t-5c4b`).
- Never `pkill`/`kill` by matching a process name, script path, or command-line pattern shared with anything the user might independently be running (a dev server, an agent daemon, a shared script invoked from elsewhere) — a pattern match can hit the user's own live, unrelated process and kill in-progress work with no undo. Resolve the exact PID first (a lockfile/state-file's recorded PID, the port a service publishes, or `$!` from a process this session itself started) and kill only that PID.

## Renames and doc sweeps

- Moving, changing the contract of, retiring or renaming a file or mechanism → sweep every doc surface by concept and paraphrase (cross-references, anchors, README prose, other skills), not only the known phrase; an exact-phrase grep proves only known spots; for a "nothing else" or "already in docs" claim, state the search scope and run it unrestricted (`git grep`, no file-type globs) and recompute counts. A rename by string also hits identifiers that only share the prefix: classify each hit, list the kept ones in `acceptance.md`, and exclude exactly that list from the evidence grep. A doc claim about a UI or a tool's flow is checked against the surface the reader sees (render it) and the tool's own printed next step (`t-e6d2`).

## Cross-backend parity

- Cross-backend equality: parse JSON before comparing (`json.dumps` vs `json.Marshal` differ in whitespace); compare bytes only for files. Aim parity fixtures at text edges (trim sets, lone surrogates, invalid UTF-8). For a user-edited file also use valid-but-wrong shapes (`null`, array, scalar), and CR/CRLF: run one hostile line through both ports (bash stripped every CR, PowerShell only trailing ones).

## Platforms

canon runs on four: every session's AGENTS.md carries a one-line pointer here (tools/skills/agents.sh, t-5c4b).

- **Windows: Git Bash only.** canon's commands run in Git Bash, never PowerShell or cmd (a `.cmd` wrapper runs bash for you).
  The Bash tool is Git Bash: unquoted `C:\...` backslashes are escapes (and trip Claude Code's approval prompt). Use forward-slash (`/c/Users/...`) or quoted paths. A suite that has only run on macOS hides host assumptions (real `uname`, `python3`): tests that model a platform stub it (`uname`, `cygpath`), and a skip must be loud. Git Bash spells one directory two ways (`/tmp/x` vs `C:/…/x`): never compare a shell path with a git path or `gitdir:` pointer as strings; use `git rev-parse --show-prefix` and test with a stub that spells it the Windows way.
- **macOS:** bash 3.2 and BSD tools: `sed -i ''`, `date -j -f`, `stat -f`, `touch -t`; write portable forms with a GNU
  fallback (`date -u -d … 2>/dev/null || date -j -u -f …`). `wc -w` counts differently from GNU's (t-35a7).
- **Linux:** GNU coreutils and bash 5; the reference for CI.
- **Claude cloud container:** Linux, running as root, so `chmod` cannot make a folder unwritable (point a test at a path
  under a regular file instead); set it up with `tkt cloud-env` (domains, setup script). It is no stand-in for a performance symptom: profile on the OS that shows it, with its real gitignored data (the cloud and a clone both measured 0 tickets) (`t-1699`, `t-3b90`).

## Go

- A server that follows a child's output reads fixed chunks, not lines: `bufio.Scanner` stops at its token limit and leaves the pipe full, so the child blocks and the job reads running forever. A stop must reach the whole process tree (Windows: `taskkill /T`; killing the `tkt.cmd` wrapper leaves bash running), and a per-key handle is cleared when a new run starts so a stop cannot hit the previous finished command (`t-d271`).
- Go test with a background goroutine that writes into `t.TempDir()` → teardown waits on the WaitGroup it joins, or `go test` flakes on cleanup; a cached `ok` hides it, so reproduce with `-count=N` and read every failure message.
- Go ignores SIGALRM, so `perl -e 'alarm N; exec …'` cannot time-limit a Go binary: fork, then SIGKILL the child (`t-8020`). Any new file under a released Go module's folder, a `_test.go` included, changes its source key (`tools/src-key.sh`) and needs a new binary release: check it before committing, or keep the file outside the folder (`t-15d8`).

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
