#!/usr/bin/env bash
# api-v1 (t-0b89 slice 1) — the public read surface end to end: a real board over HTTP on a temp project and a temp CANON_HOME.
# Ticket metadata comes out without the body, the sprint snapshot is the latest valid event per kind, every route's keys match
# `canon-go api schema`, a non-loopback Host is 403, every verb but GET (and OPTIONS) is 405, no response of any status carries
# an Access-Control header, and a bad id is refused. t-8d45: the events snapshot and a stream that resumes from its last id with no
# duplicate and no gap, and a hostile cursor is a 400. Protects GET /api/v1/* and the `canon-go api schema` command.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
command -v curl >/dev/null 2>&1 || fail "api-v1: curl is required"
command -v python3 >/dev/null 2>&1 || fail "api-v1: python3 is required (test-only JSON parsing)"

T="$(mktemp -d)"; BOARD_DIR="$(mktemp -d)"; GO_PID=""
cleanup() { [[ -n "$GO_PID" ]] && kill "$GO_PID" 2>/dev/null || true; rm -rf "$T" "$BOARD_DIR"; }
trap cleanup EXIT

PROJECT="$(cd "$(make_project)" && pwd -P)"; mkdir -p "$PROJECT/.tickets/t-aaaa" "$T/home/events"
printf -- '---\nid: t-aaaa\nstatus: open\ntype: bug\npriority: 1\ncreated: 2026-11-01T00:00:00Z\n---\n# Title A\n\nBODYMARKER\n' > "$PROJECT/.tickets/t-aaaa/ticket.md"
printf '# Plan\nPLANMARKER\n' > "$PROJECT/.tickets/t-aaaa/plan.md"
ev() { printf '{"schema":1,"id":"%s","ts":"%s","kind":"%s","source":"sprint","project":"%s","data":{"ticket":"t-aaaa"%s}}\n' "$1" "$2" "$3" "$PROJECT" "$4"; }
{ ev 0000000000000001 2026-11-01T10:00:00.000Z gate.finished ',"role":"reviewer","verdict":"fail"'
  echo 'not json'
  ev 0000000000000002 2026-11-01T11:00:00.000Z gate.finished ',"role":"reviewer","verdict":"pass"'
  ev 0000000000000003 2026-11-01T12:00:00.000Z gate.rejected ',"evil":"<script>"'; } > "$T/home/events/2026-11-01.jsonl"

# a cloned repo can ship a symlinked ticket.md and a FIFO doc (t-ca73): neither may be read or hang the loader
mkdir -p "$PROJECT/.tickets/t-eeee" "$PROJECT/.tickets/t-gggg" "$T/outside"
printf -- '---\nid: t-eeee\nstatus: open\n---\n# OUTSIDEMARKER\n' > "$T/outside/real.md"
ln -s "$T/outside/real.md" "$PROJECT/.tickets/t-eeee/ticket.md"
printf -- '---\nid: t-gggg\nstatus: open\n---\n# Title G\n' > "$PROJECT/.tickets/t-gggg/ticket.md"
mkfifo "$PROJECT/.tickets/t-gggg/plan.md"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
jget() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1:]: d=d[k] if not k.isdigit() else d[int(k)]
print(d)' "$@"; }

PORT="$(free_port)"
BIN="$(build_board "$BOARD_DIR")"
(cd "$ROOT" && SPRINT_CHECK_ROOT="$PROJECT" CANON_HOME="$T/home" SPRINT_CHECK_NO_BROWSER=1 TMPDIR="$T" exec "$BIN" "$PORT") &
GO_PID=$!
disown "$GO_PID" 2>/dev/null || true
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/tickets" && break; sleep 0.1; done
B="http://127.0.0.1:$PORT/api/v1"
curl -s -o /dev/null "$B/tickets" || fail "api-v1: the board did not start on port $PORT"

# ── tickets: metadata only ──
for route in tickets tickets/t-aaaa; do
  body="$(curl -s "$B/$route")"
  for bad in BODYMARKER PLANMARKER '"body"' '"docs"'; do
    [[ "$body" != *"$bad"* ]] || fail "api-v1: /$route served $bad"
  done
  assert_contains "$body" '"title":"Title A"'
done
assert_eq "1" "$(curl -s "$B/tickets/t-aaaa" | jget ticket priority)"

# the loader answers (curl -m 5 would give 000 on a hang), shows the FIFO's ticket, and never reads the link's target
assert_eq "200" "$(curl -s -m 5 -o "$T/list" -w "%{http_code}" "$B/tickets")"
assert_contains "$(cat "$T/list")" '"title":"Title G"'
[[ "$(cat "$T/list")" != *OUTSIDEMARKER* ]] || fail "api-v1: a symlinked ticket.md was read"
assert_eq "404" "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$B/tickets/t-eeee")"

# ── sprint: the latest valid event per kind, bad lines never served ──
sp="$(curl -s "$B/sprint/t-aaaa")"
assert_eq "1" "$(printf '%s' "$sp" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["events"]))')"
assert_eq "0000000000000002" "$(printf '%s' "$sp" | jget events 0 id)"
[[ "$sp" != *script* ]] || fail "api-v1: a line that fails the events schema was served"

# ── events (t-8d45): the snapshot is the project's valid events with a cursor; a stream resumes from its last id with no duplicate and no gap ──
snap="$(curl -s "$B/events")"
assert_eq "2" "$(printf '%s' "$snap" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["events"]))')"   # ids 1 and 2: id 3 fails the schema, 'not json' is skipped
[[ "$snap" != *script* ]] || fail "api-v1: the events snapshot served a line that fails the schema"
cursor="$(printf '%s' "$snap" | jget cursor)"
[[ "$cursor" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}:[0-9]+$ ]] || fail "api-v1: snapshot cursor is $cursor"
newest="$T/home/events/${cursor%%:*}.jsonl"   # the cursor names the newest day (the board writes its own events there): new events are appended to it
assert_eq "0000000000000002" "$(curl -s "$B/events?limit=1" | jget events 0 id)"
for bad in 0 501 abc -1; do assert_eq "400" "$(curl -s -o /dev/null -w '%{http_code}' "$B/events?limit=$bad")"; done
for c in '../../x:0' '2026-11-01:-1' '2026-13-45:0' '2026-10-31:0' '2026-11-01:99999999' x; do
  assert_eq "400" "$(curl -s -o /dev/null -w '%{http_code}' -H "Last-Event-ID: $c" "$B/events/stream")"
done
stream_ids() { grep '^data: ' "$1" | sed -E 's/.*"id":"0*([0-9a-f]+)".*/\1/' | paste -sd, -; }
ev_id() { printf '{"schema":1,"id":"%016x","ts":"2026-11-01T13:00:00.000Z","kind":"gate.finished","source":"sprint","project":"%s","data":{"ticket":"t-aaaa","role":"reviewer","verdict":"pass"}}\n' "$1" "$PROJECT"; }
curl -sN -m 3 "$B/events/stream?cursor=$cursor" > "$T/s1" & S1=$!
sleep 1; ev_id 4 >> "$newest"; wait "$S1" || true
assert_eq "4" "$(stream_ids "$T/s1")"
last="$(grep '^id: ' "$T/s1" | tail -1 | sed 's/^id: //')"
ev_id 5 >> "$newest"; echo 'not json' >> "$newest"; ev_id 6 >> "$newest"
curl -sN -m 2 -H "Last-Event-ID: $last" "$B/events/stream" > "$T/s2" || true
assert_eq "5,6" "$(stream_ids "$T/s2")"   # every missed event once, in order, and not 4 again

# ── every route's keys are the published schema's ──
SPRINT_CHECK_NO_BROWSER=1 "$BIN" api schema --json > "$T/schema.json" || fail "api-v1: canon-go api schema failed"
check_keys() { # <route pattern> <url>
  want="$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["responses"][sys.argv[2]])))' "$T/schema.json" "$1")"
  got="$(curl -s "$2" | python3 -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin))))')"
  assert_eq "$want" "$got"
}
check_keys /api/v1/tickets "$B/tickets"; check_keys '/api/v1/tickets/{id}' "$B/tickets/t-aaaa"
check_keys '/api/v1/sprint/{ticket}' "$B/sprint/t-aaaa"; check_keys /api/v1/sessions "$B/sessions"
check_keys '/api/v1/sessions/{id}/state' "$B/sessions/t-aaaa/state"
check_keys /api/v1/events "$B/events"
assert_contains "$(cat "$T/schema.json")" '"gate.finished"'
# the stream route is published too: its content type, its frame (id and data lines), and the stream cap come from the handler's own variables
stream_schema="$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["streams"]["/api/v1/events/stream"]; print(s["content_type"]); print(s["frame"]); print(s["max_streams"]); print(s["lifetime_s"])' "$T/schema.json")" || fail "api-v1: the schema has no stream entry for /api/v1/events/stream"
assert_contains "$stream_schema" "text/event-stream"
assert_contains "$stream_schema" "id: "
assert_contains "$stream_schema" "data: "
assert_eq "4 900" "$(printf '%s\n' "$stream_schema" | tail -2 | paste -sd' ' -)"

# ── refusals: Host, verbs, CORS, bad ids ──
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
for route in sessions sessions/t-aaaa tickets tickets/t-aaaa sprint/t-aaaa events events/stream; do
  assert_eq "403" "$(code -H 'Host: evil.example' "$B/$route")"
  for m in POST PUT DELETE; do assert_eq "405" "$(code -X "$m" "$B/$route")"; done
done
assert_eq "204" "$(code -X OPTIONS -H 'Origin: http://evil.example' -H 'Access-Control-Request-Method: GET' "$B/tickets")"
for m in OPTIONS POST; do   # a GET of the stream would stream: only its refusals are checked here
  hdr="$(curl -s -D - -o /dev/null -X "$m" -H 'Origin: http://evil.example' "$B/events/stream")"
  if grep -qi '^access-control-' <<<"$hdr"; then fail "api-v1: $m /events/stream sent an Access-Control header"; fi
done
for target in tickets sessions sprint/t-aaaa events tickets/nope tickets/t-zzzz; do
  for m in GET OPTIONS POST; do
    hdr="$(curl -s -D - -o /dev/null -X "$m" -H 'Origin: http://evil.example' "$B/$target")"
    if grep -qi '^access-control-' <<<"$hdr"; then fail "api-v1: $m /$target sent an Access-Control header"; fi
  done
done
assert_eq "400" "$(code "$B/tickets?project=ffffffffffff")"
assert_eq "400" "$(code "$B/sessions/x-1")"
assert_eq "307" "$(code --path-as-is "$B/sprint/..")"   # the mux cleans a dot-dot path before any handler sees it
assert_eq "400" "$(code "$B/sprint/t-AAAA")"
assert_eq "307" "$(code --path-as-is "$B/tickets/../../x")"
assert_eq "404" "$(code "$B/nope")"

echo "PASS: api-v1"
