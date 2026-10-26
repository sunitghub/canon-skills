#!/usr/bin/env bash
# t-b874: protects `sprint-check gate-clusters`: clusters from a run log, event day files and eval reports (text and --json),
# the "no data" line, an unreadable-line count, and that the command writes nothing (the scratch tree hashes the same after).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export CANON_HOME="$work/home"; mkdir -p "$CANON_HOME/events"
export SPRINT_CHECK_NO_BROWSER=1
board="$(build_board "$work/board")"
proj="$work/proj"; mkdir -p "$proj/.claude" "$proj/.tickets/t-aaaa"
tree_hash() { (cd "$work" && find proj home -type f | LC_ALL=C sort | xargs cat | { sha256sum 2>/dev/null || shasum -a 256; }); }

cd "$proj"
out="$("$board" gate-clusters)"
assert_contains "$out" "run log .claude/subagent-runs.jsonl: missing"
assert_contains "$out" "no gate failures in the last 30 days"

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; day="$(date -u +%Y-%m-%d)"
run() { printf '{"ts":"%s","agent_id":"%s","agent_type":"evaluator","ticket":"%s","outcome":"fail"}\n' "$now" "$1" "$2"; }
{ run r1 t-aaaa; run r2 t-bbbb; echo 'not json'; } > .claude/subagent-runs.jsonl
printf '| 1 | Safe reading | fail |\n' > .tickets/t-aaaa/eval-report.md
for i in 1 2 3; do
  printf '{"schema":1,"id":"e%s","ts":"%s","kind":"gate.rejected","source":"sprint","project":"p","data":{"ticket":"t-cccc","role":"evaluator","reason":"integrity"}}\n' "$i" "$now"
done > "$CANON_HOME/events/$day.jsonl"

before="$(tree_hash)"
out="$("$board" gate-clusters)"
assert_contains "$out" "3 x rejected evaluator integrity"
assert_contains "$out" "error: 1 unreadable lines"
assert_contains "$out" "seen once (not a pattern):"
assert_contains "$out" "1 x evaluator fail: Safe reading"
json="$("$board" gate-clusters --days 7 --json)"
assert_contains "$json" '"days":7'
assert_contains "$json" '"cause":"rejected evaluator integrity","count":3'
assert_contains "$json" '"unreadable_lines":1'
[[ "$(tree_hash)" == "$before" ]] || fail "gate-clusters changed files in the project or CANON_HOME"
"$board" gate-clusters --days 0 2>/dev/null && fail "--days 0 must be refused" || true

echo "gate-clusters: ok"
