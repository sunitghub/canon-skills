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
cp "$ROOT/tools/ticket-root.sh" "$legacy/tools/"   # the only file subagent-log.sh sources; a plain cp fails loudly if that changes
log_sum() { if [[ -f "$canon_log" ]]; then shasum < "$canon_log" | cut -d' ' -f1; else echo none; fi; }
canon_before="$(log_sum)"
(cd "$project" && echo '{"agent_id":"ghi789","agent_type":"legacy"}' | "$legacy/tools/subagent-log.sh")
assert_count 1 '"agent_id":"ghi789"' "$legacy/.claude/subagent-runs.jsonl"
assert_eq "$canon_before" "$(log_sum)"
[[ ! -e "$ROOT/.claude/subagent-runs.jsonl.tmp" ]] || fail "subagent-log-cli: left $ROOT/.claude/subagent-runs.jsonl.tmp"

# ── t-5ef3: cost flags land on the row; tier comes from the ticket's plan.md ─
mkdir -p "$project/.tickets/t-cost"
printf '## Sign-off\nTier: **Normal** | Risk: low\n' > "$project/.tickets/t-cost/plan.md"
(cd "$project" && "$SUBAGENT_LOG" --agent-id cost1 --agent-type evaluator --tokens 0099000 --minutes 12.5 --tool-uses 40 --ticket t-cost --outcome budget)
assert_count 1 '"agent_id":"cost1","agent_type":"evaluator","transcript_path":"","tokens":99000,"minutes":12.5,"tool_uses":40,"ticket":"t-cost","tier":"normal","outcome":"budget"}' "$log"
# An explicit --tier wins over plan.md's, lowercased like it so gate-cost groups them together.
(cd "$project" && "$SUBAGENT_LOG" --agent-id cost2 --tokens 1 --ticket t-cost --tier Bugfix)
assert_count 1 '"agent_id":"cost2","agent_type":"","transcript_path":"","tokens":1,"ticket":"t-cost","tier":"bugfix"}' "$log"
# Without the flags the row keeps its old shape exactly.
(cd "$project" && "$SUBAGENT_LOG" --agent-id plain1 --agent-type reviewer)
assert_grep '"agent_id":"plain1","agent_type":"reviewer","transcript_path":""}$' "$log"

# ── t-3a14: --model lands last; without it the row is byte-identical to the same flags' row ─
(cd "$project" && "$SUBAGENT_LOG" --agent-id mod1 --agent-type evaluator --tokens 5 --ticket t-cost --outcome pass --model claude-sonnet-5)
assert_count 1 '"agent_id":"mod1","agent_type":"evaluator","transcript_path":"","tokens":5,"ticket":"t-cost","tier":"normal","outcome":"pass","model":"claude-sonnet-5"}' "$log"
(cd "$project" && "$SUBAGENT_LOG" --agent-id mod2 --model openai:gpt-5.1)
assert_grep '"agent_id":"mod2","agent_type":"","transcript_path":"","model":"openai:gpt-5.1"}$' "$log"
(cd "$project" && "$SUBAGENT_LOG" --agent-id same1 --agent-type evaluator --tokens 5 --ticket t-cost --outcome pass)
assert_grep '"agent_id":"same1","agent_type":"evaluator","transcript_path":"","tokens":5,"ticket":"t-cost","tier":"normal","outcome":"pass"}$' "$log"

# ── A bad cost value fails loudly and writes nothing ─────────────────────────
rows_before="$(wc -l < "$log")"
for bad in "--tokens 12k" "--tool-uses -1" "--minutes 1e3" "--minutes 01.5" "--outcome partial" "--tier a\"b" "--ticket .." "--ticket ../x" "--tokens" "--outcome"; do
  set +e
  # shellcheck disable=SC2086  # split on purpose: flag and value
  (cd "$project" && "$SUBAGENT_LOG" --agent-id bad1 $bad 2>"$project/bad-err"); rc=$?
  set -e
  assert_eq 1 "$rc"
done
assert_eq "$rows_before" "$(wc -l < "$log")"

# ── t-3a14: a hostile or empty --model is refused and appends nothing ────────
long_model="$(printf 'm%.0s' $(seq 81))"
for bad in 'a"b' 'a b' $'a\nb' 'a,b' 'a{b' 'a}b' '' "$long_model"; do
  set +e
  (cd "$project" && "$SUBAGENT_LOG" --agent-id bad2 --model "$bad" 2>"$project/bad-err"); rc=$?
  set -e
  assert_eq 1 "$rc"
  assert_count 1 'model takes a model id' "$project/bad-err"
done
set +e
(cd "$project" && "$SUBAGENT_LOG" --agent-id bad2 --model 2>"$project/bad-err"); rc=$?
set -e
assert_eq 1 "$rc"
assert_count 1 'subagent-log.sh: --model needs a value' "$project/bad-err"
(cd "$project" && "$SUBAGENT_LOG" --agent-id max80 --model "${long_model:1}")
assert_eq "$((rows_before + 1))" "$(wc -l < "$log")"
assert_count 0 '"agent_id":"bad2"' "$log"

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
assert_count 1 '[--model <id>]' "$help_file"   # t-3a14: the usage text names the flag

printf 'subagent-log-cli: ok\n'
