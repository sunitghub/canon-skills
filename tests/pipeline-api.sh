#!/usr/bin/env bash
# pipeline-api (t-3a58) — Factory > Pipeline's routes end to end: a real board over HTTP on a temp project, the real tools/pipeline.sh
# as the one reader. The first change creates canon-config/pipeline.yaml and says so once, what the tab wrote is accepted by
# `pipeline.sh check` and by `sprint approve` (which pins it), a POST with no Origin, a cross-site fetch, a locked node or a bad body
# is refused and the file stays byte for byte, and Reset leaves `extends: canon-default`.
# Protects GET and POST /api/pipeline, the routes the Cockpit's Factory > Pipeline tab calls, and the files `sprint approve` and
# `sprint complete` read from what it writes.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
command -v curl >/dev/null 2>&1 || fail "pipeline-api: curl is required"
command -v python3 >/dev/null 2>&1 || fail "pipeline-api: python3 is required (test-only JSON parsing)"

T="$(mktemp -d)"; BOARD_DIR="$(mktemp -d)"; GO_PID=""
cleanup() { [[ -n "$GO_PID" ]] && kill "$GO_PID" 2>/dev/null || true; rm -rf "$T" "$BOARD_DIR"; }
trap cleanup EXIT

PROJECT="$(cd "$(make_project)" && pwd -P)"; mkdir -p "$PROJECT/.tickets"
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
jget() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1:]: d=d[k] if not k.isdigit() else d[int(k)]
print(d)' "$@"; }

PORT="$(free_port)"
BIN="$(build_board "$BOARD_DIR")"
(cd "$ROOT" && SPRINT_CHECK_ROOT="$PROJECT" CANON_HOME="$T/home" PIPELINE_BIN="$ROOT/tools/pipeline.sh" SPRINT_CHECK_NO_BROWSER=1 TMPDIR="$T" exec "$BIN" "$PORT") &
GO_PID=$!
disown "$GO_PID" 2>/dev/null || true
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/tickets" && break; sleep 0.1; done
B="http://127.0.0.1:$PORT"; O="Origin: $B"
curl -s -o /dev/null "$B/api/tickets" || fail "pipeline-api: the board did not start on port $PORT"

FILE="$PROJECT/canon-config/pipeline.yaml"
post() { curl -s -o "$T/body" -w '%{http_code}' -X POST -H "$O" -H 'Content-Type: application/json' --data "$1" "$B/api/pipeline"; }

# ── GET: the default list, and nothing created ──
got="$(curl -s -H "$O" "$B/api/pipeline")"
assert_eq "True" "$(printf '%s' "$got" | jget ok)"
assert_eq "False" "$(printf '%s' "$got" | jget exists)"
assert_eq "False" "$(printf '%s' "$got" | jget changed)"
assert_eq "14" "$(printf '%s' "$got" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["nodes"]))')"
[[ ! -e "$PROJECT/canon-config" ]] || fail "pipeline-api: a GET created canon-config"

# ── the first change creates the file and says so once ──
assert_eq "200" "$(post '{"op":"toggle","id":"mutation-test","on":false}')"
assert_eq "True" "$(jget created < "$T/body")"
assert_eq "extends: canon-default
off: [mutation-test]" "$(cat "$FILE")"
assert_eq "200" "$(post '{"op":"order","wrapup":["doc-audit","code-reviewer","code-simplifier"]}')"
assert_eq "False" "$(jget created < "$T/body")"
assert_eq "extends: canon-default
off: [mutation-test]
wrapup-order: [doc-audit, code-reviewer, code-simplifier]" "$(cat "$FILE")"

# ── what the tab wrote is read by the reader and pinned by sprint approve ──
out="$("$ROOT/tools/pipeline.sh" check --project "$PROJECT")"
assert_eq "pipeline: ok (14 nodes)" "$out"
(
  cd "$PROJECT"
  start_out="$("$SPRINT" start "tab wrote this")"
  id="$(printf '%s\n' "$start_out" | awk '/Sprint started:/ { print $3 }')"
  printf '# Plan\n## Sign-off\nTier: normal | Risk: low\n- [ ] Plan approved\n## Approach\ntest\n' > ".tickets/$id/plan.md"
  "$SPRINT" approve "$id" >/dev/null
  pin="$(sed -n 's/^Pipeline: sha256:[0-9a-f]* //p' ".tickets/$id/plan.md")"
  [[ "$pin" == "off=mutation-test wrapup=doc-audit,code-reviewer,code-simplifier" ]] || { echo "FAIL: pipeline-api: sprint approve pinned: $pin" >&2; exit 1; }
) || fail "pipeline-api: sprint approve did not pin what the tab wrote"

# ── refusals leave the file byte for byte ──
want="$(cat "$FILE")"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data '{"op":"reset"}' "$B/api/pipeline")"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://evil.example' -H 'Content-Type: application/json' --data '{"op":"reset"}' "$B/api/pipeline")"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$O" -H 'Sec-Fetch-Site: cross-site' -H 'Content-Type: application/json' --data '{"op":"reset"}' "$B/api/pipeline")"
assert_eq "415" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$O" -H 'Content-Type: text/plain' --data '{"op":"reset"}' "$B/api/pipeline")"
assert_eq "400" "$(post '{"op":"toggle","id":"eval","on":false}')"
assert_contains "$(cat "$T/body")" "node 'eval' is locked"
assert_eq "400" "$(post '{"op":"toggle","id":"$(touch PWNED)","on":false}')"
assert_eq "400" "$(post 'not json')"
assert_eq "400" "$(post '{"op":"reset","extra":1}')"
big="$(python3 -c 'print("{\"op\":\"reset\",\"id\":\"" + "a" * 20000 + "\"}")')"
assert_eq "413" "$(post "$big")"
assert_eq "400" "$(curl -s -o /dev/null -w '%{http_code}' -H "$O" "$B/api/pipeline?project=ffffffffffff")"
assert_eq "$want" "$(cat "$FILE")"
[[ ! -e "$ROOT/PWNED" && ! -e "$PROJECT/PWNED" ]] || fail "pipeline-api: a request ran a command"
[[ "$(ls -A "$PROJECT/canon-config")" == "pipeline.yaml" ]] || fail "pipeline-api: a temp file was left in canon-config: $(ls -A "$PROJECT/canon-config")"

# ── a symlinked canon-config is refused and the target is untouched ──
rm -r "$PROJECT/canon-config"; mkdir "$T/elsewhere"; ln -s "$T/elsewhere" "$PROJECT/canon-config"
assert_eq "409" "$(post '{"op":"toggle","id":"skill-eval","on":false}')"
[[ -z "$(ls -A "$T/elsewhere")" ]] || fail "pipeline-api: a write went through a symlinked canon-config"
rm "$PROJECT/canon-config"; mkdir "$PROJECT/canon-config"; printf '%s\n' "$want" > "$FILE"

# ── Reset leaves canon's default only ──
assert_eq "200" "$(post '{"op":"reset"}')"
assert_eq "extends: canon-default" "$(cat "$FILE")"
assert_eq "False" "$(jget changed < "$T/body")"

echo "PASS: pipeline-api"
