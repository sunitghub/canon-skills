#!/usr/bin/env bash
# events (t-f182) — the event stream from every writer: tkt and sprint through `sprint-check event`, and the board's own
# routes, into $CANON_HOME/events/<UTC day>.jsonl. Protects tkt create/start/close, sprint start, the board's create and
# status routes (the events they leave, and that they behave the same when events cannot be written), and the shape every
# reader (t-0b89, t-4c09) depends on.
set -euo pipefail
export SPRINT_CHECK_NO_BROWSER=1   # the board starts here
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
command -v python3 >/dev/null 2>&1 || fail "events: python3 is required (this test's JSON reader)"

W="$(mktemp -d)"; W="$(cd "$W" && pwd -P)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
use_fresh_board "$W/bin"
# HOME too, not only CANON_HOME: a writer that ignored CANON_HOME (a mutant did, in the t-f182 sweep) would fall back to
# ~/.canon and write the user's own log. Set after the board is built (the Go build cache lives under HOME on macOS).
mkdir -p "$W/userhome"
export CANON_HOME="$W/home" HOME="$W/userhome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset CANON_TICKETS_DIR   # a stamp from a clone exports it (the real project's .tickets); these projects use their own
EV="$CANON_HOME/events"
TKT="$ROOT/tools/tkt"; SPRINT="$ROOT/tools/sprint"
mkproj() { mkdir -p "$1/.tickets"; git -C "$1" init -q; git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; }
# events [kind]: every event line, as "kind source ticket from>to" (from>to only for a status change)
events() {
  python3 - "$EV" "${1:-}" <<'PY'
import glob, json, os, sys
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.jsonl"))):
    for line in open(f):
        e = json.loads(line)
        if sys.argv[2] and e["kind"] != sys.argv[2]: continue
        d = e["data"]
        parts = [e["kind"], e["source"], d.get("ticket", "")]
        if e["kind"] == "ticket.status_changed": parts.append("%s>%s" % (d.get("from", ""), d.get("to", "")))
        print(" ".join(parts))
PY
}
shape() {   # shape <kind> <source>: the top-level keys and data keys of the last such event
  python3 - "$EV" "$1" "$2" <<'PY'
import glob, json, os, sys
last = None
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.jsonl"))):
    for line in open(f):
        e = json.loads(line)
        if e["kind"] == sys.argv[2] and e["source"] == sys.argv[3]: last = e
print(" ".join(sorted(last)), "|", " ".join(sorted(last["data"])), "|", last["schema"], len(last["id"]), last["project"])
PY
}

# 1. tkt: create, start, close — each change leaves its event, in order, with the project's real path
P="$W/proj"; mkproj "$P"
id="$(cd "$P" && "$TKT" create "First & <one>" -t bug -p 1)"
(cd "$P" && "$TKT" start "$id" >/dev/null && "$TKT" close "$id" --no-sprint >/dev/null)
assert_eq "ticket.created tkt $id
ticket.status_changed tkt $id open>in_progress
ticket.status_changed tkt $id in_progress>closed
ticket.closed tkt $id" "$(events)"
assert_eq "data id kind project schema source ts | priority ticket title type | 1 16 $P" "$(shape ticket.created tkt)"
# a no-op move (start on an in-progress ticket) is not a change: no event, from tkt as from the board
nop="$(cd "$P" && "$TKT" create "No-op")"; (cd "$P" && "$TKT" start "$nop" >/dev/null && "$TKT" start "$nop" >/dev/null)
assert_eq 1 "$(events ticket.status_changed | grep -c " $nop ")"

# 2. sprint start (with a title) and the events it causes
P2="$W/proj2"; mkproj "$P2"
(cd "$P2" && "$SPRINT" start "Sprint one" >/dev/null)
sid="$(cd "$P2" && "$TKT" list 2>/dev/null | awk 'NR==1{print $1}')"
assert_contains "$(events sprint.started)" "sprint.started sprint $sid"
assert_eq "data id kind project schema source ts | ticket | 1 16 $P2" "$(shape sprint.started sprint)"

# 3. the board: + New and a status move, with the same shape as tkt's
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
SPRINT_CHECK_ROOT="$P" COCKPIT_STATE_DIR="$W/ck" COCKPIT_DAEMON_BIN=/usr/bin/false "$SPRINT_CHECK_BIN" "$port" >/dev/null 2>&1 &
PIDS+=("$!")
base="http://127.0.0.1:$port"
for _ in $(seq 1 100); do curl -s -o /dev/null "$base/api/git" && break; sleep 0.1; done
bid="$(curl -s -X POST -H 'Content-Type: application/json' -d '{"title":"From the board","type":"task","priority":2}' "$base/api/tickets" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d '{"status":"in_progress"}' "$base/api/ticket/$bid/status"
assert_contains "$(events)" "ticket.created board $bid"
assert_contains "$(events)" "ticket.status_changed board $bid open>in_progress"
t_shape="$(shape ticket.created tkt)"; b_shape="$(shape ticket.created board)"
assert_eq "${t_shape%%|*|*}" "${b_shape%%|*|*}"   # parity: same top-level keys
assert_eq "$(cut -d'|' -f2 <<<"$t_shape")" "$(cut -d'|' -f2 <<<"$b_shape")"   # and the same data keys
[[ "$(shape ticket.status_changed board | cut -d'|' -f2)" == "$(shape ticket.status_changed tkt | cut -d'|' -f2)" ]] || fail "status_changed differs between tkt and the board"

# 3b. the board closes (status_changed and closed), keeps a title on one line, and a worktree-bound ticket's move
# (written into the worktree's copy) is recorded too, with the main project as `project`
curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d '{"status":"closed"}' "$base/api/ticket/$bid/status"
assert_contains "$(event_line ticket.status_changed "$bid")" '"from":"in_progress","ticket":"'"$bid"'","to":"closed"'
assert_contains "$(event_line ticket.closed "$bid")" '"source":"board"'
nid="$(curl -s -X POST -H 'Content-Type: application/json' -d '{"title":"two\nlines","type":"task","priority":2}' "$base/api/tickets" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
assert_contains "$(event_line ticket.created "$nid")" '"title":"two lines"'
wid="$(cd "$P" && "$TKT" create "Bound one")"
git -C "$P" add -A && git -C "$P" -c user.email=t@t -c user.name=t commit -qm bound
git -C "$P" worktree add -q -b "sprint/$wid" "$W/wt-$wid"
echo "$W/wt-$wid" > "$P/.tickets/$wid/.cockpit-cwd"
curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d '{"status":"in_progress"}' "$base/api/ticket/$wid/status"
grep -q '^status: in_progress' "$W/wt-$wid/.tickets/$wid/ticket.md" || fail "setup: the bound move did not land in the worktree"
assert_contains "$(event_line ticket.status_changed "$wid")" '"from":"open","ticket":"'"$wid"'","to":"in_progress"'
assert_contains "$(event_line ticket.status_changed "$wid")" "\"project\":\"$P\""

# 3c. from a subfolder, tkt and sprint still name the project's root
mkdir -p "$P2/src/deep"
sub="$(cd "$P2/src/deep" && "$TKT" create "From a subfolder")"
(cd "$P2/src/deep" && "$TKT" start "$sub" >/dev/null && "$TKT" close "$sub" --no-sprint >/dev/null)
for k in ticket.created ticket.status_changed ticket.closed; do assert_contains "$(event_line "$k" "$sub")" "\"project\":\"$P2\""; done
P3="$W/proj3"; mkproj "$P3"; mkdir -p "$P3/src"
(cd "$P3/src" && "$SPRINT" start "Deep sprint" >/dev/null)
s3="$(cd "$P3" && "$TKT" list 2>/dev/null | awk 'NR==1{print $1}')"
assert_contains "$(event_line sprint.started "$s3")" "\"project\":\"$P3\""

# 4. a 60 KB description stays out of the event
big="$(head -c 60000 /dev/zero | tr '\0' d)"
id60="$(cd "$P" && "$TKT" create "Big one" -d "$big")"
line="$(grep -h "\"$id60\"" "$EV"/*.jsonl | grep '"ticket.created"')"
(( ${#line} < 2048 )) || fail "a 60 KB description made a ${#line}-byte event"
[[ "$line" != *ddddd* ]] || fail "the description leaked into the event"

# 5. observer-only: an unwritable events folder, no board, or an older board — same exit code, output and ticket file
snap() { (cd "$1" && "$TKT" create "Same $2" -p 3 | sed 's/t-[a-z0-9]*/ID/'; echo "rc=$?"); }
want="$(snap "$P" a)"
# Unusable for everyone, root included: CANON_HOME under a regular file, so every write fails "not a directory".
: > "$W/not-a-dir"
assert_eq "$want" "$(CANON_HOME="$W/not-a-dir/home" snap "$P" b)"
(cd "$P" && CANON_HOME="$W/not-a-dir/home" "$TKT" start "$id60" >/dev/null && CANON_HOME="$W/not-a-dir/home" "$TKT" close "$id60" --no-sprint >/dev/null) \
  || fail "tkt start/close failed with an unusable events folder"
# sprint start, and the board's create and status routes, behave the same with an unusable events folder
P4="$W/proj4"; mkproj "$P4"; P5="$W/proj5"; mkproj "$P5"
o_ok="$(cd "$P4" && "$SPRINT" start "Observer sprint" 2>&1 | sed 's/t-[a-z0-9]\{4\}/ID/g; s#'"$P4"'#ROOT#g')"
o_bad="$(cd "$P5" && CANON_HOME="$W/not-a-dir/home" "$SPRINT" start "Observer sprint" 2>&1 | sed 's/t-[a-z0-9]\{4\}/ID/g; s#'"$P5"'#ROOT#g')"
assert_eq "$o_ok" "$o_bad"
port2="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
SPRINT_CHECK_ROOT="$P5" CANON_HOME="$W/not-a-dir/home" COCKPIT_STATE_DIR="$W/ck2" COCKPIT_DAEMON_BIN=/usr/bin/false "$SPRINT_CHECK_BIN" "$port2" >/dev/null 2>&1 &
PIDS+=("$!")
base2="http://127.0.0.1:$port2"
for _ in $(seq 1 100); do curl -s -o /dev/null "$base2/api/git" && break; sleep 0.1; done
oid="$(curl -s -X POST -H 'Content-Type: application/json' -d '{"title":"Board without events","type":"task","priority":2}' "$base2/api/tickets" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
[[ -f "$P5/.tickets/$oid/ticket.md" ]] || fail "the board did not create a ticket with an unusable events folder"
assert_eq True "$(curl -s -X POST -H 'Content-Type: application/json' -d '{"status":"in_progress"}' "$base2/api/ticket/$oid/status" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])')"
grep -q '^status: in_progress' "$P5/.tickets/$oid/ticket.md" || fail "the board's status move did not land with an unusable events folder"


if [[ "$(id -u)" != 0 ]]; then
  chmod 400 "$EV"/*.jsonl; chmod 500 "$EV"
  assert_eq "$want" "$(snap "$P" e)"
  chmod 700 "$EV"; chmod 600 "$EV"/*.jsonl
fi
assert_eq "$want" "$(SPRINT_CHECK_BIN="$W/no-board" snap "$P" c)"
printf '#!/bin/sh\n[ "$1" = --help ] && { echo "sprint-check-win (headless-json only)"; exit 0; }\nsleep 20\n' > "$W/old-board"; chmod +x "$W/old-board"
start=$SECONDS; assert_eq "$want" "$(SPRINT_CHECK_BIN="$W/old-board" snap "$P" d)"
(( SECONDS - start < 10 )) || fail "an older board without \`event\` held tkt up"
[[ "$(grep -l 'Same b' "$P"/.tickets/*/ticket.md | wc -l | tr -d ' ')" == 1 ]] || fail "the ticket was not written with an unusable events folder"
for f in "$EV"/*.jsonl; do ! grep -q 'Same b\|Same c\|Same d\|Same e' "$f" || fail "an event was written although it could not or should not be"; done
[[ -f "$W/not-a-dir" && ! -s "$W/not-a-dir" ]] || fail "the file standing in for CANON_HOME was written to"
# a bad call to the writer is refused, noted, and still exits 0 with no output: an unknown kind, no kind, a bare word,
# a dangling --project
n0="$(cat "$EV"/*.jsonl | wc -l | tr -d ' ')"
for args in "ticket.deleted --source tkt --project $P ticket=t-x" "" "ticket.closed --source tkt --project $P t-bare" "ticket.closed --source tkt ticket=t-y --project"; do
  # shellcheck disable=SC2086
  out="$("$SPRINT_CHECK_BIN" event $args)"; rc=$?
  assert_eq "0:" "$rc:$out"
done
assert_eq "$n0" "$(cat "$EV"/*.jsonl | wc -l | tr -d ' ')"
errs="$(cat "$EV/emit-errors.log")"
assert_contains "$errs" 'unknown event kind "ticket.deleted"'; assert_contains "$errs" 'unknown event kind ""'
assert_contains "$errs" 'has no field "t-bare"'; assert_contains "$errs" 'has no field "--project"'

# 6. 16 writer processes at once: whole lines, none lost
CH="$W/conc"; writers=(); for w in $(seq 1 16); do
  ( for i in $(seq 1 50); do CANON_HOME="$CH" "$SPRINT_CHECK_BIN" event ticket.created --source tkt --project "$P" "ticket=t-w$w" "title=$(head -c 190 /dev/zero | tr '\0' t)"; done ) &
  writers+=("$!")
done; wait "${writers[@]}"   # not a bare wait: the board from step 3 is a background job too
assert_eq 800 "$(EV="$CH/events"; cat "$EV"/*.jsonl | python3 -c 'import json,sys; print(sum(1 for l in sys.stdin if json.loads(l)))')"

# 7. across midnight: each event in its UTC day's file
MH="$W/mid"
for ts in 2026-10-19T23:59:59.500Z 2026-10-20T00:00:00.500Z; do CANON_HOME="$MH" CANON_EVENTS_CLOCK="$ts" "$SPRINT_CHECK_BIN" event ticket.closed --source tkt --project "$P" ticket=t-mid; done
assert_eq "2026-10-19.jsonl 2026-10-20.jsonl" "$(ls "$MH/events" | grep jsonl | tr '\n' ' ' | sed 's/ $//')"

# 8. close gates (t-8854): gate.started from `gate-snapshot.sh pre --role`, gate.finished from subagent-log.sh with the report's
# verdict, gate.rejected from the check commands; and each tool behaves the same with an unusable events folder
G="$W/gates"; mkproj "$G"; gid="$(cd "$G" && "$TKT" create "Gated")"; gt="$G/.tickets/$gid"
printf '# A\n\n- [x] c\n' > "$gt/acceptance.md"; printf '# P\n' > "$gt/plan.md"; sed -i.bak 's/^eval_fail_count: 0$/eval_fail_count: 2/' "$gt/ticket.md"; rm -f "$gt/ticket.md.bak"
git -C "$G" add -A; git -C "$G" -c user.email=t@t -c user.name=t commit -qm gated
(cd "$G" && "$ROOT/tools/gate-snapshot.sh" pre ".tickets/$gid/gate-snapshot.txt" --role reviewer >/dev/null)
docs="$(cat "$gt/acceptance.md" "$gt/plan.md" | shasum -a 256 | cut -c1-12)"
assert_contains "$(event_line gate.started "$gid")" '"data":{"attempt":"3","docs":"'"$docs"'","role":"reviewer","ticket":"'"$gid"'"}'
assert_contains "$(event_line gate.started "$gid")" '"source":"gate-snapshot"'
rc=0; (cd "$G" && "$ROOT/tools/gate-snapshot.sh" pre ".tickets/$gid/gate-snapshot.txt" --role judge >/dev/null 2>&1) || rc=$?
assert_eq 2 "$rc"
printf '# Review\n\n## Verdict\n\nNO\n' > "$gt/review-notes.md"
(cd "$G" && "$ROOT/tools/subagent-log.sh" --agent-id reviewer-x --agent-type reviewer --ticket "$gid" --tokens 1200 --minutes 2.5 --model claude-sonnet-5-5 >/dev/null)
assert_contains "$(event_line gate.finished "$gid")" '"data":{"minutes":"2.5","model":"claude-sonnet-5-5","role":"reviewer","ticket":"'"$gid"'","tokens":"1200","verdict":"NO"}'
(cd "$G" && "$ROOT/tools/subagent-log.sh" --agent-id 123-4 --agent-type evaluator --ticket "$gid" >/dev/null)
assert_contains "$(event_line gate.finished "$gid")" '"verdict":"unknown"'   # no eval-report.md yet
printf 'evaluator-run-id: 1-2\n\npartial: half done\n' > "$gt/eval-report.md"
(cd "$G" && "$ROOT/tools/subagent-log.sh" --agent-id 123-5 --agent-type evaluator --ticket "$gid" --outcome fail >/dev/null)
assert_contains "$(event_line gate.finished "$gid")" '"role":"evaluator","ticket":"'"$gid"'","tokens":"","verdict":"partial"'
(cd "$G" && "$ROOT/tools/subagent-log.sh" --agent-id plain --agent-type general-purpose --ticket "$gid" >/dev/null)
[[ "$(cat "$EV"/*.jsonl | grep -c '"kind":"gate.finished"')" == 3 ]] || fail "a non-gate subagent run made a gate.finished event"
# t-7c89: a second log call for the same agent id (the totals arrive late) replaces that run's row and writes no second gate.finished.
(cd "$G" && "$ROOT/tools/subagent-log.sh" --agent-id reviewer-x --agent-type reviewer --ticket "$gid" --tokens 1500 --minutes 3 >/dev/null)
[[ "$(cat "$EV"/*.jsonl | grep -c '"kind":"gate.finished"')" == 3 ]] || fail "a repeated agent id made a second gate.finished event"
assert_eq 1 "$(grep -c '"agent_id":"reviewer-x"' "$G/.claude/subagent-runs.jsonl")"
grep '"agent_id":"reviewer-x"' "$G/.claude/subagent-runs.jsonl" | grep -q '"tokens":1500' || fail "the later row's numbers did not win"
# t-7c89: CANON_EVENT_ACTOR=system puts actor:system on an event canon records itself.
(source "$ROOT/tools/platform-lib.sh"; CANON_EVENT_ACTOR=system canon_event github.merged tkt "$G" "ticket=$gid" pr=7)
assert_contains "$(event_line github.merged "$gid")" '"actor":"system"'
# t-ff14: under Claude Code, an evaluator's gate.finished names the agent type of the harness transcript holding its run-id
# (a fallback shows as general-purpose), and leaves the field out when no transcript holds it.
FX="$(mktemp -d)"; mkdir -p "$FX/projects/-p/s1/subagents"
printf '{"agentType": "general-purpose"}\n' > "$FX/projects/-p/s1/subagents/agent-a1.meta.json"
printf 'evaluator-run-id: 777-1\n' > "$FX/projects/-p/s1/subagents/agent-a1.jsonl"
(cd "$G" && CLAUDECODE=1 CLAUDE_CONFIG_DIR="$FX" "$ROOT/tools/subagent-log.sh" --agent-id 777-1 --agent-type evaluator --ticket "$gid" >/dev/null)
assert_contains "$(event_line gate.finished "$gid")" '"agent":"general-purpose"'
(cd "$G" && CLAUDECODE=1 CLAUDE_CONFIG_DIR="$FX" "$ROOT/tools/subagent-log.sh" --agent-id 777-2 --agent-type evaluator --ticket "$gid" >/dev/null)
[[ "$(event_line gate.finished "$gid")" != *'"agent"'* ]] || fail "gate.finished named an agent with no transcript behind it"
rm -rf "$FX"
# t-ff14: the two new fields are cut at their limits (agent 32, gate_agents 8), never copied whole
long="$(head -c 40 /dev/zero | tr '\0' a)"
CANON_HOME="$W/cap" "$SPRINT_CHECK_BIN" event gate.finished --source sprint --project "$P" "ticket=t-cap" "agent=$long"
CANON_HOME="$W/cap" "$SPRINT_CHECK_BIN" event sprint.started --source sprint --project "$P" "ticket=t-cap" "gate_agents=$long"
assert_contains "$(cat "$W/cap"/events/*.jsonl)" "\"agent\":\"$(printf %.32s "$long")\""
assert_contains "$(cat "$W/cap"/events/*.jsonl)" "\"gate_agents\":\"$(printf %.8s "$long")\""
[[ "$(cat "$W/cap"/events/*.jsonl)" != *"$(printf %.33s "$long")"* ]] || fail "an event field was copied past its limit"
(cd "$G" && "$SPRINT" check-review-notes "$gid" >/dev/null 2>&1) || true
assert_contains "$(event_line gate.rejected "$gid")" '"reason":"review_shape","role":"reviewer"'
mkdir -p "$gt/evidence"; printf 'not a stamped log\n' > "$gt/evidence/x.log"
(cd "$G" && "$SPRINT" check-evidence "$gid" >/dev/null 2>&1) || true
assert_contains "$(event_line gate.rejected "$gid")" '"reason":"stale_evidence","role":"evaluator"'
# run from a subfolder, each gate tool still names the project root; a snapshot outside any ticket emits nothing; a verdict
# that is not one of the known words reads unknown; a non-numeric eval_fail_count counts as 0
mkdir -p "$G/src/deep"
(cd "$G/src/deep" && "$ROOT/tools/gate-snapshot.sh" pre "../../.tickets/$gid/gate-snapshot.txt" --role evaluator >/dev/null)
assert_contains "$(event_line gate.started "$gid")" "\"project\":\"$G\""
printf '# Review\n\n## Verdict\n\nMaybe\n' > "$gt/review-notes.md"
(cd "$G/src/deep" && "$ROOT/tools/subagent-log.sh" --agent-id reviewer-y --agent-type reviewer --ticket "$gid" >/dev/null)
assert_contains "$(event_line gate.finished "$gid")" '"verdict":"unknown"'; assert_contains "$(event_line gate.finished "$gid")" "\"project\":\"$G\""
(cd "$G/src/deep" && "$SPRINT" check-review-notes "$gid" >/dev/null 2>&1) || true
assert_contains "$(event_line gate.rejected "$gid")" "\"project\":\"$G\""
(cd "$G/src/deep" && "$SPRINT" check-evidence "$gid" >/dev/null 2>&1) || true
assert_contains "$(event_line gate.rejected "$gid")" '"reason":"stale_evidence"'; assert_contains "$(event_line gate.rejected "$gid")" "\"project\":\"$G\""
n0="$(cat "$EV"/*.jsonl | grep -c '"kind":"gate.started"')"
(cd "$G" && "$ROOT/tools/gate-snapshot.sh" pre "$W/loose-snapshot.txt" --role reviewer >/dev/null)
assert_eq "$n0" "$(cat "$EV"/*.jsonl | grep -c '"kind":"gate.started"')"
sed -i.bak 's/^eval_fail_count: 2$/eval_fail_count: lots/' "$gt/ticket.md"; rm -f "$gt/ticket.md.bak"
(cd "$G" && "$ROOT/tools/gate-snapshot.sh" pre ".tickets/$gid/gate-snapshot.txt" --role reviewer >/dev/null)
assert_contains "$(event_line gate.started "$gid")" '"attempt":"1"'
n_before="$(cat "$EV"/*.jsonl | wc -l | tr -d ' ')"
for tool in pre log review evidence; do
  case $tool in
    pre) cmd=("$ROOT/tools/gate-snapshot.sh" pre ".tickets/$gid/gate-snapshot.txt" --role evaluator) ;;
    log) cmd=("$ROOT/tools/subagent-log.sh" --agent-id 9-9 --agent-type evaluator --ticket "$gid") ;;
    review) cmd=("$SPRINT" check-review-notes "$gid") ;;
    evidence) cmd=("$SPRINT" check-evidence "$gid") ;;
  esac
  a_rc=0; a="$(cd "$G" && "${cmd[@]}" 2>&1)" || a_rc=$?
  b_rc=0; b="$(cd "$G" && CANON_HOME="$W/not-a-dir/home" "${cmd[@]}" 2>&1)" || b_rc=$?
  assert_eq "$a_rc:$(sed 's/[0-9a-f]\{40\}/H/g' <<<"$a")" "$b_rc:$(sed 's/[0-9a-f]\{40\}/H/g' <<<"$b")"
done

echo "events: ok (tkt, sprint and board writers; parity; 60 KB body kept out; observer-only; 16 writers; day files)"
