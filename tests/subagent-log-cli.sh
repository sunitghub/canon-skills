#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
SUBAGENT_LOG="$ROOT/tools/subagent-log.sh"

project="$(make_project)"
trap 'rm -rf "$project"' EXIT

# ── CLI-arg mode writes to the calling project's own root, not canon's ──────
(cd "$project" && "$SUBAGENT_LOG" --agent-id abc123 --agent-type evaluator)
log="$project/.claude/subagent-runs.jsonl"
assert_file_exists "$log"
assert_count 1 '"agent_id":"abc123"' "$log"
assert_count 1 '"agent_type":"evaluator"' "$log"

# Confirm it did NOT write into canon's own log.
canon_log="$ROOT/.claude/subagent-runs.jsonl"
if [[ -f "$canon_log" ]]; then
  assert_count 0 '"agent_id":"abc123"' "$canon_log"
fi

# ── Second call appends, does not overwrite ─────────────────────────────────
(cd "$project" && "$SUBAGENT_LOG" --agent-id def456 --agent-type reviewer)
assert_count 1 '"agent_id":"abc123"' "$log"
assert_count 1 '"agent_id":"def456"' "$log"

# ── Legacy stdin-JSON hook mode still works (back-compat for un-migrated installs) ─
(cd "$project" && echo '{"agent_id":"ghi789","agent_type":"legacy"}' | "$SUBAGENT_LOG")
# Legacy mode resolves root from the script's own location (canon's install path),
# not the caller's cwd — documented pre-existing behavior, not fixed by this ticket.
assert_count 1 '"agent_id":"ghi789"' "$canon_log"
# Clean up the entry this test just wrote into canon's real log.
grep -v '"agent_id":"ghi789"' "$canon_log" > "$canon_log.tmp" && mv "$canon_log.tmp" "$canon_log"

err_file="$project/subagent-log-err"
help_file="$project/subagent-log-help"

# ── Unrecognized arg fails loudly with usage, does not silently exit 0 ──────
set +e
(cd "$project" && "$SUBAGENT_LOG" - 2>"$err_file"); rc=$?
set -e
assert_eq 1 "$rc"
assert_count 1 'unrecognized argument' "$err_file"

# ── Missing --agent-id fails loudly with usage, does not silently exit 0 ───
set +e
(cd "$project" && "$SUBAGENT_LOG" --agent-type reviewer 2>"$err_file"); rc=$?
set -e
assert_eq 1 "$rc"
assert_count 1 'agent-id is required' "$err_file"

# ── -h/--help prints usage and exits 0 ──────────────────────────────────────
set +e
(cd "$project" && "$SUBAGENT_LOG" -h >"$help_file" 2>&1); rc=$?
set -e
assert_eq 0 "$rc"
assert_count 1 'Usage:' "$help_file"

printf 'subagent-log-cli: ok\n'
