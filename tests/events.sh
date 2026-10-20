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
export CANON_HOME="$W/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
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
chmod 400 "$EV"/*.jsonl; chmod 500 "$EV"   # neither today's file nor a new one can be written
assert_eq "$want" "$(snap "$P" b)"
(cd "$P" && "$TKT" start "$id60" >/dev/null && "$TKT" close "$id60" --no-sprint >/dev/null) || fail "tkt start/close failed with an unwritable events folder"
chmod 700 "$EV"; chmod 600 "$EV"/*.jsonl
assert_eq "$want" "$(SPRINT_CHECK_BIN="$W/no-board" snap "$P" c)"
printf '#!/bin/sh\n[ "$1" = --help ] && { echo "sprint-check-win (headless-json only)"; exit 0; }\nsleep 20\n' > "$W/old-board"; chmod +x "$W/old-board"
start=$SECONDS; assert_eq "$want" "$(SPRINT_CHECK_BIN="$W/old-board" snap "$P" d)"
(( SECONDS - start < 10 )) || fail "an older board without \`event\` held tkt up"
[[ "$(grep -l 'Same b' "$P"/.tickets/*/ticket.md | wc -l | tr -d ' ')" == 1 ]] || fail "the ticket was not written with an unwritable events folder"
for f in "$EV"/*.jsonl; do ! grep -q 'Same b\|Same c\|Same d' "$f" || fail "an event was written although it could not or should not be"; done
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

echo "events: ok (tkt, sprint and board writers; parity; 60 KB body kept out; observer-only; 16 writers; day files)"
