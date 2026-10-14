#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# t-269d: the Go board server opens the developer's real browser at startup unless this is set; every test
# that starts it would otherwise open real tabs (tests/no-browser-in-tests.sh keeps each script honest too).
export SPRINT_CHECK_NO_BROWSER=1
# t-2d74: skills.sh prompts through /dev/tty, so a run from a real terminal stopped for a 15s prompt per
# temp project. The pty-simulated prompt tests unset this for their own child.
export SKILLS_SH_NO_TTY=1

# t-2633: `--changed [<base>]` runs only the suites a change can reach (scripts/test-select.sh), for the builder between commits.
# It is never the close stamp: evidence.sh refuses to stamp it, and the full run stays the evidence a gate reads.
CHANGED=0; CHANGED_BASE=""; LIST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --changed) CHANGED=1; shift; if [[ $# -gt 0 && "$1" != -* ]]; then CHANGED_BASE="$1"; shift; fi ;;
    --list) LIST=1; shift ;;
    -h|--help) echo "usage: scripts/test.sh [--changed [<base>] | --list]   (base defaults to git merge-base HEAD origin/main; --list prints every suite label, one owner of the list)"; exit 0 ;;
    *) echo "test.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

tests=(
  "$ROOT/tests/tkt.sh"
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
  "$ROOT/tests/hooks-lib-settings.sh"
  "$ROOT/tests/git-precommit-hook.sh"
  "$ROOT/tests/post-commit-worktree.sh"
  "$ROOT/tests/prefix-keys-parity.sh"
  "$ROOT/tests/subagent-log-cli.sh"
  "$ROOT/tests/disposable-cred.sh"
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
  "$ROOT/tests/evidence.sh"
  "$ROOT/tests/sprint-check-evidence.sh"
  "$ROOT/tests/test-sh-changed.sh"
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
  "$ROOT/tests/release-daemon-publish.sh"
  "$ROOT/tests/release.sh"
  "$ROOT/tests/release-zip.sh"
  "$ROOT/tests/release-manifest.sh"
  "$ROOT/tests/sprint-check-upkeep.sh"
  "$ROOT/tests/upkeep-skill-hash-parity.sh"
  "$ROOT/tests/sprint-check-worktrees.sh"
  "$ROOT/tests/sprint-check-ticket-commit.sh"
  "$ROOT/tests/sprint-check-track-changes.sh"
  "$ROOT/tests/board-origin-guard.sh"
  "$ROOT/tests/sprint-check-worktree-holds.sh"
  "$ROOT/tests/sprint-check-live-docs.sh"
  "$ROOT/tests/sprint-check-live-ticket.sh"
  "$ROOT/tests/helpers-sweep.sh"
  "$ROOT/tests/sprint-check-app.sh"
  "$ROOT/tests/sprint-check-api-parity.sh"
  "$ROOT/tests/theme-files-parity.sh"
  "$ROOT/tests/board-branch-divergence.sh"
  "$ROOT/tests/registry.sh"
  "$ROOT/tests/canon.sh"
  "$ROOT/tests/no-browser-in-tests.sh"
  "$ROOT/tests/sprint-check-delegate.sh"
  "$ROOT/tests/doc-mirror-parity.sh"
  "$ROOT/tests/doc-update-behavior.sh"
  "$ROOT/tests/gate-model-parity.sh"
  "$ROOT/tests/gate-snapshot.sh"
  "$ROOT/tests/jtbd-routing.sh"
  "$ROOT/tests/why-cap.sh"
  "$ROOT/tests/sprint-headless.sh"
  "$ROOT/tests/sprint-headless-eval-tools.sh"
  "$ROOT/tests/sprint-headless-eval-criteria-only.sh"
)

# t-8765: a test that backgrounds a board server and doesn't kill it leaks it past the run (a subshell-
# captured PID once orphaned two servers per run, ~240 across a session). Snapshot the server PIDs first
# and fail if the run leaves NEW ones — servers already running (a developer's own board) are ignored.
_server_pids() { { pgrep -f 'sprint-check-app/server\.py|sprint-check-go-bin' 2>/dev/null || true; } | sort -u; }
SERVERS_BEFORE="$(_server_pids)"
# pgrep is machine-wide, so a concurrent run's LIVE server (or a build in another worktree) also shows up
# as "new". A leaked server is an ORPHAN: its test script exited, so it was reparented to PID 1. Only
# count those; a live server still has its own script as parent.
_new_orphan_servers() {
  local p
  for p in $(comm -13 <(printf '%s\n' "$SERVERS_BEFORE") <(_server_pids)); do
    [[ "$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" == 1 ]] && printf '%s ' "$p"
  done
  return 0
}

# suite <label> <command...> — prints the `==> <label>` header, runs the command, records its whole-second wall time (t-2633). In the
# dry pass it only records the label, so the label list --changed selects from is this same sequence, never a second copy of it.
TIMES=(); LABELS=(); RAN=0; SKIPPED=0; CURRENT=""; CURRENT_T0=0; DRY=0
suite() {
  local label="$1"; shift
  if (( DRY )); then LABELS+=("$label"); return 0; fi
  if (( CHANGED )) && ! select_suite "$label"; then printf '==> %s skipped (--changed)\n' "$label"; SKIPPED=$((SKIPPED + 1)); return 0; fi
  printf '==> %s\n' "$label"
  CURRENT="$label"; CURRENT_T0=$SECONDS
  "$@"
  TIMES+=("$((SECONDS - CURRENT_T0)) $label"); RAN=$((RAN + 1)); CURRENT=""
}
print_timings() {   # an EXIT trap: the run's own exit status stands, whatever this returns
  if [[ -n "$CURRENT" ]]; then TIMES+=("$((SECONDS - CURRENT_T0)) $CURRENT (failed)"); fi
  if (( ${#TIMES[@]} )); then
    printf '\n== suite times (s), in run order\n'; printf '%s\n' "${TIMES[@]}"
    printf '== slowest 10 (s)\n'; printf '%s\n' "${TIMES[@]}" | sort -rn | head -10
    printf '== total %ss for %s suite(s)\n' "$SECONDS" "${#TIMES[@]}"
  fi
  if (( CHANGED )); then printf 'PARTIAL RUN (--changed): ran %s, skipped %s — not a close stamp\n' "$RAN" "$SKIPPED"; fi
  if declare -F select_cleanup >/dev/null; then select_cleanup; fi
}
go_board() { (cd "$ROOT" && GO111MODULE=off go test ./tools/sprint-check-go); }
go_headless_json() { (cd "$ROOT" && GO111MODULE=off go test ./tools/sprint-headless-json-go); }
go_daemon() { (cd "$ROOT/tools/cockpit-daemon" && go test ./...); }

run_all() {
for test_file in "${tests[@]}"; do
  suite "${test_file#$ROOT/}" bash "$test_file"
done

if (( DRY )) || command -v go >/dev/null 2>&1; then
  suite tools/sprint-check-go go_board
  suite tools/sprint-headless-json-go go_headless_json
  suite tools/cockpit-daemon go_daemon
else
  printf '==> %s\n' "tools/sprint-check-go skipped (go absent)"
  printf '==> %s\n' "tools/sprint-headless-json-go skipped (go absent)"
  printf '==> %s\n' "tools/cockpit-daemon skipped (go absent)"
fi

if (( DRY )) || command -v node >/dev/null 2>&1; then
  suite tests/sprint-check-gherkin.js node "$ROOT/tests/sprint-check-gherkin.js"
  suite tests/sprint-check-editor.js node "$ROOT/tests/sprint-check-editor.js"
  suite tests/sprint-check-seed.js node "$ROOT/tests/sprint-check-seed.js"
  suite tests/sprint-check-handoff-state.js node "$ROOT/tests/sprint-check-handoff-state.js"
  suite tests/sprint-check-status-badge.js node "$ROOT/tests/sprint-check-status-badge.js"
  suite tests/sprint-check-worktree-chip.js node "$ROOT/tests/sprint-check-worktree-chip.js"
  suite tests/sprint-check-esc.js node "$ROOT/tests/sprint-check-esc.js"
  suite tests/sprint-check-theme.js node "$ROOT/tests/sprint-check-theme.js"
  suite tests/prefix-keys.js node "$ROOT/tests/prefix-keys.js"
  suite tests/board-spec-guard-unit.js node "$ROOT/tests/board-spec-guard-unit.js"
  suite tests/board-spec-classify-unit.js node "$ROOT/tests/board-spec-classify-unit.js"
  suite tests/sprint-check-api-scoping.js node "$ROOT/tests/sprint-check-api-scoping.js"
else
  printf '==> %s\n' "tests/sprint-check-gherkin.js skipped (node absent)"
fi
return 0
}

if (( LIST )); then DRY=1; run_all; printf '%s\n' "${LABELS[@]}"; exit 0; fi
if (( CHANGED )); then
  source "$ROOT/scripts/test-select.sh"
  if [[ -z "$CHANGED_BASE" ]]; then
    CHANGED_BASE="$(git -C "$ROOT" merge-base HEAD origin/main 2>/dev/null)" || { echo "test.sh --changed: no origin/main to diff against; pass a base" >&2; exit 2; }
  fi
  DRY=1; run_all; DRY=0
  LABELS_FILE="$(mktemp "${TMPDIR:-/tmp}/test-labels.XXXXXX")"; printf '%s\n' "${LABELS[@]}" > "$LABELS_FILE"
  rc=0; select_init "$ROOT" "$CHANGED_BASE" "$LABELS_FILE" || rc=$?
  rm -f "$LABELS_FILE"
  if (( rc )); then exit "$rc"; fi
  n_changed="$(printf '%s' "$SELECT_CHANGED" | grep -c . || true)"
  printf 'PARTIAL RUN (--changed): %s changed path(s) since %s, %s suite(s) known\n' "$n_changed" "${SELECT_BASE:0:8}" "${#LABELS[@]}"
  if (( SELECT_UNTRACKED )); then echo "test.sh --changed: $SELECT_UNTRACKED untracked path(s) not seen; git add -N a new file to include it"; fi
  if [[ -z "$SELECT_CHANGED" ]]; then echo "test.sh --changed: nothing changed outside the evidence-neutral docs; no suite to run (untracked files are not seen: git add -N them)"; select_cleanup; exit 0; fi
  if [[ -n "$SELECT_FULL" ]]; then echo "test.sh --changed: running every suite: $SELECT_FULL"; fi
fi
trap print_timings EXIT
run_all

# Give a server that was just killed a few seconds to actually exit before calling it a leak.
for _ in 1 2 3 4 5; do
  sleep 1
  LEAKED_SERVERS="$(_new_orphan_servers)"
  [[ -z "${LEAKED_SERVERS// /}" ]] && break
done
if [[ -n "${LEAKED_SERVERS// /}" ]]; then
  printf '\nFAIL: the test run left sprint-check servers running (PIDs): %s\n' "$LEAKED_SERVERS" >&2
  exit 1
fi

printf '\nAll tests passed.\n'
