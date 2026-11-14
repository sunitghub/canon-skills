#!/usr/bin/env bash
# t-63a7: `sprint token-spend` splits each closed sprint's transcript tokens into planning / implementation / gates.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
cfg="$(mktemp -d)"
wt="$(mktemp -d)"
# Its own CANON_HOME: scripts/test.sh shares one across suites, and their events would fill this one's log.
CANON_HOME="$(mktemp -d)"; export CANON_HOME
trap 'rm -rf "$project" "$cfg" "$wt" "$CANON_HOME"' EXIT
cd "$project"
root="$(pwd -P)"
export CLAUDE_CONFIG_DIR="$cfg"
events="$CANON_HOME/events"
mkdir -p "$events"

# No transcripts: says so, exit 0, no table.
assert_eq "No Claude Code transcripts for $root under $cfg/projects: token-spend reads only Claude Code's (other harnesses keep none it can read)." "$("$SPRINT" token-spend)"

# A sprint in a worktree: its events and its session both carry the worktree's path.
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git worktree add -q "$wt/w1" 2>/dev/null
wtp="$(cd "$wt/w1" && pwd -P)"
wdir="$cfg/projects/$(printf '%s' "$wtp" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$wdir"

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
turn 15:05:00 msg_w1 claude-opus-5-5 44 0 0 0 "$wtp" > "$wdir/s2.jsonl"   # t-gggg, in the worktree
turn 10:45:00 msg_i1 claude-sonnet-5-5 50 0 0 0 > "$tdir/s1/subagents/agent-i1.jsonl"   # implementer: implementation
printf '{"agentType":"general-purpose","description":"implement"}' > "$tdir/s1/subagents/agent-i1.meta.json"
{ turn 10:50:00 msg_g1 claude-sonnet-5-5 40 0 0 0; turn 10:51:00 msg_g2 claude-sonnet-5-5 0 0 0 0; } > "$tdir/s1/subagents/agent-g1.jsonl"   # before gate.started, still a gate; two turns, one run
printf '{"agentType":"canon-evaluator","description":"t-aaaa binding evaluator"}' > "$tdir/s1/subagents/agent-g1.meta.json"
turn 13:15:00 msg_r1 claude-sonnet-5-5 50 0 0 0 > "$tdir/s1/subagents/agent-r1.jsonl"   # a sprint with only its gates here
printf '{"agentType":"canon-reviewer","description":"t-ffff advisory reviewer"}' > "$tdir/s1/subagents/agent-r1.meta.json"

# Transcripts but no events: says so.
out="$("$SPRINT" token-spend)"
assert_contains "$out" "No canon events"

ev() { printf '{"schema":1,"ts":"2026-%sZ","kind":"%s","project":"%s","data":{"ticket":"%s"}}\n' "$1" "$2" "$root" "$3"; }
# t-c8c6: events only for a project spelled another way (another folder here): the no-match message names that spelling beside the path list,
# control bytes shown as ?, so a mis-spelled event project is visible instead of a bare "No completed sprints"
for pj in 'D:/elsewhere/p\033x' 'D:/elsewhere/p\033x' '' /o/two /o/three /o/four; do   # a repeat, an empty project, then more than three
  printf '{"schema":1,"ts":"2026-09-29T08:00:00.000Z","kind":"sprint.started","project":"%b","data":{"ticket":"t-mmmm"}}\n' "$pj"
done > "$events/2026-09-29.jsonl"
out="$("$SPRINT" token-spend)"
assert_contains "$out" "No completed sprints in $events for $root. Event projects that did not match: D:/elsewhere/p?x, /o/two, /o/three; path list: $root"   # each once, at most three
rm "$events/2026-09-29.jsonl"
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
  ev 10-01T12:50:00.000 gate.started t-bbbb    # a re-grade: the gates phase still starts at the first
  ev 10-01T13:00:00.000 sprint.completed t-bbbb
  ev 10-01T13:10:00.000 sprint.started t-ffff
  ev 10-01T13:20:00.000 sprint.completed t-ffff
  ev 10-01T13:30:00.000 sprint.started t-eeee   # never completed: no row
  ev 10-01T13:40:00.000 sprint.started ../t-evil
  ev 10-01T13:50:00.000 sprint.completed ../t-evil
} > "$events/2026-10-01.jsonl"
printf '{"schema":1,"ts":"2026-10-01T15:00:00.000Z","kind":"sprint.started","project":"%s","data":{"ticket":"t-gggg"}}\n{"schema":1,"ts":"2026-10-01T15:10:00.000Z","kind":"sprint.completed","project":"%s","data":{"ticket":"t-gggg"}}\n' "$wtp" "$wtp" >> "$events/2026-10-01.jsonl"
mkdir -p .tickets/t-aaaa .tickets/t-bbbb
printf '## Sign-off\nTier: normal | Risk: x\n\n- [x] Plan approved\nApproved: sha256:%s 2026-10-01T10:30:00Z\n' "$(printf 'a%.0s' {1..64})" > .tickets/t-aaaa/plan.md
printf '## Sign-off\nTier: high | Risk: x\n\n- [x] Plan approved\n' > .tickets/t-bbbb/plan.md
mkdir -p t-evil && printf 'Tier: high\n' > t-evil/plan.md   # an id from the events never names a path outside .tickets/

before="$(find "$cfg" "$events" .tickets t-evil -type f -exec cksum {} + | sort)"
out="$("$SPRINT" token-spend)"
after="$(find "$cfg" "$events" .tickets t-evil -type f -exec cksum {} + | sort)"
assert_eq "$before" "$after"   # read-only

row() { printf '%s\n' "$out" | awk -v t="$1" '$1 == t' | tr -s ' '; }
# ticket tier planning implementation gates cache-read
assert_eq "t-aaaa normal 20 150 343 1k" "$(row t-aaaa)"
assert_eq "t-bbbb high-risk - 600* 900 0" "$(row t-bbbb)"
assert_eq "t-cccc - - 11* 0 0 ~ partial" "$(row t-cccc)"
assert_eq "t-dddd - no transcript turns (older than the transcripts kept)" "$(row t-dddd)"
assert_eq "" "$(row t-eeee)"
assert_eq "t-gggg - - 44* 0 0 ~ partial" "$(row t-gggg)"
assert_eq "../t-evil - no transcript turns (older than the transcripts kept)" "$(row ../t-evil)"
assert_eq "t-ffff - - 0* 50 0" "$(row t-ffff)"   # no Approved: stamp and no build turns: still "-", not 0
phase() { printf '%s\n' "$out" | awk -v p="$1" -v m="$2" '$1 == p && $2 == m' | tr -s ' '; }
# phase model turns fresh-in cache-read output
assert_eq "overlap claude-opus-5-5 1 7 0 0" "$(phase overlap claude-opus-5-5)"
assert_eq "gates claude-opus-5-5 2 303 0 0" "$(phase gates claude-opus-5-5)"
assert_eq "gates claude-sonnet-5-5 4 990 0 0" "$(phase gates claude-sonnet-5-5)"
assert_eq "implementation claude-sonnet-5-5 1 50 0 0" "$(phase implementation claude-sonnet-5-5)"
assert_eq "planning claude-opus-5-5 1 10 1k 10" "$(phase planning claude-opus-5-5)"
assert_eq "" "$(phase planning '<synthetic>')"

# --ticket narrows both tables to that sprint; overlap belongs to no one sprint.
out="$("$SPRINT" token-spend --ticket t-bbbb)"
assert_eq "t-bbbb high-risk - 600* 900 0" "$(row t-bbbb)"
assert_eq "" "$(row t-aaaa)"
assert_eq "" "$(phase overlap claude-opus-5-5)"

# --last 4: the four newest closed sprints.
out="$("$SPRINT" token-spend --last 4)"
assert_eq "t-bbbb high-risk - 600* 900 0" "$(row t-bbbb)"
assert_eq "" "$(row t-aaaa)"

# An Approved: stamp before sprint start (planned during another sprint): no planning here, marked ^.
sed -i.bak 's/10:30:00Z/09:00:00Z/' .tickets/t-aaaa/plan.md && rm .tickets/t-aaaa/plan.md.bak
out="$("$SPRINT" token-spend --ticket t-aaaa)"
assert_eq "t-aaaa normal 0^ 170 343 1k" "$(row t-aaaa)"

out="$("$SPRINT" token-spend --ticket t-zzzz)"
assert_contains "$out" "No completed sprint for t-zzzz."

# t-134b: one folder, several spellings. On Windows the events' project reached the log as C:/Users/x/p (a native exe got Git Bash's converted argument)
# while the path list said /c/Users/x/p, so every turn was dropped. canon_awk_pkey is the one definition; the table is the spellings it must join (and not).
source "$ROOT/tools/platform-lib.sh"
pk() { printf '%s\n' "$1" | awk "$canon_awk_pkey"'{ print pkey($0) }'; }
for sp in 'C:\\Users\\x\\p' 'C:\Users\x\p' 'C:/Users/x/p' 'c:/Users/x/p' 'C:/Users/x/p/' '/c/Users/x/p' '/c/Users/x/p/'; do
  assert_eq "/c/Users/x/p" "$(pk "$sp")"
done
assert_eq "/Users/x/p" "$(pk '/Users/x/p/')"; assert_eq "/" "$(pk '/')"; assert_eq "" "$(pk '')"; assert_eq "/c" "$(pk 'C:/')"
assert_eq "/Users/X/p" "$(pk '/Users/X/p')"            # only the drive letter is lower-cased: /Users/X and /Users/x are two folders on a case-sensitive system
assert_eq "//host/share" "$(pk '\\\\host\\share')"       # a JSON-escaped UNC path stays distinguishable from /host/share
[[ "$(pk 'C:/Users/x/p')" != "$(pk 'D:/Users/x/p')" ]] || fail "another drive is another folder"

# End to end: the events' project and the turns' cwd are spelled differently from the project path: JSON-escaped backslashes after the first folder
# (/private\\\\var\\\\...), the way a Windows cwd arrives in a transcript (C:\\\\Users\\\\...); a Mac cannot spell its path as /c/Users, but pkey must join a
# backslash spelling to the POSIX project path in both awk stages, which a trailing slash alone does not exercise (the old code already tolerated that).
p2="$(make_project)"; r2="$(cd "$p2" && pwd -P)"; trap 'rm -rf "$project" "$cfg" "$wt" "$CANON_HOME" "$p2" "${p3:-}"' EXIT
mkdir -p "$cfg/projects/$(printf '%s' "$r2" | sed 's/[^A-Za-z0-9]/-/g')"
b2="$(printf '%s' "$r2" | sed -e 's|/|\\\\|g' -e 's|^\\\\|/|')"   # /private\\var\\folders\\...: two backslashes per separator, as JSON writes one
{ printf '{"schema":1,"ts":"2026-10-02T14:00:00.000Z","kind":"sprint.started","project":"%s","data":{"ticket":"t-wwww"}}\n' "$b2"
  printf '{"schema":1,"ts":"2026-10-02T14:30:00.000Z","kind":"sprint.completed","project":"%s","data":{"ticket":"t-wwww"}}\n' "$b2"; } > "$events/2026-10-02.jsonl"
turn2() { printf '{"parentUuid":null,"isSidechain":false,"type":"assistant","message":{"model":"claude-sonnet-5-5","id":"%s","type":"message","role":"assistant","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":20}},"timestamp":"2026-10-02T%s.000Z","cwd":"%s"}\n' "$1" "$2" "$3"; }
turn2 msg_w1 14:10:00 "$b2" > "$cfg/projects/$(printf '%s' "$r2" | sed 's/[^A-Za-z0-9]/-/g')/w.jsonl"
out="$(cd "$p2" && "$SPRINT" token-spend --ticket t-wwww)"
assert_contains "$out" "t-wwww"; [[ "$out" != *"No transcript turns"* ]] || fail "a sprint whose project and cwd are spelled differently found no turns: $out"
# turns that match no sprint: the message now says how many were read and which folders were compared (three at most, each once, control bytes
# replaced and a long one cut at 120), and which folders the sprints ran in (a worktree is a second one)
p3="$(make_project)"; r3="$(cd "$p3" && pwd -P)"; mkdir -p "$cfg/projects/$(printf '%s' "$r3" | sed 's/[^A-Za-z0-9]/-/g')"
( cd "$p3" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init && for n in 3 4 5; do git worktree add -q "$wt/w$n" 2>/dev/null; done )
w3="$(cd "$wt/w3" && pwd -P)"; w4="$(cd "$wt/w4" && pwd -P)"; w5="$(cd "$wt/w5" && pwd -P)"
{ printf '{"schema":1,"ts":"2026-10-03T14:00:00.000Z","kind":"sprint.started","project":"%s","data":{"ticket":"t-vvvv"}}\n' "$r3"
  printf '{"schema":1,"ts":"2026-10-03T14:30:00.000Z","kind":"sprint.completed","project":"%s","data":{"ticket":"t-vvvv"}}\n' "$r3"
  printf '{"schema":1,"ts":"2026-10-03T14:00:00.000Z","kind":"sprint.started","project":"%s","data":{"ticket":"t-uuuu"}}\n' "$w3"
  printf '{"schema":1,"ts":"2026-10-03T14:30:00.000Z","kind":"sprint.completed","project":"%s","data":{"ticket":"t-uuuu"}}\n' "$w3"
  for pair in "t-tttt $r3" "t-ssss $w4" "t-rrrr $w5"; do   # a second sprint in a folder already listed, then two more worktrees: the list holds each once, three at most
    set -- $pair
    printf '{"schema":1,"ts":"2026-10-03T15:00:00.000Z","kind":"sprint.started","project":"%s","data":{"ticket":"%s"}}\n' "$2" "$1"
    printf '{"schema":1,"ts":"2026-10-03T15:30:00.000Z","kind":"sprint.completed","project":"%s","data":{"ticket":"%s"}}\n' "$2" "$1"
  done; } > "$events/2026-10-03.jsonl"
long="$(head -c 200 /dev/zero | tr '\0' a)"
{ turn2 msg_v1 18:00:00 "$r3"$'\033[2J'; turn2 msg_v2 18:01:00 "$r3"$'\033[2J'; turn2 msg_v3 18:02:00 "$r3/x"; turn2 msg_v4 18:03:00 "$r3/$long"; turn2 msg_v5 18:04:00 "$r3/z"; } \
  | sed 's/2026-10-02/2026-10-03/' > "$cfg/projects/$(printf '%s' "$r3" | sed 's/[^A-Za-z0-9]/-/g')/v.jsonl"
out="$(cd "$p3" && "$SPRINT" token-spend --ticket t-vvvv)"
assert_contains "$out" "No transcript turns inside these sprints"
assert_contains "$out" "read 5 turns in $r3?[2J, $r3/x, $(printf '%s' "$r3/$long" | cut -c1-120)...; the sprints ran in $r3, $w3, $w4"
[[ "$(printf '%s\n' "$out" | sed -n 2p)" == *"ran in $r3, $w3, $w4" && "$out" != *"$w5"* ]] || fail "the sprint folders are each listed once, three at most: $out"
[[ "$out" != *$'\033'* ]] || fail "a control byte from a transcript cwd reached the terminal: $out"
[[ "$out" != *"$r3/z"* ]] || fail "more than three folders were listed: $out"

# t-7e26: --record writes one sprint.cost event (numbers only), prints the cost line, and writes nothing twice.
bd="$(mktemp -d)"; trap 'rm -rf "$project" "$cfg" "$wt" "$CANON_HOME" "$p2" "${p3:-}" "$bd"' EXIT
use_fresh_board "$bd/bin"   # canon_event writes through the board binary under test
recspend() { CANON_EVENTS_CLOCK=2026-10-05T00:00:00Z "$SPRINT" token-spend "$@" --record; }   # the fixtures are dated October: a real clock would prune them as older than the retention
cost_lines() { cat "$events"/*.jsonl 2>/dev/null | grep -c '"kind":"sprint.cost"' || true; }
assert_eq 0 "$(cost_lines)"
# t-b6ad: the gate run log subagent-log.sh writes. t-aaaa's builder is opus (100 implementation tokens against a sonnet implementer's 50).
# The evaluator's LAST row is opus (its first was sonnet); the reviewer's last row is sonnet (its first was opus); a row for t-aaaab is another ticket.
mkdir -p "$root/.claude"
{ printf '{"ts":"2026-10-02T10:30:00Z","agent_id":"r0","agent_type":"reviewer","ticket":"t-aaaa","model":"claude-opus-5-5"}\n'
  printf '{"ts":"2026-10-02T10:31:00Z","agent_id":"e0","agent_type":"evaluator","ticket":"t-aaaa","model":"claude-sonnet-5-5"}\n'
  printf '{"ts":"2026-10-02T10:50:00Z","agent_id":"r1","agent_type":"reviewer","ticket":"t-aaaa","model":"claude-sonnet-5-5"}\n'
  printf '{"ts":"2026-10-02T10:51:00Z","agent_id":"e1","agent_type":"evaluator","ticket":"t-aaaa","model":"claude-opus-5-5"}\n'
  printf '{"ts":"2026-10-02T10:52:00Z","agent_id":"x1","agent_type":"reviewer","ticket":"t-aaaab","model":"claude-opus-5-5"}\n'
  printf '{"ts":"2026-10-02T10:53:00Z","agent_id":"reviewer-t-aaaa","agent_type":"reviewer","ticket":"t-zzzz","model":"claude-opus-5-5"}\n'; } > "$root/.claude/subagent-runs.jsonl"   # an agent id that ENDS in t-aaaa is not a row for t-aaaa
out="$(recspend --ticket t-aaaa)"
assert_eq "1" "$(cost_lines)"
ln="$(grep -h '"kind":"sprint.cost"' "$events"/*.jsonl)"
assert_contains "$ln" '"ticket":"t-aaaa"'
assert_contains "$ln" '"gates":"343"'; assert_contains "$ln" '"implementation":"170"'; assert_contains "$ln" '"turns":"'
assert_contains "$ln" '"gate_runs":"1"'; assert_contains "$ln" 'claude-sonnet-5-5:'
[[ "$ln" != *"content"* && "$ln" != *'"text"'* ]] || fail "a sprint.cost line carries transcript text: $ln"
assert_contains "$out" "cost: 513 tokens (gates 343, 66%), 1 gate runs"
# t-b6ad: the builder is the implementation phase's biggest model; only the evaluator ran on it (the reviewer's LAST row is another model, t-aaaab is another ticket)
assert_contains "$ln" '"builder":"claude-opus-5-5"'; assert_contains "$ln" '"same_model":"evaluator"'
assert_contains "$out" "note: the evaluator ran on claude-opus-5-5, the model that built this change, so it is not independent of it (advisory, never a block)."
[[ "$out" != *"reviewer ran"* && "$out" != *"reviewer and"* ]] || fail "the reviewer's last row is sonnet: it must not be named: $out"
assert_contains "$out" "Most of this ticket's tokens went to the close gates"
out="$(recspend --ticket t-aaaa)"; assert_eq "" "$out"; assert_eq "1" "$(cost_lines)"   # idempotent
# the cost survives the transcripts (about 9 days): the row comes from the event
mv "$cfg/projects" "$cfg/projects.gone"; mkdir -p "$cfg/projects/$(printf '%s' "$root" | sed 's/[^A-Za-z0-9]/-/g')"
out="$("$SPRINT" token-spend --ticket t-aaaa < <(printf '(standard input):'; turn 10:55:00 msg_stdin claude-opus-5-5 99 0 0 0))"   # a grep that waited on stdin would read this turn
assert_eq "t-aaaa normal 0 170 343 1k (from the sprint.cost event)" "$(printf '%s\n' "$out" | awk '$1 == "t-aaaa"' | tr -s ' ')"
rm -rf "$cfg/projects"; mv "$cfg/projects.gone" "$cfg/projects"
# no turns inside the sprint: nothing recorded, nothing printed
assert_eq "" "$(recspend --ticket t-dddd)"; assert_eq "1" "$(cost_lines)"
assert_eq "" "$(recspend --ticket t-zzzz)"; assert_eq "1" "$(cost_lines)"
# the same cost under a Windows-style spelling of the project (the t-wwww fixture above): recorded, not lost to a path mismatch
out="$(cd "$p2" && CANON_EVENTS_CLOCK=2026-10-05T00:00:00Z "$SPRINT" token-spend --ticket t-wwww --record)"
assert_contains "$out" "cost: 120 tokens (gates 0, 0%), 0 gate runs"
ln2="$(grep -h '"ticket":"t-wwww"' "$events"/*.jsonl | grep '"kind":"sprint.cost"')"
assert_contains "$ln2" '"builder":"claude-sonnet-5-5"'   # no Approved: stamp: the build phase; and no .claude/subagent-runs.jsonl in this project
[[ "$ln2" != *same_model* && "$out" != *"note:"* ]] || fail "no gate run log: no same_model and no note: $ln2 / $out"
set +e; "$SPRINT" token-spend --record >/dev/null 2>&1; rc=$?; set -e; assert_eq 1 "$rc"   # needs a ticket
# t-b6ad: a log row that does not name the builder's exact id gives no note: an alias (sonnet), a model with a control byte
{ printf '{"ts":"2026-10-02T12:50:00Z","agent_id":"e2","agent_type":"evaluator","ticket":"t-bbbb","model":"sonnet"}\n'
  printf '{"ts":"2026-10-02T12:51:00Z","agent_id":"r2","agent_type":"reviewer","ticket":"t-bbbb","model":"claude-sonnet-5-5\033[2J"}\n'; } >> "$root/.claude/subagent-runs.jsonl"
out="$(recspend --ticket t-bbbb)"
assert_contains "$out" "cost: "
ln3="$(grep -h '"ticket":"t-bbbb"' "$events"/*.jsonl | grep '"kind":"sprint.cost"')"
assert_contains "$ln3" '"builder":"claude-sonnet-5-5"'
[[ "$ln3" != *same_model* && "$out" != *"note:"* && "$out" != *$'\033'* ]] || fail "an alias or a control-byte row must name no gate and write nothing odd: $ln3 / $out"
# a transcript model that is not a plain id: when it is the TOP implementation model there is no builder at all (not the runner-up, which would be a
# guess), and no gate is named even though the log has a row for this ticket on the runner-up's id (three evil turns against one sonnet turn)
p4="$(make_project)"; r4="$(cd "$p4" && pwd -P)"; trap 'rm -rf "$project" "$cfg" "$wt" "$CANON_HOME" "$p2" "${p3:-}" "$bd" "$p4"' EXIT
mkdir -p "$cfg/projects/$(printf '%s' "$r4" | sed 's/[^A-Za-z0-9]/-/g')" "$r4/.claude"
sprint_events() { printf '{"schema":1,"ts":"2026-10-06T%s.000Z","kind":"sprint.started","project":"%s","data":{"ticket":"%s"}}\n{"schema":1,"ts":"2026-10-06T%s.000Z","kind":"sprint.completed","project":"%s","data":{"ticket":"%s"}}\n' "$2" "$r4" "$1" "$3" "$r4" "$1"; }
{ sprint_events t-hhhh 14:00:00 14:30:00; sprint_events t-kkkk 15:00:00 15:30:00; sprint_events t-jjjj 16:00:00 16:30:00; } > "$events/2026-10-06.jsonl"
{ turn2 msg_h1 14:10:00 "$r4"; for n in 2 3 4; do turn2 "msg_h$n" "14:1$n:00" "$r4" | sed 's/claude-sonnet-5-5/claude-evil'$'\033''[2J/'; done
  turn2 msg_k1 15:10:00 "$r4"; turn2 msg_j1 16:10:00 "$r4"; } | sed 's/2026-10-02/2026-10-06/' > "$cfg/projects/$(printf '%s' "$r4" | sed 's/[^A-Za-z0-9]/-/g')/h.jsonl"
rl() { printf '{"ts":"2026-10-06T00:00:00Z","agent_id":"%s","agent_type":"%s","ticket":"%s","model":"claude-sonnet-5-5"}\n' "$1" "$2" "$3"; }
{ rl h1 reviewer t-hhhh; rl k1 reviewer t-kkkk; rl k2 evaluator t-kkkk; rl j1 reviewer t-jjjj; } > "$r4/.claude/subagent-runs.jsonl"
cost_of() { grep -h "\"ticket\":\"$1\"" "$events"/*.jsonl | grep '"kind":"sprint.cost"'; }
out="$(cd "$p4" && recspend --ticket t-hhhh)"
[[ "$(cost_of t-hhhh)" != *'"builder"'* && "$(cost_of t-hhhh)" != *same_model* && "$out" != *"note:"* && "$out" != *$'\033'* ]] || fail "a hostile top model gave a builder, a gate, a note or a control byte: $(cost_of t-hhhh) / $out"
# both gates logged on the builder's model: one line names both; only the reviewer: the singular reviewer line, not the evaluator
out="$(cd "$p4" && recspend --ticket t-kkkk)"
assert_contains "$(cost_of t-kkkk)" '"same_model":"reviewer,evaluator"'
assert_contains "$out" "note: the reviewer and the evaluator ran on claude-sonnet-5-5, the model that built this change, so neither is independent of it (advisory, never a block)."
out="$(cd "$p4" && recspend --ticket t-jjjj)"
assert_contains "$(cost_of t-jjjj)" '"same_model":"reviewer"'
assert_contains "$out" "note: the reviewer ran on claude-sonnet-5-5, the model that built this change, so it is not independent of it (advisory, never a block)."
[[ "$out" != *evaluator* ]] || fail "only the reviewer's row matches: $out"
# a ticket whose only turns are gates: its models have no implementation tokens, so there is no builder (a tie or zero must not pick one)
out="$(recspend --ticket t-ffff)"
[[ "$(cost_of t-ffff)" != *'"builder"'* ]] || fail "a gates-only ticket has no builder: $(cost_of t-ffff)"

for bad in "--last 0" "--last x" "--last x1" "--last 1x" "--last" "--ticket" "--bogus"; do
  set +e
  # shellcheck disable=SC2086  # split on purpose
  "$SPRINT" token-spend $bad >/dev/null 2>&1; rc=$?
  set -e
  assert_eq 1 "$rc"
done
out="$("$SPRINT" token-spend --help)"   # exits 0
assert_eq "Usage: sprint token-spend [--last N] [--ticket <id> [--record]]" "$out"

printf 'sprint-token-spend: ok\n'
