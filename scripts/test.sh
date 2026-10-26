#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# t-269d: the Go board server opens the developer's real browser at startup unless this is set; every test
# that starts it would otherwise open real tabs (tests/no-browser-in-tests.sh keeps each script honest too).
export SPRINT_CHECK_NO_BROWSER=1
# t-2d74: skills.sh prompts through /dev/tty, so a run from a real terminal stopped for a 15s prompt per
# temp project. The pty-simulated prompt tests unset this for their own child.
export SKILLS_SH_NO_TTY=1
# t-9791: a git that needs credentials prompts on /dev/tty; a suite in the batch's background process group then gets SIGTTOU
# when git turns off echo, and the whole group stops. That is what hung the board's Check & merge (it runs this on a pty). Never prompt.
export GIT_TERMINAL_PROMPT=0
# t-f182: tkt, sprint and the board append events to $CANON_HOME/events; a test run never writes into the user's own log.
# One folder for the run, unless the caller pinned one (a test that needs the default sets CANON_HOME= for its child).
if [[ -z "${CANON_HOME:-}" ]]; then CANON_HOME="$(mktemp -d "${TMPDIR:-/tmp}/canon-test-home.XXXXXX")"; export CANON_HOME; fi

# t-2633: `--list` prints every suite label, one per line: the one list of what this script runs (scripts/test-hermetic.sh reads it).
# t-abb1: suites run in parallel, `--jobs N` workers (default: the CPU count, at most 8); `--jobs 1` is the sequential run, which stops
# at the first failure. A parallel run runs every suite and exits with the first failing suite's code in list order.
LIST=0; JOBS=""; JOBS_GIVEN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST=1; shift ;;
    --jobs) if [[ $# -lt 2 ]]; then echo "test.sh: --jobs needs a positive number" >&2; exit 2; fi; JOBS="$2"; JOBS_GIVEN=1; shift 2 ;;
    -h|--help) echo "usage: scripts/test.sh [--list] [--jobs N]   (--list prints every suite label, one per line; --jobs 1 runs them one at a time)"; exit 0 ;;
    *) echo "test.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
if (( ! JOBS_GIVEN )); then
  JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"
  [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || JOBS=1
  (( JOBS <= 8 )) || JOBS=8
elif [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then echo "test.sh: --jobs needs a positive number" >&2; exit 2
fi

tests=(
  "$ROOT/tests/tkt.sh"
  "$ROOT/tests/tkt-compact.sh"
  "$ROOT/tests/tkt-send-issue.sh"
  "$ROOT/tests/cloud-round-trip.sh"
  "$ROOT/tests/tkt-export-warn.sh"
  "$ROOT/tests/tkt-github-doctor.sh"
  "$ROOT/tests/cloud-env.sh"
  "$ROOT/tests/tkt-sync-issues.sh"
  "$ROOT/tests/tkt-merge-pr.sh"
  "$ROOT/tests/tkt-land.sh"
  "$ROOT/tests/tkt-take-back.sh"
  "$ROOT/tests/tkt-github-status.sh"
  "$ROOT/tests/tkt-open-pr.sh"
  "$ROOT/tests/tkt-push-main.sh"
  "$ROOT/tests/tkt-worktree-reset.sh"
  "$ROOT/tests/sprint-check-github-endpoints.sh"
  "$ROOT/tests/tool-symlinks.sh"
  "$ROOT/tests/agent-template.sh"
  "$ROOT/tests/ticket-skeleton.sh"
  "$ROOT/tests/sprint.sh"
  "$ROOT/tests/ticket-root-worktree.sh"
  "$ROOT/tests/frontmatter-lib.sh"
  "$ROOT/tests/skills-add-sprint.sh"
  "$ROOT/tests/skills-sprint-deps.sh"
  "$ROOT/tests/sprint-check-nongit.sh"
  "$ROOT/tests/skills-model-tiers-note.sh"
  "$ROOT/tests/skills-not-commands.sh"
  "$ROOT/tests/skills-subagent-log-permission.sh"
  "$ROOT/tests/skills-assume-yes.sh"
  "$ROOT/tests/skills-refresh.sh"
  "$ROOT/tests/skills-uninstall.sh"
  "$ROOT/tests/worktree-suites.sh"
  "$ROOT/tests/skills-mirror-gitignore.sh"
  "$ROOT/tests/skills-agents.sh"
  "$ROOT/tests/windows-no-python.sh"
  "$ROOT/tests/windows-install.sh"
  "$ROOT/tests/canon-version.sh"
  "$ROOT/tests/cockpit-nongit-wording.sh"
  "$ROOT/tests/cockpit-launch-lib.sh"
  "$ROOT/tests/no-python-windows-paths.sh"
  "$ROOT/tests/git-precommit-chain.sh"
  "$ROOT/tests/hooks-lib-settings.sh"
  "$ROOT/tests/git-precommit-hook.sh"
  "$ROOT/tests/post-commit-worktree.sh"
  "$ROOT/tests/prefix-keys-parity.sh"
  "$ROOT/tests/subagent-log-cli.sh"
  "$ROOT/tests/sprint-gate-cost.sh"
  "$ROOT/tests/skills-std.sh"
  "$ROOT/tests/install-target.sh"
  "$ROOT/tests/install-sh.sh"
  "$ROOT/tests/local-only-dirs.sh"
  "$ROOT/tests/plugin-eval-gen.sh"
  "$ROOT/tests/skill-check.sh"
  "$ROOT/tests/sprint-check-skill-eval.sh"
  "$ROOT/tests/sprint-check-skill-eval-go.sh"
  "$ROOT/tests/skill-eval-parity.sh"
  "$ROOT/tests/skill-eval-scope.sh"
  "$ROOT/tests/mutant-sweep.sh"
  "$ROOT/tests/sprint-checklists.sh"
  "$ROOT/tests/machine-load-unit.sh"
  "$ROOT/tests/run-board-spec-isolation.sh"
  "$ROOT/tests/evidence.sh"
  "$ROOT/tests/work-beat.sh"
  "$ROOT/tests/folder-guard.sh"
  "$ROOT/tests/sprint-check-evidence.sh"
  "$ROOT/tests/test-sh-runner.sh"
  "$ROOT/tests/build-zip-go-package.sh"
  "$ROOT/tests/sprint-check-server.sh"
  "$ROOT/tests/sprint-check-cockpit.sh"
  "$ROOT/tests/sprint-check-interrupted.sh"
  "$ROOT/tests/canon-cli.sh"
  "$ROOT/tests/canon-update.sh"
  "$ROOT/tests/canon-uninstall.sh"
  "$ROOT/tests/fetch-daemon.sh"
  "$ROOT/tests/fetch-win-binaries.sh"
  "$ROOT/tests/check-binaries-released.sh"
  "$ROOT/tests/src-key.sh"
  "$ROOT/tests/events.sh"
  "$ROOT/tests/release-daemon-publish.sh"
  "$ROOT/tests/release.sh"
  "$ROOT/tests/release-zip-slim.sh"
  "$ROOT/tests/integrity-list.sh"
  "$ROOT/tests/sprint-integrity.sh"
  "$ROOT/tests/gate-clusters.sh"
  "$ROOT/tests/release-zip.sh"
  "$ROOT/tests/release-manifest.sh"
  "$ROOT/tests/dead-code-scan.sh"
  "$ROOT/tests/sprint-gate-agents.sh"
  "$ROOT/tests/doc-check.sh"
  "$ROOT/tests/pre-push-release.sh"
  "$ROOT/tests/sprint-check-worktrees.sh"
  "$ROOT/tests/sprint-check-ticket-commit.sh"
  "$ROOT/tests/sprint-check-track-changes.sh"
  "$ROOT/tests/board-origin-guard.sh"
  "$ROOT/tests/sprint-check-worktree-holds.sh"
  "$ROOT/tests/sprint-check-live-docs.sh"
  "$ROOT/tests/sprint-check-live-ticket.sh"
  "$ROOT/tests/helpers-sweep.sh"
  "$ROOT/tests/sprint-check-api.sh"
  "$ROOT/tests/theme-files-parity.sh"
  "$ROOT/tests/board-branch-divergence.sh"
  "$ROOT/tests/canon.sh"
  "$ROOT/tests/no-browser-in-tests.sh"
  "$ROOT/tests/pipefail-early-exit.sh"
  "$ROOT/tests/pipefail-rewrites.sh"
  "$ROOT/tests/pi-gate-recipe.sh"
  "$ROOT/tests/ci-security-config.sh"
  "$ROOT/tests/model-registry-parity.sh"
  "$ROOT/tests/vendored-manifest.sh"
  "$ROOT/tests/check-vendored.sh"
  "$ROOT/tests/ticket-tags.sh"
  "$ROOT/tests/sprint-check-delegate.sh"
  "$ROOT/tests/doc-mirror-parity.sh"
  "$ROOT/tests/doc-update-behavior.sh"
  "$ROOT/tests/gate-model-parity.sh"
  "$ROOT/tests/gate-ticket-check.sh"
  "$ROOT/tests/git-read.sh"
  "$ROOT/tests/gate-snapshot.sh"
  "$ROOT/tests/jtbd-routing.sh"
  "$ROOT/tests/why-cap.sh"
  "$ROOT/tests/sprint-headless.sh"
  "$ROOT/tests/sprint-headless-eval-tools.sh"
  "$ROOT/tests/sprint-headless-eval-criteria-only.sh"
)

# t-8765: a test that backgrounds a board server and doesn't kill it leaks it past the run (a subshell-
# captured PID once orphaned two servers per run, ~240 across a session): fail if the run leaves one running.
# t-72e9: only this run's own. pgrep is machine-wide, so every suite inherits CANON_TEST_RUN and a server
# counts only if it started with exactly this run's value; one started by anything else (a developer's own
# board, a concurrent board spec or test run) never does. Every suite has ended by the check, so any server
# of ours still running is a leak, orphaned or not (a leaked wrapper can still be its parent).
_server_pids() { { pgrep -f 'sprint-check-bin/sprint-check' 2>/dev/null || true; } | sort -u; }
CANON_TEST_RUN="$$.$(date +%s).$RANDOM"; export CANON_TEST_RUN
# t-f151: grep, not grep -q: under pipefail an early-exiting grep -q SIGPIPEs tr and reports a found marker as a miss (43/1000 under load).
_ours() {   # _ours <pid>: the process started with exactly this run's CANON_TEST_RUN (an unreadable one is not ours)
  if [[ -r "/proc/$1/environ" ]]; then tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | grep -xF "CANON_TEST_RUN=$CANON_TEST_RUN" >/dev/null
  else ps -wwE -o command= -p "$1" 2>/dev/null | tr ' ' '\n' | grep -xF "CANON_TEST_RUN=$CANON_TEST_RUN" >/dev/null
  fi
}
_leaked_servers() {
  local p
  for p in $(_server_pids); do
    if _ours "$p"; then printf '%s ' "$p"; fi
  done
  return 0
}

# suite <label> <command...> — prints the `==> <label>` header, runs the command, records its whole-second wall time (t-2633). In the
# dry pass it only records the label, so --list prints this same sequence, never a second copy of it.
TIMES=(); LABELS=(); CURRENT=""; CURRENT_T0=0; DRY=0
PLAN=0; KINDS=(); CMDS=()   # t-abb1: the planning pass records each suite's command for the parallel run, and skip lines in place
suite() {
  local label="$1"; shift
  if (( DRY )); then LABELS+=("$label"); return 0; fi
  if (( PLAN )); then LABELS+=("$label"); KINDS+=(suite); CMDS+=("$(printf '%q ' "$@")"); return 0; fi
  printf '==> %s\n' "$label"
  CURRENT="$label"; CURRENT_T0=$SECONDS
  "$@"
  TIMES+=("$((SECONDS - CURRENT_T0)) $label"); CURRENT=""
}
print_timings() {   # an EXIT trap: the run's own exit status stands, whatever this returns
  if [[ -n "$CURRENT" ]]; then TIMES+=("$((SECONDS - CURRENT_T0)) $CURRENT (failed)"); fi
  if (( ${#TIMES[@]} )); then
    printf '\n== suite times (s), in run order\n'; printf '%s\n' "${TIMES[@]}"
    printf '== slowest 10 (s)\n'; printf '%s\n' "${TIMES[@]}" | sort -rn | head -10
    printf '== total %ss for %s suite(s)\n' "$SECONDS" "${#TIMES[@]}"
  fi
}
# skipped <line> — a `==> <line>` note for a suite whose tool is absent; the parallel run prints it in its place.
skipped() {
  if (( PLAN )); then LABELS+=("$1"); KINDS+=(skip); CMDS+=(""); return 0; fi
  printf '==> %s\n' "$1"
}
go_board() { (cd "$ROOT/tools/canon-go" && go test ./cmd/... ./internal/board ./internal/common ./internal/events ./internal/term); }   # t-8020: one module
go_daemon() { (cd "$ROOT/tools/canon-go" && go test ./internal/daemon); }

run_all() {
for test_file in "${tests[@]}"; do
  suite "${test_file#$ROOT/}" bash "$test_file"
done

if (( DRY )) || command -v go >/dev/null 2>&1; then
  suite tools/canon-go/internal/board go_board
  suite tools/canon-go/internal/daemon go_daemon
else
  skipped "tools/canon-go/internal/board skipped (go absent)"
  skipped "tools/canon-go/internal/daemon skipped (go absent)"
fi

if (( DRY )) || command -v node >/dev/null 2>&1; then
  suite tests/sprint-check-gherkin.js node "$ROOT/tests/sprint-check-gherkin.js"
  suite tests/sprint-check-editor.js node "$ROOT/tests/sprint-check-editor.js"
  suite tests/sprint-check-seed.js node "$ROOT/tests/sprint-check-seed.js"
  suite tests/sprint-check-handoff-state.js node "$ROOT/tests/sprint-check-handoff-state.js"
  suite tests/sprint-check-status-badge.js node "$ROOT/tests/sprint-check-status-badge.js"
  suite tests/sprint-check-worktree-chip.js node "$ROOT/tests/sprint-check-worktree-chip.js"
  suite tests/sprint-check-esc.js node "$ROOT/tests/sprint-check-esc.js"
  suite tests/sprint-check-md.js node "$ROOT/tests/sprint-check-md.js"
  suite tests/sprint-check-theme.js node "$ROOT/tests/sprint-check-theme.js"
  suite tests/prefix-keys.js node "$ROOT/tests/prefix-keys.js"
  suite tests/board-spec-guard-unit.js node "$ROOT/tests/board-spec-guard-unit.js"
  suite tests/board-spec-classify-unit.js node "$ROOT/tests/board-spec-classify-unit.js"
  suite tests/board-spec-ids-unit.js node "$ROOT/tests/board-spec-ids-unit.js"
  suite tests/split-handle-unit.js node "$ROOT/tests/split-handle-unit.js"
  suite tests/sprint-check-api-scoping.js node "$ROOT/tests/sprint-check-api-scoping.js"
else
  skipped "tests/sprint-check-gherkin.js skipped (node absent)"
fi
return 0
}

# run_parallel — t-abb1. Plans every suite, starts them through `xargs -P "$JOBS"` (each with its own log, exit-code file and TMPDIR, so
# a fixed temp name in one suite cannot meet another's), then prints each suite's block in list order as soon as it and every earlier
# one are done. SERIAL suites run alone after the batch. Sets FIRST_RC to the first failing suite's code in list order.
SERIAL=(   # --list labels that share state with another suite, each with its reason; filled only from measured collisions
  # each deletes, on exit, every $ROOT/.canon-cache/skill-eval/ folder it did not see at its start: run alongside each other (or the
  # board's Go suite, which writes there too), one removes another's live run folder (sprint-check-skill-eval's report 404'd in a stamp)
  tests/sprint-check-skill-eval.sh
  tests/sprint-check-skill-eval-go.sh
  tests/skill-eval-parity.sh
)
# Suites started first (t-b792): xargs starts the batch in file order, so a slow suite that sits late in list order starts late and sets the
# wall time (test-sh-runner.sh was 53rd and started about a minute in). Longest first, from the `== slowest 10` block of a full run; a stale
# entry costs speed only. Printing, --list and the exit code stay in list order.
LONGEST=(tests/test-sh-runner.sh tools/canon-go/internal/daemon tests/canon-update.sh tests/sprint-check-live-docs.sh tests/canon-uninstall.sh
  tests/sprint.sh tests/evidence.sh)
run_parallel() {
  local i n s w t hit
  local -a B=()
  PLAN=1; run_all; PLAN=0
  t="${TMPDIR:-/tmp}"   # macOS's TMPDIR ends in "/": a "//" in a suite's TMPDIR breaks Go tests that string-compare t.TempDir() paths
  RUN="$(mktemp -d "${t%/}/test-sh-run.XXXXXX")"; mkdir -p "$RUN/jobs" "$RUN/tmp"
  export ROOT RUN; export -f go_board go_daemon
  cat > "$RUN/worker.sh" <<'WORKER'
i="$1"; cmd="$(cat "$RUN/jobs/$i.cmd")"
export TMPDIR="$RUN/tmp/$i"; mkdir -p "$TMPDIR"
s=$(date +%s); rc=0
( eval "$cmd" ) > "$RUN/jobs/$i.log" 2>&1 < /dev/null || rc=$?
echo "$(( $(date +%s) - s ))" > "$RUN/jobs/$i.time"; echo "$rc" > "$RUN/jobs/$i.rc.part"; mv "$RUN/jobs/$i.rc.part" "$RUN/jobs/$i.rc"
WORKER
  n=${#LABELS[@]}; : > "$RUN/batch"; : > "$RUN/serial"
  for (( i = 0; i < n; i++ )); do
    [[ "${KINDS[$i]}" == suite ]] || continue
    printf '%s' "${CMDS[$i]}" > "$RUN/jobs/$i.cmd"
    s=0; for w in "${SERIAL[@]:-}"; do if [[ "$w" == "${LABELS[$i]}" ]]; then s=1; fi; done
    if (( s )); then echo "$i" >> "$RUN/serial"; else B+=("$i"); fi
  done
  for w in "${LONGEST[@]}"; do
    for i in ${B[@]+"${B[@]}"}; do if [[ "${LABELS[$i]}" == "$w" ]]; then echo "$i" >> "$RUN/batch"; fi; done
  done
  for i in ${B[@]+"${B[@]}"}; do
    hit=0; for w in "${LONGEST[@]}"; do if [[ "${LABELS[$i]}" == "$w" ]]; then hit=1; fi; done
    if (( ! hit )); then echo "$i" >> "$RUN/batch"; fi
  done
  set -m   # the batch gets its own process group, so stop_workers can stop every process a suite started, not only the workers
  xargs -P "$JOBS" -n 1 bash "$RUN/worker.sh" < "$RUN/batch" &
  XARGS_PID=$!; set +m
  print_block() {   # print_block <index>: wait for that suite's exit code, then print its block and record its time
    local i="$1" rc t
    while [[ ! -f "$RUN/jobs/$i.rc" ]]; do sleep 0.2; done
    rc="$(cat "$RUN/jobs/$i.rc")"; t="$(cat "$RUN/jobs/$i.time")"
    printf '==> %s\n' "${LABELS[$i]}"; cat "$RUN/jobs/$i.log"
    if [[ "$rc" == 0 ]]; then TIMES+=("$t ${LABELS[$i]}")
    else TIMES+=("$t ${LABELS[$i]} (failed)"); FAILED+=("${LABELS[$i]} (exit $rc)"); if (( FIRST_RC == 0 )); then FIRST_RC="$rc"; fi; fi
  }
  for (( i = 0; i < n; i++ )); do
    if [[ "${KINDS[$i]}" == skip ]]; then printf '==> %s\n' "${LABELS[$i]}"; continue; fi
    if grep -qx "$i" "$RUN/serial"; then continue; fi
    print_block "$i"
  done
  wait "$XARGS_PID" 2>/dev/null || true; XARGS_PID=""
  while IFS= read -r i; do
    bash "$RUN/worker.sh" "$i"; print_block "$i"
  done < "$RUN/serial"
  return 0
}
stop_workers() {   # on any exit: stop a batch still running (an interrupted run) and remove its folder
  if [[ -n "${XARGS_PID:-}" ]]; then kill -TERM -- "-$XARGS_PID" 2>/dev/null || true; fi
  if [[ -n "${RUN:-}" ]]; then case "$RUN" in */test-sh-run.*) rm -rf -- "$RUN" ;; esac; fi
}

if (( LIST )); then DRY=1; run_all; printf '%s\n' "${LABELS[@]}"; exit 0; fi
trap 'stop_workers; print_timings' EXIT
FIRST_RC=0; FAILED=(); XARGS_PID=""; RUN=""
if (( JOBS == 1 )); then run_all; else run_parallel; fi

# Give a server that was just killed a few seconds to actually exit before calling it a leak.
for _ in 1 2 3 4 5; do
  sleep 1
  LEAKED_SERVERS="$(_leaked_servers)"
  [[ -z "${LEAKED_SERVERS// /}" ]] && break
done
if (( ${#FAILED[@]} )); then
  { printf '\n'; printf 'FAILED: %s\n' "${FAILED[@]}"; } >&2
fi
if [[ -n "${LEAKED_SERVERS// /}" ]]; then
  printf '\nFAIL: the test run left sprint-check servers running (PIDs): %s\n' "$LEAKED_SERVERS" >&2
  exit 1
fi
if (( FIRST_RC != 0 )); then exit "$FIRST_RC"; fi

printf '\nAll tests passed.\n'
