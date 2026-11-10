#!/usr/bin/env bash
# api-v1 (t-0b89 slice 1) — the public read surface end to end: a real board over HTTP on a temp project and a temp CANON_HOME.
# Ticket metadata comes out without the body, the sprint snapshot is the latest valid event per kind, every route's keys match
# `canon-go api schema`, a non-loopback Host is 403, every verb but GET (and OPTIONS) is 405, no response of any status carries
# an Access-Control header, and a bad id is refused. Protects GET /api/v1/* and the `canon-go api schema` command.
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

# ── sprint: the latest valid event per kind, bad lines never served ──
sp="$(curl -s "$B/sprint/t-aaaa")"
assert_eq "1" "$(printf '%s' "$sp" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["events"]))')"
assert_eq "0000000000000002" "$(printf '%s' "$sp" | jget events 0 id)"
[[ "$sp" != *script* ]] || fail "api-v1: a line that fails the events schema was served"

# ── every route's keys are the published schema's ──
"$BIN" api schema --json > "$T/schema.json" || fail "api-v1: canon-go api schema failed"
check_keys() { # <route pattern> <url>
  want="$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["responses"][sys.argv[2]])))' "$T/schema.json" "$1")"
  got="$(curl -s "$2" | python3 -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin))))')"
  assert_eq "$want" "$got"
}
check_keys /api/v1/tickets "$B/tickets"; check_keys '/api/v1/tickets/{id}' "$B/tickets/t-aaaa"
check_keys '/api/v1/sprint/{ticket}' "$B/sprint/t-aaaa"; check_keys /api/v1/sessions "$B/sessions"
check_keys '/api/v1/sessions/{id}/state' "$B/sessions/t-aaaa/state"
assert_contains "$(cat "$T/schema.json")" '"gate.finished"'

# ── refusals: Host, verbs, CORS, bad ids ──
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
for route in sessions sessions/t-aaaa tickets tickets/t-aaaa sprint/t-aaaa; do
  assert_eq "403" "$(code -H 'Host: evil.example' "$B/$route")"
  for m in POST PUT DELETE; do assert_eq "405" "$(code -X "$m" "$B/$route")"; done
done
assert_eq "204" "$(code -X OPTIONS -H 'Origin: http://evil.example' -H 'Access-Control-Request-Method: GET' "$B/tickets")"
for target in tickets sessions sprint/t-aaaa tickets/nope tickets/t-zzzz; do
  for m in GET OPTIONS POST; do
    if curl -s -D - -o /dev/null -X "$m" -H 'Origin: http://evil.example' "$B/$target" | grep -qi '^access-control-'; then fail "api-v1: $m /$target sent an Access-Control header"; fi
  done
done
assert_eq "400" "$(code "$B/tickets?project=ffffffffffff")"
assert_eq "400" "$(code "$B/sessions/x-1")"
assert_eq "307" "$(code --path-as-is "$B/sprint/..")"   # the mux cleans a dot-dot path before any handler sees it
assert_eq "400" "$(code "$B/sprint/t-AAAA")"
assert_eq "307" "$(code --path-as-is "$B/tickets/../../x")"
assert_eq "404" "$(code "$B/nope")"

echo "PASS: api-v1"
