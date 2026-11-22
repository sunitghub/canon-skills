#!/usr/bin/env bash
# t-0829: `sprint token-spend` computed by the board binary (internal/board/tokenspend.go), held to the bash/awk version it replaced.
# Prod paths protected: `sprint token-spend [--last N] [--ticket <id>]` (the table, its refusals), `sprint complete`'s call
# `sprint token-spend --ticket <id> --record` (the sprint.cost event, the gate.cost events, the `cost:` line) and the stale-binary line.
#   1. Golden: the bash version from the base commit and the Go one print the same table on the same fixtures (every number, every
#      refusal; the labels that t-e200 renamed are normalised, then asserted on their own). The base is `git merge-base HEAD main`; once
#      this change is merged that commit holds the delegation, so the live comparison is skipped and the committed numbers below stand
#      (they are what the bash version printed on these fixtures).
#   2. The new numbers per phase and per gate run (calls, input, cache_read, cache_write, output, peak), for Claude Code's transcripts
#      and one Copilot session record, and the events --record writes.
# Everything is pinned under one scratch dir: never the real ~/.claude, ~/.copilot or ~/.canon.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

S="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$S"' EXIT
export HOME="$S/home" CANON_HOME="$S/canon" CLAUDE_CONFIG_DIR="$S/claude" COPILOT_HOME="$S/copilot" TMPDIR="$S/tmp"
mkdir -p "$HOME" "$CANON_HOME/events" "$CLAUDE_CONFIG_DIR" "$COPILOT_HOME" "$TMPDIR"
use_fresh_board "$S/bin"

project="$(make_project)"
cd "$project"
root="$(pwd -P)"
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git worktree add -q "$S/w1" 2>/dev/null
wtp="$(cd "$S/w1" && pwd -P)"
events="$CANON_HOME/events"
enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
tdir="$CLAUDE_CONFIG_DIR/projects/$(enc "$root")"
wdir="$CLAUDE_CONFIG_DIR/projects/$(enc "$wtp")"
mkdir -p "$tdir/s1/subagents" "$wdir"

# The bash version from the base commit, in a scratch copy of tools/ so its `source` lines resolve.
legacy=""
base="$(git -C "$ROOT" merge-base HEAD main 2>/dev/null || true)"
base_sprint="$(git -C "$ROOT" show "$base:tools/sprint" 2>/dev/null || true)"
if [[ -n "$base" && "$base_sprint" == *"function winpath"* ]]; then
  mkdir -p "$S/base"
  git -C "$ROOT" archive "$base" -- tools/sprint tools/tkt ':(glob)tools/*.sh' | tar -x -C "$S/base"
  legacy="$S/base/tools/sprint"
fi
[[ -z "$legacy" ]] && echo "token-spend-golden: base commit no longer holds the awk version; comparing against the committed numbers only"

# turn <ts> <msg id> <model> <input> <cache write> <cache read> <output> [cwd]   (EXTRA is text inside the message)
turn() {
  printf '{"parentUuid":null,"isSidechain":false,"type":"assistant","message":{"model":"%s","id":"%s","type":"message","role":"assistant","content":[{"type":"text","text":"x%s"}],"usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s,"iterations":[{"input_tokens":99999}]}},"timestamp":"2026-10-01T%s.000Z","cwd":"%s"}\n' \
    "$3" "$2" "${EXTRA:-}" "$4" "$5" "$6" "$7" "$1" "${8:-$root}"
}
sub() { # sub <agent id> <agentType> <description or ->: writes the meta file ('-': no meta file at all)
  [[ "$3" == - ]] || printf '{"agentType":"%s","description":"%s"}' "$2" "$3" > "$tdir/s1/subagents/agent-$1.meta.json"
}
O=claude-opus-5-5; N=claude-sonnet-5-5

# ---- t-aaaa: planning (with a spec check) -> approval 10:30 -> build -> gates from 11:00 -> done 12:00 ------------------------------------
{
  EXTRA=SECRET9f3 turn 10:10:00 msg_m1 $O 5 700 3000 40          # plan (its text must reach no event)
  turn 10:10:00 msg_m1 $O 5 700 3000 40          # the same message written twice: once
  turn 10:20:00 msg_m2 $O 2 100 3700 20          # plan, peak context 3802
  turn 10:40:00 msg_m3 $O 60 300 4000 40         # build
  turn 10:50:00 msg_m4 $O 7 0 4400 10            # build, peak context 4407
  turn 10:30:00 msg_m7 $O 11 0 0 1               # build: the approval second itself (planning ends before it)
  turn 11:00:00 msg_m8 $O 13 0 0 1               # close: the first gate.started second
  turn 11:10:00 msg_m5 $O 3 0 5000 300           # close
  turn 11:25:00 msg_m6 $O 4 50 6000 30           # close
  turn 11:45:00 msg_o1 $O 7 0 0 0                # inside t-aaaa and t-bbbb: overlap only
  turn 14:00:00 msg_z1 $O 800 0 0 0              # outside every sprint
  turn 10:15:00 msg_x1 $O 500 0 0 0 /elsewhere   # another project's cwd: never counted
} > "$tdir/s1.jsonl"
{ turn 10:12:00 msg_s1a $N 1 200 0 10; turn 10:14:00 msg_s1b $N 1 20 200 30; } > "$tdir/s1/subagents/agent-s1.jsonl"; sub s1 canon-spec-checker "t-aaaa spec check"
turn 10:45:00 msg_i1 $N 50 0 0 5 > "$tdir/s1/subagents/agent-i1.jsonl"; sub i1 general-purpose "implement"
turn 10:48:00 msg_u1 $N 9 1 2 3 > "$tdir/s1/subagents/agent-u1.jsonl"; sub u1 - -   # no meta: unknown
{ turn 11:05:00 msg_e1a $N 10 400 0 20; turn 11:08:00 msg_e1b $N 4 100 400 50; turn 11:12:00 msg_e1c $N 2 10 500 90; } > "$tdir/s1/subagents/agent-e1.jsonl"; sub e1 canon-evaluator "t-aaaa binding evaluator"
{ turn 11:20:00 msg_r1a $N 6 300 0 40; turn 11:22:00 msg_r1b $N 2 20 300 60; } > "$tdir/s1/subagents/agent-r1.jsonl"; sub r1 canon-reviewer "t-aaaa advisory reviewer"
EXTRA=' .claude/skills/sprint/reference/eval.md' turn 11:26:00 msg_p1a $N 5 5 5 5 > "$tdir/s1/subagents/agent-p1.jsonl"; sub p1 Plan "t-aaaa second opinion"   # a Plan agent that read eval.md ran the evaluator
# ---- t-bbbb: no Approved: stamp (build), a reviewer dispatched before its gate.started ---------------------------------------------------
{ turn 12:10:00 msg_b1 $N 600 0 0 0; turn 12:40:00 msg_b2 $N 900 0 0 0; } > "$tdir/s2.jsonl"
turn 12:20:00 msg_br $N 50 0 0 0 > "$tdir/s1/subagents/agent-br.jsonl"; sub br canon-reviewer "t-bbbb advisory reviewer"
# ---- t-gggg: a sprint in the worktree; t-dddd: older than the transcripts ------------------------------------------------------------------
{ turn 15:05:00 msg_w1 $O 44 0 0 0 "$wtp"; turn 15:10:00 msg_w2 $O 99 0 0 0 "$wtp"; } > "$wdir/s3.jsonl"   # the second turn is at the sprint's end second: outside

ev() { printf '{"schema":1,"ts":"2026-%sZ","kind":"%s","project":"%s","data":{"ticket":"%s"}}\n' "$1" "$2" "$root" "$3"; }

# ---- refusals, before the events exist ----------------------------------------------------------------------------------------------------
# norm_go: what the Go output holds beyond the bash one: the context and per-step (t-0abe) sections, planning's spec share; and t-e200's rename of "gates" to "close"
norm_go() {
  awk '/^(Context cost per phase|Cost per step)/ { skip = 1 } skip { if ($0 == "") skip = 0; next } { print }' | sed -e 's/ (spec [0-9.]*[kM]*)//' -e '/^ticket /s/ close / gates /' -e 's/^close /gates /' | tr -s ' '
}
same() { # same <args...>: both versions print the same text for this command
  local g b
  g="$("$SPRINT" token-spend "$@" 2>&1 | norm_go)"
  [[ -n "$legacy" ]] || return 0
  b="$("$legacy" token-spend "$@" 2>&1 | tr -s ' ')"
  [[ "$g" == "$b" ]] || { printf 'bash:\n%s\ngo:\n%s\n' "$b" "$g" >&2; fail "token-spend $* differs between the bash and the Go version"; }
}
mv "$CLAUDE_CONFIG_DIR/projects" "$S/projects.away"
same
assert_eq "No Claude Code transcripts for $root under $CLAUDE_CONFIG_DIR/projects: token-spend reads only Claude Code's (other harnesses keep none it can read)." "$("$SPRINT" token-spend)"
mv "$S/projects.away" "$CLAUDE_CONFIG_DIR/projects"
same
assert_contains "$("$SPRINT" token-spend)" "No canon events under $events"
# events that name another project only: the no-match message names its spelling
printf '{"schema":1,"ts":"2026-09-29T08:00:00.000Z","kind":"sprint.started","project":"/elsewhere/p","data":{"ticket":"t-mmmm"}}\n' > "$events/2026-09-29.jsonl"
same
assert_contains "$("$SPRINT" token-spend)" "Event projects that did not match: /elsewhere/p; path list: $root, $wtp"
rm "$events/2026-09-29.jsonl"

# ---- the fixture events (a gz day, a plain day) ---------------------------------------------------------------------------------------------
ev 09-30T08:00:00.000 sprint.started t-dddd | gzip > "$events/2026-09-30.jsonl.gz"
ev 09-30T08:10:00.000 sprint.completed t-dddd | gzip | cat >> "$events/2026-09-30.jsonl.gz"
{
  ev 10-01T10:00:00.000 sprint.started t-aaaa
  printf '{"schema":1,"ts":"2026-10-01T10:05:00.000Z","kind":"gate.started","project":"%s","data":{"role":"speccheck","ticket":"t-aaaa"}}\n' "$root"
  ev 10-01T11:00:00.000 gate.started t-aaaa
  ev 10-01T11:30:00.000 sprint.started t-bbbb
  ev 10-01T12:00:00.000 sprint.completed t-aaaa
  ev 10-01T12:30:00.000 gate.started t-bbbb
  ev 10-01T13:00:00.000 sprint.completed t-bbbb
  printf '{"schema":1,"ts":"2026-10-01T15:00:00.000Z","kind":"sprint.started","project":"%s","data":{"ticket":"t-gggg"}}\n{"schema":1,"ts":"2026-10-01T15:10:00.000Z","kind":"sprint.completed","project":"%s","data":{"ticket":"t-gggg"}}\n' "$wtp" "$wtp"
} > "$events/2026-10-01.jsonl"
mkdir -p .tickets/t-aaaa .tickets/t-bbbb
printf '## Sign-off\nTier: normal | Risk: x\n\n- [x] Plan approved\nApproved: sha256:%s 2026-10-01T10:30:00Z\n' "$(printf 'a%.0s' {1..64})" > .tickets/t-aaaa/plan.md
printf '## Sign-off\nTier: high | Risk: x\n\n- [x] Plan approved\n' > .tickets/t-bbbb/plan.md
mkdir -p "$S/events-copy"; cp -R "$CANON_HOME/." "$S/events-copy/"   # before any --record

# ---- 1. golden: the same table, the same numbers ----------------------------------------------------------------------------------------------
out="$("$SPRINT" token-spend)"
for a in "" "--ticket t-aaaa" "--ticket t-bbbb" "--ticket t-gggg" "--last 2" "--last 1" "--ticket t-zzzz"; do
  # shellcheck disable=SC2086  # split on purpose
  same $a
done
# the committed numbers (what the bash version printed on these fixtures)
row() { printf '%s\n' "$out" | norm_go | awk -v t="$1" '$1 == t'; }
phase() { printf '%s\n' "$out" | norm_go | awk -v p="$1" -v m="$2" '$1 == p && $2 == m'; }
assert_eq "t-aaaa normal 1k 497 2k 28k ~ partial" "$(row t-aaaa)"
assert_eq "t-bbbb high-risk - 600* 950 0" "$(row t-bbbb)"
assert_eq "t-gggg - - 44* 0 0 ~ partial" "$(row t-gggg)"
assert_eq "t-dddd - no transcript turns (older than the transcripts kept)" "$(row t-dddd)"
assert_eq "gates claude-sonnet-5-5 8 2k 1k 265" "$(phase gates claude-sonnet-5-5)"
assert_eq "gates claude-opus-5-5 3 70 11k 331" "$(phase gates claude-opus-5-5)"
assert_eq "planning claude-sonnet-5-5 2 222 200 40" "$(phase planning claude-sonnet-5-5)"
assert_eq "overlap claude-opus-5-5 1 7 0 0" "$(phase overlap claude-opus-5-5)"
# the labels (t-e200), asserted on the raw Go output
assert_contains "$out" "ticket   tier         planning  implementation      close  cache-read"
assert_contains "$out" "t-aaaa   normal     1k (spec 262)"   # planning names its spec-check share
[[ "$(printf '%s\n' "$out" | awk '$1 == "close" && $2 == "claude-opus-5-5"')" == "close "* ]] || fail "the by-phase table still says gates: $out"
[[ "$out" != *"gates "*"cache-read"* ]] || fail "the table header still says gates: $out"

# ---- 2. the new numbers: per phase (main session) and per subagent run, exact -----------------------------------------------------------------
ctx() { printf '%s\n' "$out" | awk -v w="$1" -v t="$2" '/^Context cost/ { on = 1 } on && $0 == "" { on = 0 } on && index($0, w) == 1 && index($0, " " t " ") { print }' | tr -s ' '; }
assert_eq "plan (main) t-aaaa 2 7 7k 800 60 4k" "$(ctx 'plan (main)' t-aaaa)"
assert_eq "plan (main) t-bbbb n/a n/a n/a n/a n/a n/a" "$(ctx 'plan (main)' t-bbbb)"   # no Approved: stamp: never a 0
assert_eq "evaluator e1 t-aaaa 3 16 900 510 160 512" "$(ctx 'evaluator e1' t-aaaa)"
assert_eq "evaluator p1 t-aaaa 1 5 5 5 5 15" "$(ctx 'evaluator p1' t-aaaa)"   # a Plan agent that read reference/eval.md
assert_eq "speccheck s1 t-aaaa 2 2 200 220 40 221" "$(ctx 'speccheck s1' t-aaaa)"
assert_eq "other i1 t-aaaa 1 50 0 0 5 50" "$(ctx 'other i1' t-aaaa)"
assert_eq "unknown u1 t-aaaa 1 9 2 1 3 12" "$(ctx 'unknown u1' t-aaaa)"   # no meta: never folded into the main session
assert_eq "reviewer br t-bbbb 1 50 0 0 0 50" "$(ctx 'reviewer br' t-bbbb)"

# ---- --record: the events -----------------------------------------------------------------------------------------------------------------------
mkdir -p "$root/.claude"
{ printf '{"ts":"2026-10-02T10:51:00Z","agent_id":"e1","agent_type":"evaluator","ticket":"t-aaaa","model":"claude-opus-5-5"}\n'
  printf '{"ts":"2026-10-02T10:50:00Z","agent_id":"r1","agent_type":"reviewer","ticket":"t-aaaa","model":"claude-sonnet-5-5"}\n'; } > "$root/.claude/subagent-runs.jsonl"
hb="$S/home-bash"; hg="$S/home-go"; cp -R "$S/events-copy" "$hb"; cp -R "$S/events-copy" "$hg"
rec() { (cd "$project" && CANON_HOME="$2" CANON_EVENTS_CLOCK=2026-10-05T00:00:00Z "$1" token-spend --ticket "$3" --record); }
fieldof() { printf '%s\n' "$1" | sed -n 's/.*"'"$2"'":"\([^"]*\)".*/\1/p'; }
cost_ev() { cat "$1"/events/*.jsonl | grep '"kind":"sprint.cost"' | grep "\"ticket\":\"$2\"" || true; }
gate_ev() { cat "$1"/events/*.jsonl | grep '"kind":"gate.cost"' | grep "\"agent_id\":\"$2\"" || true; }
gout="$(rec "$SPRINT" "$hg" t-aaaa)"
assert_eq "cost: 3k tokens (close 2k, 48% — gate agents 1k), cache reads 28k, 2 gate runs
note: the evaluator ran on claude-opus-5-5, the model that built this change, so it is not independent of it (advisory, never a block)." "$gout"
ge="$(cost_ev "$hg" t-aaaa)"
assert_eq 1 "$(printf '%s\n' "$ge" | grep -c .)"
for kv in planning=1129 implementation=497 gates=1530 cache_read=27507 turns=18 gate_runs=2 builder=claude-opus-5-5 same_model=evaluator \
  plan_calls=2 plan_input=7 plan_cache_read=6700 plan_cache_write=800 plan_output=60 plan_peak=3802 \
  build_calls=3 build_input=78 build_cache_read=8400 build_cache_write=300 build_output=51 build_peak=4407 \
  close_calls=3 close_input=20 close_cache_read=11000 close_cache_write=50 close_output=331 close_peak=6054; do
  assert_eq "${kv#*=}" "$(fieldof "$ge" "${kv%%=*}")"
done
if [[ -n "$legacy" ]]; then   # the old fields are what the bash version recorded
  bout="$(rec "$legacy" "$hb" t-aaaa)"
  be="$(cost_ev "$hb" t-aaaa)"
  for k in planning implementation gates cache_read turns gate_runs models builder same_model; do
    assert_eq "$(fieldof "$be" "$k")" "$(fieldof "$ge" "$k")"
  done
  assert_eq "cost: 3k tokens (gates 2k, 48%), 2 gate runs" "${bout%%$'\n'*}"
fi
# one gate.cost per subagent run, keyed by its agent id; never transcript text
assert_eq "evaluator|canon-evaluator|claude-sonnet-5-5|3|16|900|510|160|512" "$(g="$(gate_ev "$hg" e1)"; for k in role agent_type model calls input cache_read cache_write output peak; do printf '%s|' "$(fieldof "$g" $k)"; done | sed 's/|$//')"
assert_eq "evaluator|Plan|claude-sonnet-5-5|1|5|5|5|5|15" "$(g="$(gate_ev "$hg" p1)"; for k in role agent_type model calls input cache_read cache_write output peak; do printf '%s|' "$(fieldof "$g" $k)"; done | sed 's/|$//')"
assert_eq "speccheck|canon-spec-checker|2|221" "$(g="$(gate_ev "$hg" s1)"; for k in role agent_type calls peak; do printf '%s|' "$(fieldof "$g" $k)"; done | sed 's/|$//')"
assert_eq "reviewer" "$(fieldof "$(gate_ev "$hg" r1)" role)"; assert_eq "other" "$(fieldof "$(gate_ev "$hg" i1)" role)"
assert_eq "unknown" "$(fieldof "$(gate_ev "$hg" u1)" role)"
assert_eq 6 "$(cat "$hg"/events/*.jsonl | grep -c '"kind":"gate.cost"')"
assert_eq "" "$(gate_ev "$hg" br)"   # t-bbbb's reviewer: another sprint's run, not written for t-aaaa
all="$(cat "$hg"/events/*.jsonl)"
[[ "$all" != *SECRET9f3* && "$all" != *"reference/eval.md"* && "$all" != *'"text"'* ]] || fail "an event carries transcript text"
# a second close writes nothing and prints nothing; a close that lost only its sprint.cost writes it again and no gate.cost twice
assert_eq "" "$(rec "$SPRINT" "$hg" t-aaaa)"
assert_eq 6 "$(cat "$hg"/events/*.jsonl | grep -c '"kind":"gate.cost"')"
f="$hg/events/2026-10-05.jsonl"; grep -v '"kind":"sprint.cost"' "$f" > "$f.new" || true; mv "$f.new" "$f"
rec "$SPRINT" "$hg" t-aaaa >/dev/null
assert_eq 1 "$(cost_ev "$hg" t-aaaa | grep -c .)"
assert_eq 6 "$(cat "$hg"/events/*.jsonl | grep -c '"kind":"gate.cost"')"
# no build stamp (t-bbbb): the plan phase has no fields at all, never 0
rec "$SPRINT" "$hg" t-bbbb >/dev/null
gb="$(cost_ev "$hg" t-bbbb)"
[[ "$gb" != *'"plan_'* ]] || fail "t-bbbb has no planning, so no plan_ fields: $gb"
assert_eq "600" "$(fieldof "$gb" build_peak)"; assert_eq 1 "$(fieldof "$gb" build_calls)"; assert_eq 1 "$(fieldof "$gb" close_calls)"
if [[ -n "$legacy" ]]; then
  rec "$legacy" "$hb" t-bbbb >/dev/null
  for k in planning implementation gates cache_read turns gate_runs models builder; do assert_eq "$(fieldof "$(cost_ev "$hb" t-bbbb)" "$k")" "$(fieldof "$gb" "$k")"; done
fi

# ---- a transcript that cannot be read, a malformed line, an over-long line: skipped, never fatal ---------------------------------------------------
mkdir "$tdir/dir.jsonl"                          # a folder named like a transcript
printf '%s\n' 'not json at all {"type":"assistant"' '{"type":"assistant","message":{"id":"msg_bad","usage":"x"}}' > "$tdir/garbage.jsonl"
# an unreadable transcript (not for root, which reads anything) holding an in-window call: skipped, not counted, not fatal
turn 10:41:00 msg_locked $O 5555 0 0 0 > "$tdir/locked.jsonl"; chmod 000 "$tdir/locked.jsonl"
rc=0; out2="$("$SPRINT" token-spend 2>&1)" || rc=$?; assert_eq 0 "$rc"
if [[ "$(id -u)" != 0 ]]; then assert_eq "$(printf '%s\n' "$out" | norm_go)" "$(printf '%s\n' "$out2" | norm_go)"; fi
chmod 644 "$tdir/locked.jsonl"; rm -f "$tdir/locked.jsonl"
assert_eq "$(printf '%s\n' "$out" | norm_go)" "$("$SPRINT" token-spend | norm_go)"

# ---- Copilot's session record: calls by agentId, found by the session's working folder, inside the sprint window --------------------------------
cu() { printf '{"type":"session.usage_record","data":{"usage":{"model":"claude-sonnet-5.5","responseModel":"claude-sonnet-5-5","inputTokens":%s,"outputTokens":%s,"cacheReadTokens":%s,"cacheWriteTokens":%s,"apiCallId":"%s"}},%s"id":"x","timestamp":"2026-10-%sZ"}\n' "$3" "$4" "$5" "$6" "$7" "${2:+\"agentId\":\"$2\",}" "$1"; }
ag=b28a5306-d26b-4287-89ab-c67b3370b6b9
mksession() { # mksession <id> <cwd> <date prefix>: the numbers are t-4084's live run (an evaluator dispatched by the main session)
  mkdir -p "$COPILOT_HOME/session-state/$1"
  {
    printf '{"type":"session.start","data":{"sessionId":"%s","context":{"cwd":"%s","gitRoot":"%s"}},"id":"s","timestamp":"2026-10-%sT20:06:12.476Z"}\n' "$1" "$2" "$2" "$3"
    printf '{"type":"subagent.started","data":{"agentType":"canon-evaluator"},"agentId":"%s","id":"y","timestamp":"2026-10-%sT20:06:16.477Z"}\n' "$ag" "$3"
    cu "$3T20:06:16.463" "" 31087 328 0 31083 "$1-call1"
    cu "$3T20:06:17.813" $ag 6900 127 0 6896 "$1-call2"
    cu "$3T20:06:19.411" $ag 7155 215 6896 257 "$1-call3"
    echo 'a line that is not json'
    cu "$3T20:06:21.232" $ag 7718 264 7153 563 "$1-call4"
    cu "$3T20:06:23.767" $ag 16594 324 7716 8876 "$1-call5"
    cu "$3T20:06:26.243" $ag 17203 246 16592 609 "$1-call6"
    cu "$3T20:06:31.419" $ag 17673 659 17201 470 "$1-call7"
    cu "$3T20:06:35.421" "" 32077 659 31083 992 "$1-call8"
  } > "$COPILOT_HOME/session-state/$1/events.jsonl"
}
mksession cp-this "$root" 08
mksession cp-elsewhere /elsewhere/other 08     # another project's session: never counted
mksession cp-later "$root" 09                  # this project, a day with no sprint: outside every window
mkdir -p "$COPILOT_HOME/session-state/cp-nostart" && printf '%s\n' "$(cu 08T20:06:20.000 '' 99999 9 0 0 callX)" > "$COPILOT_HOME/session-state/cp-nostart/events.jsonl"   # no session.start: no working folder
{ ev 10-08T20:00:00.000 sprint.started t-cplt; ev 10-08T20:06:17.000 gate.started t-cplt; ev 10-08T20:30:00.000 sprint.completed t-cplt; } > "$events/2026-10-08.jsonl"
cout="$("$SPRINT" token-spend --ticket t-cplt)"
assert_contains "$cout" "from Claude Code transcripts and Copilot's session record:"
assert_eq "t-cplt - - 31k* 21k 87k" "$(printf '%s\n' "$cout" | awk '$1 == "t-cplt"' | tr -s ' ')"
cctx() { printf '%s\n' "$cout" | awk -v w="$1" '/^Context cost/ { on = 1 } on && $0 == "" { on = 0 } on && index($0, w) == 1' | tr -s ' '; }
assert_eq "build (main) t-cplt 1 4 0 31k 328 31k" "$(cctx 'build (main)')"
assert_eq "close (main) t-cplt 1 2 31k 992 659 32k" "$(cctx 'close (main)')"
assert_eq "evaluator b28a5306 t-cplt 6 14 56k 18k 2k 18k" "$(cctx 'evaluator')"
[[ "$(printf '%s\n' "$cout" | awk '$1 == "t-aaaa"')" == "" ]] || fail "--ticket t-cplt shows another sprint"
assert_eq "$(printf '%s\n' "$out" | norm_go | awk '$1 == "t-aaaa"')" "$("$SPRINT" token-spend --ticket t-aaaa | norm_go | awk '$1 == "t-aaaa"')"   # the Copilot calls leak into no other sprint
cp "$events/2026-10-08.jsonl" "$hg/events/"
rec "$SPRINT" "$hg" t-cplt >/dev/null
cp_ev="$(cost_ev "$hg" t-cplt)"
for kv in build_calls=1 build_input=4 build_cache_read=0 build_cache_write=31083 build_output=328 build_peak=31087 \
  close_calls=1 close_input=2 close_cache_read=31083 close_cache_write=992 close_output=659 close_peak=32077; do
  assert_eq "${kv#*=}" "$(fieldof "$cp_ev" "${kv%%=*}")"
done
cg="$(gate_ev "$hg" "$ag")"
for kv in role=evaluator agent_type=canon-evaluator model=claude-sonnet-5-5 calls=6 input=14 cache_read=55558 cache_write=17671 output=1835 peak=17673; do
  assert_eq "${kv#*=}" "$(fieldof "$cg" "${kv%%=*}")"
done
# the session's own shutdown totals (input 20, cache read 86641, cache write 49746, output 2822) are the sum of the main session and the agent
assert_eq "20 86641 49746 2822" "$(( $(fieldof "$cp_ev" build_input) + $(fieldof "$cp_ev" close_input) + $(fieldof "$cg" input) )) $(( $(fieldof "$cp_ev" build_cache_read) + $(fieldof "$cp_ev" close_cache_read) + $(fieldof "$cg" cache_read) )) $(( $(fieldof "$cp_ev" build_cache_write) + $(fieldof "$cp_ev" close_cache_write) + $(fieldof "$cg" cache_write) )) $(( $(fieldof "$cp_ev" build_output) + $(fieldof "$cp_ev" close_output) + $(fieldof "$cg" output) ))"

# ---- an older board binary: one line naming canon update, exit 0, nothing written -------------------------------------------------------------
old="$S/oldboard"; printf '#!/bin/sh\necho "canon-go - usage: event <kind> copilot-report"\n' > "$old"; chmod +x "$old"
before="$(cat "$hg"/events/*.jsonl | wc -l)"
oout="$(cd "$project" && SPRINT_CHECK_BIN="$old" CANON_HOME="$hg" "$SPRINT" token-spend --ticket t-aaaa --record)"; assert_eq 0 "$?"
assert_contains "$oout" "run 'canon update'"; assert_eq 1 "$(printf '%s\n' "$oout" | grep -c .)"
assert_eq "$before" "$(cat "$hg"/events/*.jsonl | wc -l)"
assert_eq "Usage: sprint token-spend [--last N] [--ticket <id> [--record]]" "$(cd "$project" && SPRINT_CHECK_BIN="$old" "$SPRINT" token-spend --help)"

echo "token-spend-golden: ok"
