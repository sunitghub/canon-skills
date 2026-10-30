#!/usr/bin/env bash
# t-63a7: `sprint token-spend` splits each closed sprint's transcript tokens into planning / implementation / gates.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
cfg="$(mktemp -d)"
trap 'rm -rf "$project" "$cfg"' EXIT
cd "$project"
root="$(pwd -P)"
export CLAUDE_CONFIG_DIR="$cfg"
events="$CANON_HOME/events"
mkdir -p "$events"

# No transcripts: says so, exit 0, no table.
out="$("$SPRINT" token-spend)"
assert_contains "$out" "No Claude Code transcripts"

tdir="$cfg/projects/$(printf '%s' "$root" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$tdir/s1/subagents"
# turn <ts> <msg id> <model> <input> <cache write> <cache read> <output> [cwd]
turn() {
  printf '{"parentUuid":null,"isSidechain":false,"type":"assistant","message":{"model":"%s","id":"%s","type":"message","role":"assistant","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s,"iterations":[{"input_tokens":99999}]}},"timestamp":"2026-10-01T%s.000Z","cwd":"%s"}\n' \
    "$3" "$2" "$4" "$5" "$6" "$7" "$1" "${8:-$root}"
}
main="$tdir/s1.jsonl"
{
  turn 09:55:00 msg_c1 claude-opus-5-5 11 0 0 0              # t-cccc (no plan.md): build
  turn 10:10:00 msg_a1 claude-opus-5-5 1 9 1000 10          # t-aaaa planning: 20
  turn 10:10:00 msg_a1 claude-opus-5-5 1 9 1000 10          # the same message written twice: once
  turn 10:15:00 msg_x1 claude-opus-5-5 500 0 0 0 /elsewhere # another project's cwd: never counted
  turn 10:40:00 msg_a2 claude-opus-5-5 60 0 0 40            # t-aaaa implementation: 100
  turn 10:55:00 msg_a3 claude-opus-5-5 3 0 0 0              # after the evaluator's first turn: gates
  turn 11:10:00 msg_a4 claude-opus-5-5 300 0 0 0            # after gate.started: gates
  turn 11:45:00 msg_o1 claude-opus-5-5 7 0 0 0              # inside t-aaaa and t-bbbb: overlap only
  turn 12:10:00 msg_b1 claude-sonnet-5-5 600 0 0 0          # t-bbbb, no Approved: stamp: build
  turn 12:40:00 msg_b2 claude-sonnet-5-5 900 0 0 0          # t-bbbb gates
  turn 14:00:00 msg_z1 claude-opus-5-5 800 0 0 0            # outside every sprint
  turn 10:12:00 a789507e-b355 '<synthetic>' 0 0 0 0         # harness-made, no msg_ id: not a turn
  # A user line quoting usage-shaped text is not a turn.
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"{\"type\":\"assistant\",\"id\":\"msg_fake\",\"usage\":{\"input_tokens\":777}}"},"timestamp":"2026-10-01T10:20:00.000Z","cwd":"'"$root"'"}'
} > "$main"
turn 10:45:00 msg_i1 claude-sonnet-5-5 50 0 0 0 > "$tdir/s1/subagents/agent-i1.jsonl"   # implementer: implementation
printf '{"agentType":"general-purpose","description":"implement"}' > "$tdir/s1/subagents/agent-i1.meta.json"
turn 10:50:00 msg_g1 claude-sonnet-5-5 40 0 0 0 > "$tdir/s1/subagents/agent-g1.jsonl"   # before gate.started, still a gate
printf '{"agentType":"canon-evaluator","description":"t-aaaa binding evaluator"}' > "$tdir/s1/subagents/agent-g1.meta.json"
turn 13:15:00 msg_r1 claude-sonnet-5-5 50 0 0 0 > "$tdir/s1/subagents/agent-r1.jsonl"   # a sprint with only its gates here
printf '{"agentType":"canon-reviewer","description":"t-ffff advisory reviewer"}' > "$tdir/s1/subagents/agent-r1.meta.json"

# Transcripts but no events: says so.
out="$("$SPRINT" token-spend)"
assert_contains "$out" "No canon events"

ev() { printf '{"schema":1,"ts":"2026-%sZ","kind":"%s","project":"%s","data":{"ticket":"%s"}}\n' "$1" "$2" "$root" "$3"; }
ev 09-30T08:00:00.000 sprint.started t-dddd | gzip > "$events/2026-09-30.jsonl.gz"
ev 09-30T08:10:00.000 sprint.completed t-dddd | gzip | cat >> "$events/2026-09-30.jsonl.gz"
{
  ev 10-01T09:50:00.000 sprint.started t-cccc
  ev 10-01T10:00:00.000 sprint.completed t-cccc
  ev 10-01T10:00:00.000 sprint.started t-aaaa
  ev 10-01T11:00:00.000 gate.started t-aaaa
  ev 10-01T11:30:00.000 sprint.started t-bbbb
  ev 10-01T12:00:00.000 sprint.completed t-aaaa
  ev 10-01T12:30:00.000 gate.started t-bbbb
  ev 10-01T13:00:00.000 sprint.completed t-bbbb
  ev 10-01T13:10:00.000 sprint.started t-ffff
  ev 10-01T13:20:00.000 sprint.completed t-ffff
  ev 10-01T13:30:00.000 sprint.started t-eeee   # never completed: no row
} > "$events/2026-10-01.jsonl"
mkdir -p .tickets/t-aaaa .tickets/t-bbbb
printf '## Sign-off\nTier: normal | Risk: x\n\n- [x] Plan approved\nApproved: sha256:%s 2026-10-01T10:30:00Z\n' "$(printf 'a%.0s' {1..64})" > .tickets/t-aaaa/plan.md
printf '## Sign-off\nTier: high | Risk: x\n\n- [x] Plan approved\n' > .tickets/t-bbbb/plan.md

before="$(find "$cfg" "$events" .tickets -type f -exec cksum {} + | sort)"
out="$("$SPRINT" token-spend)"
after="$(find "$cfg" "$events" .tickets -type f -exec cksum {} + | sort)"
assert_eq "$before" "$after"   # read-only

row() { printf '%s\n' "$out" | awk -v t="$1" '$1 == t' | tr -s ' '; }
# ticket tier planning implementation gates cache-read
assert_eq "t-aaaa normal 20 150 343 1k" "$(row t-aaaa)"
assert_eq "t-bbbb high-risk - 600* 900 0" "$(row t-bbbb)"
assert_eq "t-cccc - - 11* 0 0 ~ partial" "$(row t-cccc)"
assert_eq "t-dddd - no transcript turns (older than the transcripts kept)" "$(row t-dddd)"
assert_eq "" "$(row t-eeee)"
assert_eq "t-ffff - - 0* 50 0" "$(row t-ffff)"   # no Approved: stamp and no build turns: still "-", not 0
phase() { printf '%s\n' "$out" | awk -v p="$1" -v m="$2" '$1 == p && $2 == m' | tr -s ' '; }
# phase model turns fresh-in cache-read output
assert_eq "overlap claude-opus-5-5 1 7 0 0" "$(phase overlap claude-opus-5-5)"
assert_eq "gates claude-opus-5-5 2 303 0 0" "$(phase gates claude-opus-5-5)"
assert_eq "gates claude-sonnet-5-5 3 990 0 0" "$(phase gates claude-sonnet-5-5)"
assert_eq "implementation claude-sonnet-5-5 1 50 0 0" "$(phase implementation claude-sonnet-5-5)"
assert_eq "planning claude-opus-5-5 1 10 1k 10" "$(phase planning claude-opus-5-5)"
assert_eq "" "$(phase planning '<synthetic>')"

# --ticket narrows both tables to that sprint; overlap belongs to no one sprint.
out="$("$SPRINT" token-spend --ticket t-bbbb)"
assert_eq "t-bbbb high-risk - 600* 900 0" "$(row t-bbbb)"
assert_eq "" "$(row t-aaaa)"
assert_eq "" "$(phase overlap claude-opus-5-5)"

# --last 2: the two newest closed sprints.
out="$("$SPRINT" token-spend --last 2)"
assert_eq "t-bbbb high-risk - 600* 900 0" "$(row t-bbbb)"
assert_eq "" "$(row t-aaaa)"

# An Approved: stamp before sprint start (planned during another sprint): no planning here, marked ^.
sed -i.bak 's/10:30:00Z/09:00:00Z/' .tickets/t-aaaa/plan.md && rm .tickets/t-aaaa/plan.md.bak
out="$("$SPRINT" token-spend --ticket t-aaaa)"
assert_eq "t-aaaa normal 0^ 170 343 1k" "$(row t-aaaa)"

out="$("$SPRINT" token-spend --ticket t-zzzz)"
assert_contains "$out" "No completed sprint for t-zzzz."

for bad in "--last 0" "--last x" "--last" "--ticket" "--bogus"; do
  set +e
  # shellcheck disable=SC2086  # split on purpose
  "$SPRINT" token-spend $bad >/dev/null 2>&1; rc=$?
  set -e
  assert_eq 1 "$rc"
done
assert_eq "Usage: sprint token-spend [--last N] [--ticket <id>]" "$("$SPRINT" token-spend --help)"

printf 'sprint-token-spend: ok\n'
