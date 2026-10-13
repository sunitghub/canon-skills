#!/usr/bin/env bash
# ticket-skeleton (t-b0c9): a new ticket starts from the same intent skeleton (Problem / Outcome / Constraints / Open questions,
# bugs also Expected / Actual, hints as HTML comments) whichever way it is created: `tkt create` without -d, the board's New
# ticket form (TYPE_TEMPLATES in static/board-core.js), and a create request with no body to server.py or the Go board. The four
# copies must be identical for every type; -d text and an empty body are kept as given. The board's Plan and Acceptance doc
# templates must equal what `sprint start` writes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
command -v node >/dev/null && command -v python3 >/dev/null && command -v curl >/dev/null || fail "ticket-skeleton: node, python3 and curl are required"

TMP="$(mktemp -d)"; PIDS=(); GO_BIN=""
cleanup() {
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP"; [[ -n "$GO_BIN" ]] && rm -rf "$(dirname "$GO_BIN")"
  return 0
}
trap cleanup EXIT
export HOME="$TMP/home" CANON_HOME="$TMP/home/.canon" XDG_CONFIG_HOME="$TMP/home/.config" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
mkdir -p "$HOME"; : > "$GIT_CONFIG_GLOBAL"

TYPES=(feature task bug chore epic)
# board <expr>: an expression over the board's real exports (eval of this test's own fixed strings, never outside input)
board() { node -e 'const b=require(process.argv[1]).loadBoard(); const v=eval("b."+process.argv[2]); process.stdout.write(String(v))' "$ROOT/tests/board-script.js" "$1"; }
body_of() {   # <ticket.md>: the body below the frontmatter and the optional "# title" line, trimmed
  python3 -c 'import re,sys; t=open(sys.argv[1]).read(); t=re.sub(r"\A---\n.*?\n---\n","",t,flags=re.S); t=re.sub(r"\A\s*# [^\n]*\n","",t); print(t.strip())' "$1"
}
trim() { python3 -c 'import sys; print(sys.stdin.read().strip())'; }

# 1. the board's form text is the reference; tkt must equal it for every type
proj="$TMP/proj"; mkdir -p "$proj"; git -C "$proj" init -q
for ty in "${TYPES[@]}"; do
  want="$(board "TYPE_TEMPLATES['$ty']" | trim)"
  [[ "$want" == "## Problem"* && "$want" == *"## Open questions"* ]] || fail "ticket-skeleton: the board's $ty template is not the skeleton: $want"
  id="$(cd "$proj" && "$TKT" create "a $ty" -t "$ty")"
  assert_eq "$want" "$(body_of "$proj/.tickets/$id/ticket.md")"
done
[[ "$(board "TYPE_TEMPLATES['bug']")" == *"## Expected"*"## Actual"*"## Outcome"* ]] || fail "ticket-skeleton: a bug keeps Expected and Actual before Outcome"
[[ "$(board "TYPE_TEMPLATES['task']")" != *"## Expected"* ]] || fail "ticket-skeleton: only a bug has Expected"
# every hint is a comment, so an untouched skeleton renders as headings only
for ty in "${TYPES[@]}"; do
  [ "$(board "TYPE_TEMPLATES['$ty']" | grep -Ev '^(## .*|<!-- .* -->)?$' | grep -c .)" -eq 0 ] || fail "ticket-skeleton: the $ty skeleton has text outside headings and comments"
done
# -d is kept exactly, even empty
id="$(cd "$proj" && "$TKT" create "given" -d "just this")"; assert_eq "just this" "$(body_of "$proj/.tickets/$id/ticket.md")"
id="$(cd "$proj" && "$TKT" create "empty" -d "")"; assert_eq "" "$(body_of "$proj/.tickets/$id/ticket.md")"

# 2. both servers: no body (absent or null) gets the skeleton for the type; an empty or given body is kept
if command -v go >/dev/null 2>&1; then
  GO_BIN="$(mktemp -d)/sprint-check-go-bin"; (cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)
fi
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
for kind in py go; do
  [[ "$kind" == go && -z "$GO_BIN" ]] && fail "ticket-skeleton: go is required to check the Go board"
  repo="$TMP/$kind"; mkdir -p "$repo/.tickets"; git -C "$repo" init -q
  port="$(free_port)"
  if [[ "$kind" == py ]]; then
    SPRINT_CHECK_ROOT="$repo" COCKPIT_STATE_DIR="$TMP/$kind-ck" COCKPIT_DAEMON_BIN=/usr/bin/false python3 "$ROOT/tools/sprint-check-app/server.py" "$port" >/dev/null 2>&1 &
  else
    SPRINT_CHECK_ROOT="$repo" COCKPIT_STATE_DIR="$TMP/$kind-ck" COCKPIT_DAEMON_BIN=/usr/bin/false SPRINT_CHECK_NO_BROWSER=1 "$GO_BIN" "$port" >/dev/null 2>&1 &
  fi
  PIDS+=("$!"); disown "$!" 2>/dev/null || true
  base="http://127.0.0.1:$port"
  for _ in $(seq 1 50); do curl -s -o /dev/null "$base/api/git" && break; sleep 0.1; done
  create() { curl -s -X POST -H 'Content-Type: application/json' --data-binary "$1" "$base/api/tickets" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'; }
  for ty in "${TYPES[@]}"; do
    id="$(create "{\"title\":\"a $ty\",\"type\":\"$ty\"}")"
    assert_eq "$(board "TYPE_TEMPLATES['$ty']" | trim)" "$(body_of "$repo/.tickets/$id/ticket.md")"
  done
  id="$(create '{"title":"null body","type":"bug","body":null}')"; assert_eq "$(board "TYPE_TEMPLATES['bug']" | trim)" "$(body_of "$repo/.tickets/$id/ticket.md")"
  id="$(create '{"title":"cleared","type":"task","body":""}')"; assert_eq "" "$(body_of "$repo/.tickets/$id/ticket.md")"
  id="$(create '{"title":"written","type":"task","body":"my words"}')"; assert_eq "my words" "$(body_of "$repo/.tickets/$id/ticket.md")"
done

# 3. the board's Plan and Acceptance templates are what `sprint start` writes
sp="$TMP/sp"; mkdir -p "$sp"; git -C "$sp" init -q
sid="$(cd "$sp" && "$SPRINT" start "templates" | awk '/Sprint started:/ { print $3 }')"
for doc in plan acceptance; do
  want="$(board "DOC_TYPES.find(d=>d.slug==='$doc').template.split('<id>').join('$sid')")"
  [[ "$want" == "$(cat "$sp/.tickets/$sid/$doc.md")" ]] || fail "ticket-skeleton: the board's $doc template differs from what sprint start writes: $(diff <(printf '%s\n' "$want") "$sp/.tickets/$sid/$doc.md" | head -5)"
done
grep -qF "## Open questions" "$sp/.tickets/$sid/plan.md" || fail "ticket-skeleton: plan.md's Decisions comment does not mention the ticket's open questions"

echo "ticket-skeleton: ok (tkt, the board form, server.py and the Go board give one skeleton per type; -d and empty bodies kept; plan/acceptance templates match sprint start)"
