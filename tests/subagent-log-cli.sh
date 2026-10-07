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
# Legacy mode resolves the root from the script's own location (its install path), not the caller's cwd.
# Run a COPY inside a throwaway git repo so the entry lands there: this test must never read or write
# canon's own log (t-c8be: the old cleanup `grep -v … && mv` skipped its mv when the log held only that
# entry, so a fresh clone counted 2 on the next run and left a .tmp behind).
legacy="$(make_project)"
trap 'rm -rf "$project" "$legacy"' EXIT
mkdir -p "$legacy/tools"; cp "$SUBAGENT_LOG" "$legacy/tools/"
for dep in project-root-lib.sh ticket-root.sh; do [[ -f "$ROOT/tools/$dep" ]] && cp "$ROOT/tools/$dep" "$legacy/tools/"; done
log_sum() { if [[ -f "$canon_log" ]]; then shasum < "$canon_log" | cut -d' ' -f1; else echo none; fi; }
canon_before="$(log_sum)"
(cd "$project" && echo '{"agent_id":"ghi789","agent_type":"legacy"}' | "$legacy/tools/subagent-log.sh")
assert_count 1 '"agent_id":"ghi789"' "$legacy/.claude/subagent-runs.jsonl"
assert_eq "$canon_before" "$(log_sum)"
[[ ! -e "$ROOT/.claude/subagent-runs.jsonl.tmp" ]] || fail "subagent-log-cli: left $ROOT/.claude/subagent-runs.jsonl.tmp"

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
