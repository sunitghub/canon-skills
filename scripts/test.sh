#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# t-269d: the Go board server opens the developer's real browser at startup unless this is set; every test
# that starts it would otherwise open real tabs (tests/no-browser-in-tests.sh keeps each script honest too).
export SPRINT_CHECK_NO_BROWSER=1
# t-2d74: skills.sh prompts through /dev/tty, so a run from a real terminal stopped for a 15s prompt per
# temp project. The pty-simulated prompt tests unset this for their own child.
export SKILLS_SH_NO_TTY=1

tests=(
  "$ROOT/tests/tkt.sh"
  "$ROOT/tests/sprint.sh"
  "$ROOT/tests/ticket-root-worktree.sh"
  "$ROOT/tests/frontmatter-lib.sh"
  "$ROOT/tests/skills-add-sprint.sh"
  "$ROOT/tests/skills-sprint-deps.sh"
  "$ROOT/tests/sprint-check-nongit.sh"
  "$ROOT/tests/skills-model-tiers-note.sh"
  "$ROOT/tests/skills-subagent-log-permission.sh"
  "$ROOT/tests/skills-assume-yes.sh"
  "$ROOT/tests/skills-refresh.sh"
  "$ROOT/tests/skills-uninstall.sh"
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
  "$ROOT/tests/subagent-log-cli.sh"
  "$ROOT/tests/disposable-cred.sh"
  "$ROOT/tests/skills-std.sh"
  "$ROOT/tests/install-target.sh"
  "$ROOT/tests/install-sh.sh"
  "$ROOT/tests/example-paths.sh"
  "$ROOT/tests/plugin-eval-gen.sh"
  "$ROOT/tests/skill-check.sh"
  "$ROOT/tests/sprint-check-skill-eval.sh"
  "$ROOT/tests/sprint-check-skill-eval-go.sh"
  "$ROOT/tests/skill-eval-parity.sh"
  "$ROOT/tests/build-zip-go-package.sh"
  "$ROOT/tests/sprint-check-server.sh"
  "$ROOT/tests/sprint-check-cockpit.sh"
  "$ROOT/tests/sprint-check-interrupted.sh"
  "$ROOT/tests/canon-cli.sh"
  "$ROOT/tests/canon-update.sh"
  "$ROOT/tests/sprint-check-upkeep.sh"
  "$ROOT/tests/upkeep-skill-hash-parity.sh"
  "$ROOT/tests/sprint-check-worktrees.sh"
  "$ROOT/tests/sprint-check-ticket-commit.sh"
  "$ROOT/tests/sprint-check-track-changes.sh"
  "$ROOT/tests/board-origin-guard.sh"
  "$ROOT/tests/sprint-check-worktree-holds.sh"
  "$ROOT/tests/sprint-check-live-docs.sh"
  "$ROOT/tests/helpers-sweep.sh"
  "$ROOT/tests/sprint-check-app.sh"
  "$ROOT/tests/sprint-check-api-parity.sh"
  "$ROOT/tests/board-branch-divergence.sh"
  "$ROOT/tests/registry.sh"
  "$ROOT/tests/canon.sh"
  "$ROOT/tests/no-browser-in-tests.sh"
  "$ROOT/tests/sprint-check-delegate.sh"
  "$ROOT/tests/doc-mirror-parity.sh"
  "$ROOT/tests/site.sh"
  "$ROOT/tests/gate-model-parity.sh"
  "$ROOT/tests/jtbd-routing.sh"
  "$ROOT/tests/why-cap.sh"
  "$ROOT/tests/dsl-runner-comments.sh"
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

for test_file in "${tests[@]}"; do
  printf '==> %s\n' "${test_file#$ROOT/}"
  bash "$test_file"
done

if command -v go >/dev/null 2>&1; then
  printf '==> %s\n' "tools/sprint-check-go"
  (cd "$ROOT" && GO111MODULE=off go test ./tools/sprint-check-go)
  printf '==> %s\n' "tools/sprint-headless-json-go"
  (cd "$ROOT" && GO111MODULE=off go test ./tools/sprint-headless-json-go)
  printf '==> %s\n' "tools/cockpit-daemon"
  (cd "$ROOT/tools/cockpit-daemon" && go test ./...)
else
  printf '==> %s\n' "tools/sprint-check-go skipped (go absent)"
  printf '==> %s\n' "tools/sprint-headless-json-go skipped (go absent)"
  printf '==> %s\n' "tools/cockpit-daemon skipped (go absent)"
fi

if command -v node >/dev/null 2>&1; then
  printf '==> %s\n' "tests/sprint-check-gherkin.js"
  node "$ROOT/tests/sprint-check-gherkin.js"
  printf '==> %s\n' "tests/sprint-check-editor.js"
  node "$ROOT/tests/sprint-check-editor.js"
  printf '==> %s\n' "tests/sprint-check-seed.js"
  node "$ROOT/tests/sprint-check-seed.js"
  printf '==> %s\n' "tests/sprint-check-handoff-state.js"
  node "$ROOT/tests/sprint-check-handoff-state.js"
  printf '==> %s\n' "tests/sprint-check-status-badge.js"
  node "$ROOT/tests/sprint-check-status-badge.js"
  printf '==> %s\n' "tests/sprint-check-api-scoping.js"
  node "$ROOT/tests/sprint-check-api-scoping.js"
else
  printf '==> %s\n' "tests/sprint-check-gherkin.js skipped (node absent)"
fi

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
