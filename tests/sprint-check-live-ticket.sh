#!/usr/bin/env bash
# sprint-check-live-ticket (t-8be2) — for a ticket bound to a worktree, the board shows that worktree copy's
# status, title, Description and Demo (t-26f9 did the docs) and writes status/demo/body THERE, never to main's
# ticket.md, identically in server.py and main.go. A body save is guarded by the etag it read (base_hash); status
# and demo are single-field edits of the current bytes. The binding comes from the agent-writable .cockpit-cwd
# lock, so every write re-validates its target (registered worktree, plain folders, no symlinks, size cap, atomic
# rename) and ACTIVE follows tkt's per-checkout file.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "sprint-check-live-ticket: python3/curl/git absent — skipped"
  exit 0
fi

SERVER_PY="$ROOT/tools/sprint-check-app/server.py"
TKT_BIN="$ROOT/tools/tkt"
GO_BIN=""
PIDS=()
TMP="$(mktemp -d)"
cleanup() {
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
  [[ -n "$GO_BIN" ]] && rm -rf "$(dirname "$GO_BIN")"
  return 0
}
trap cleanup EXIT

if command -v go >/dev/null 2>&1; then
  GO_BIN="$(mktemp -d)/sprint-check-go-bin"
  (cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)
fi

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
fm() { printf -- '---\nid: %s\nstatus: %s\ntype: task\npriority: 2\n---\n# %s\n' "$1" "$2" "$1"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

run_checks() {
  local kind="$1" label="$2" repo wt port base out
  repo="$TMP/$kind/proj"; wt="$TMP/$kind/proj-worktrees/sprint-t-lv01"; out="$TMP/$kind/outside"
  mkdir -p "$repo/.tickets/t-lv01" "$repo/.tickets/t-lv02" "$repo/.tickets/t-lv03" "$out/.tickets/t-lv03"
  git -C "$repo" init -q -b master
  git -C "$repo" config user.email t@t && git -C "$repo" config user.name t
  fm t-lv01 open > "$repo/.tickets/t-lv01/ticket.md"
  fm t-lv02 open > "$repo/.tickets/t-lv02/ticket.md"
  fm t-lv03 open > "$repo/.tickets/t-lv03/ticket.md"
  git -C "$repo" add -A && git -C "$repo" commit -q -m init
  git -C "$repo" worktree add -q -b sprint/t-lv01 "$wt"
  # The sprint's live copy: in progress, its own title and Description, Demo on.
  printf -- '---\nid: t-lv01\nstatus: in_progress\ntype: task\npriority: 2\ndemo: true\n---\n# Live title\n\nlive description\nstatus: written in the body\n' > "$wt/.tickets/t-lv01/ticket.md"
  fm t-lv03 in_progress > "$out/.tickets/t-lv03/ticket.md"      # a decoy shaped like a worktree, NOT registered with git
  echo "$wt" > "$repo/.tickets/t-lv01/.cockpit-cwd"
  echo "$out" > "$repo/.tickets/t-lv03/.cockpit-cwd"

  port="$(free_port)"
  if [[ "$kind" == py ]]; then
    SPRINT_CHECK_ROOT="$repo" CANON_HOME="$TMP/$kind/canon" COCKPIT_STATE_DIR="$TMP/$kind/ck" COCKPIT_DAEMON_BIN=/usr/bin/false SPRINT_CHECK_DIVERGENCE_TTL=0 \
      python3 "$SERVER_PY" "$port" >/dev/null 2>&1 &
  else
    SPRINT_CHECK_ROOT="$repo" CANON_HOME="$TMP/$kind/canon" COCKPIT_STATE_DIR="$TMP/$kind/ck" COCKPIT_DAEMON_BIN=/usr/bin/false SPRINT_CHECK_DIVERGENCE_TTL=0 SPRINT_CHECK_NO_BROWSER=1 \
      "$GO_BIN" "$port" >/dev/null 2>&1 &
  fi
  PIDS+=("$!"); disown "$!" 2>/dev/null || true
  base="http://127.0.0.1:$port"
  for _ in $(seq 1 50); do curl -s -o /dev/null "$base/api/git" && break; sleep 0.1; done

  tfield() { curl -s "$base/api/tickets" | python3 -c 'import json,sys; t={x["id"]:x for x in json.load(sys.stdin)}[sys.argv[1]]; print(json.dumps({k:t.get(k) for k in sys.argv[2:]}, sort_keys=True))' "$@"; }
  post() { curl -s -o "$TMP/$kind/post.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary "$2" "$base/api/ticket/$1"; }
  pj() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$TMP/$kind/post.json" "$1"; }
  local mainf="$repo/.tickets/t-lv01/ticket.md" wtf="$wt/.tickets/t-lv01/ticket.md" code main_before wt_before

  # 1. Overlay: the worktree copy's status, title, body, demo and an etag of its exact bytes. branch_divergence stays on
  #    the payload (t-2241's dirty/merged signal); only the page hides its banner, as the statuses now agree.
  [[ "$(tfield t-lv01 status title demo ticket_etag)" == "{\"demo\": \"true\", \"status\": \"in_progress\", \"ticket_etag\": \"$(sha "$wtf")\", \"title\": \"Live title\"}" ]] \
    || fail "$label: a bound ticket must show the worktree's status/title/demo/etag, got $(tfield t-lv01 status title demo ticket_etag)"
  curl -s "$base/api/tickets" | python3 -c 'import json,sys; t={x["id"]:x for x in json.load(sys.stdin)}["t-lv01"]; d=t.get("branch_divergence") or {}; sys.exit(0 if d.get("where")=="worktree" and d.get("status")=="in_progress" else 1)' \
    || fail "$label: a bound ticket must keep its branch_divergence (where/status) on the payload"
  curl -s "$base/api/tickets" | python3 -c 'import json,sys; t={x["id"]:x for x in json.load(sys.stdin)}["t-lv01"]; sys.exit(0 if "live description" in t["body"] else 1)' \
    || fail "$label: a bound ticket's body must be the worktree's"
  [[ "$(tfield t-lv02 status ticket_etag)" == '{"status": "open", "ticket_etag": null}' ]] || fail "$label: an unbound ticket must stay main's, got $(tfield t-lv02 status ticket_etag)"
  # The decoy lock (an unregistered folder) binds nothing.
  [[ "$(tfield t-lv03 status ticket_etag)" == '{"status": "open", "ticket_etag": null}' ]] || fail "$label: a lock naming an unregistered folder must be ignored, got $(tfield t-lv03 status ticket_etag)"

  main_before="$(sha "$mainf")"; wt_before="$(sha "$wtf")"
  # 2. Status writes the worktree copy only and moves the worktree's ACTIVE, never main's.
  code="$(post t-lv01/status '{"status":"closed"}')"
  [[ "$code" == 200 && "$(pj ok)" == True && "$(pj etag)" == "$(sha "$wtf")" ]] || fail "$label: a bound status write must succeed with the new etag, got $code $(cat "$TMP/$kind/post.json")"
  grep -q '^status: closed$' "$wtf" || fail "$label: the worktree copy's status was not written"
  grep -q '^demo: true$' "$wtf" && grep -q 'live description' "$wtf" || fail "$label: a status write must keep every other field and the body"
  grep -q '^status: written in the body$' "$wtf" || fail "$label: a status write must edit the frontmatter only, never a body line that starts with status:"
  [[ "$(sha "$mainf")" == "$main_before" ]] || fail "$label: main's ticket.md must be untouched by a bound status write"
  code="$(post t-lv01/status '{"status":"in_progress"}')"
  [[ "$code" == 200 && "$(tr -d '[:space:]' < "$wt/.tickets/ACTIVE")" == t-lv01 && ! -e "$repo/.tickets/ACTIVE" ]] || fail "$label: in_progress must set the WORKTREE's ACTIVE only"
  [[ "$(cd "$wt" && "$TKT_BIN" show t-lv01 | awk '/^Status:/{print $2}')" == in_progress ]] || fail "$label: tkt in the worktree must see the board's status"
  [[ "$(cd "$wt" && "$TKT_BIN" current | awk '{print $1}')" == t-lv01 ]] || fail "$label: tkt current in the worktree must name the ticket the board started, got $(cd "$wt" && "$TKT_BIN" current 2>&1)"
  code="$(post t-lv01/status '{"status":"closed"}')"
  [[ "$code" == 200 && ! -e "$wt/.tickets/ACTIVE" ]] || fail "$label: closing must release the worktree's ACTIVE"
  [[ "$(cd "$wt" && "$TKT_BIN" show t-lv01 | awk '/^Status:/{print $2}')" == closed ]] || fail "$label: tkt in the worktree must see the board closing it"
  post t-lv01/status '{"status":"in_progress"}' >/dev/null
  # 2a. Only a known status is written: nothing a newline can smuggle into the frontmatter.
  wt_before="$(sha "$wtf")"
  for bad in '' 'bogus' $'in_progress\nevil: 1' 'closed ' 'CLOSED'; do
    code="$(post t-lv01/status "$(python3 -c 'import json,sys; print(json.dumps({"status": sys.argv[1]}))' "$bad")")"
    [[ "$code" == 400 && "$(pj code)" == bad_status ]] || fail "$label: status '$bad' must be 400 bad_status, got $code $(cat "$TMP/$kind/post.json")"
  done
  [[ "$(sha "$wtf")" == "$wt_before" && "$(sha "$mainf")" == "$main_before" ]] || fail "$label: a refused status changed a file"

  # 3. Demo.
  code="$(post t-lv01/demo '{"demo":false}')"
  [[ "$code" == 200 && -z "$(grep '^demo:' "$wtf" || true)" && "$(sha "$mainf")" == "$main_before" ]] || fail "$label: Demo off must edit the worktree copy only, got $code"
  code="$(post t-lv01/demo '{"demo":true}')"
  [[ "$code" == 200 ]] && grep -q '^demo: true$' "$wtf" && [[ "$(sha "$mainf")" == "$main_before" ]] || fail "$label: Demo on must edit the worktree copy only"

  # 4. Body: guarded by base_hash, frontmatter kept, size capped, main untouched.
  local etag; etag="$(sha "$wtf")"
  code="$(post t-lv01/body '{"body":"# Board title\n\nboard edit"}')"
  [[ "$code" == 409 && "$(pj code)" == stale ]] || fail "$label: a body save without base_hash must be 409 stale, got $code"
  code="$(post t-lv01/body '{"body":"# Board title\n\nboard edit","base_hash":"deadbeef"}')"
  [[ "$code" == 409 && "$(pj code)" == stale && "$(sha "$wtf")" == "$etag" ]] || fail "$label: a wrong base_hash must be 409 stale and write nothing, got $code"
  code="$(post t-lv01/body "{\"body\":\"# Board title\\n\\nboard edit\",\"base_hash\":\"$etag\"}")"
  [[ "$code" == 200 && "$(pj etag)" == "$(sha "$wtf")" ]] || fail "$label: a matching base_hash must write and return the new etag, got $code $(cat "$TMP/$kind/post.json")"
  grep -q 'board edit' "$wtf" && grep -q '^id: t-lv01$' "$wtf" && grep -q '^status: in_progress$' "$wtf" || fail "$label: a body save must keep the frontmatter"
  [[ "$(sha "$mainf")" == "$main_before" ]] || fail "$label: main's ticket.md must be untouched by a bound body save"
  [[ "$(tfield t-lv01 title ticket_etag)" == "{\"ticket_etag\": \"$(sha "$wtf")\", \"title\": \"Board title\"}" ]] || fail "$label: the title and etag must follow the saved body"
  code="$(post t-lv01/body "{\"body\":\"again\",\"base_hash\":\"$etag\"}")"
  [[ "$code" == 409 ]] || fail "$label: a used-up base_hash must be stale, got $code"
  # 4a. A write by anything else (tkt, the sprint) between the read and the save makes the save stale.
  etag="$(sha "$wtf")"
  python3 - "$wtf" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
open(p, 'w').write(t.replace('priority: 2\n', 'priority: 2\neval_fail_count: 1\n', 1))
PY
  code="$(post t-lv01/body "{\"body\":\"clobber\",\"base_hash\":\"$etag\"}")"
  [[ "$code" == 409 ]] && ! grep -q clobber "$wtf" && grep -q '^eval_fail_count: 1$' "$wtf" || fail "$label: a save over someone else's write must be stale and keep their field, got $code"
  # 4b. Over 1 MiB is refused with nothing written.
  etag="$(sha "$wtf")"
  python3 -c 'import json; print(json.dumps({"body": "x" * ((1 << 20) + 1), "base_hash": "'"$etag"'"}))' > "$TMP/$kind/big.json"
  code="$(curl -s -o "$TMP/$kind/post.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @"$TMP/$kind/big.json" "$base/api/ticket/t-lv01/body")"
  [[ "$code" == 400 && "$(pj code)" == too_large && "$(sha "$wtf")" == "$etag" ]] || fail "$label: a body over 1 MiB must be 400 too_large, got $code"

  # 5. Hostile targets: each leaves every file as it was.
  local victim="$TMP/$kind/victim.txt" snap
  printf 'victim\n' > "$victim"
  #   a lock naming an unregistered folder: the write goes to main's copy (unbound) and never to the decoy
  snap="$(sha "$out/.tickets/t-lv03/ticket.md")"
  post t-lv03/status '{"status":"in_progress"}' >/dev/null
  [[ "$(sha "$out/.tickets/t-lv03/ticket.md")" == "$snap" ]] || fail "$label: a write must never reach an unregistered folder named by a lock"
  #   a symlinked ticket.md in the worktree
  cp "$wtf" "$TMP/$kind/ticket.saved"; rm "$wtf"; ln -s "$victim" "$wtf"
  code="$(post t-lv01/status '{"status":"closed"}')"
  [[ "$code" == 403 && "$(pj code)" == unsafe_path && "$(cat "$victim")" == victim ]] || fail "$label: a symlinked ticket.md must be refused (403 unsafe_path) and the link target untouched, got $code"
  rm "$wtf"; cp "$TMP/$kind/ticket.saved" "$wtf"
  #   a symlinked ACTIVE
  rm -f "$wt/.tickets/ACTIVE"; ln -s "$victim" "$wt/.tickets/ACTIVE"; wt_before="$(sha "$wtf")"
  code="$(post t-lv01/status '{"status":"in_progress"}')"
  [[ "$code" == 403 && "$(cat "$victim")" == victim && "$(sha "$wtf")" == "$wt_before" ]] || fail "$label: a symlinked ACTIVE must be refused before anything is written, got $code"
  rm -f "$wt/.tickets/ACTIVE"
  #   a path-shaped id never leaves the tickets folder
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary '{"status":"closed"}' "$base/api/ticket/..%2foutside%2ft-lv03/status")"
  [[ "$(sha "$out/.tickets/t-lv03/ticket.md")" == "$snap" ]] || fail "$label: a path-shaped id must not write outside the tickets folder (got $code)"

  # 5b. Reads never go through a link the agent made (break-it): a symlinked ticket.md or .tickets shows main's copy.
  cp "$wtf" "$TMP/$kind/ticket.keep"
  printf -- '---\nid: x\nstatus: closed\n---\n# SECRET title\n\nSECRET body\n' > "$out/secret.md"
  rm "$wtf"; ln -s "$out/secret.md" "$wtf"
  [[ "$(tfield t-lv01 status title ticket_etag)" == '{"status": "open", "ticket_etag": null, "title": "t-lv01"}' ]] || fail "$label: a symlinked ticket.md must not be read through, got $(tfield t-lv01 status title ticket_etag)"
  rm "$wtf"; cp "$TMP/$kind/ticket.keep" "$wtf"
  mv "$wt/.tickets" "$wt/.tickets.real"; mkdir -p "$out/tix/t-lv01"
  printf -- '---\nid: t-lv01\nstatus: closed\n---\n# LEAK title\n\nLEAK body\n' > "$out/tix/t-lv01/ticket.md"; printf 'LEAKDOC\n' > "$out/tix/t-lv01/plan.md"
  ln -s "$out/tix" "$wt/.tickets"
  [[ "$(tfield t-lv01 status title)" == '{"status": "open", "title": "t-lv01"}' ]] || fail "$label: a symlinked .tickets must not be read through, got $(tfield t-lv01 status title)"
  [[ -z "$(curl -s "$base/api/doc/t-lv01/plan.md" | grep LEAKDOC || true)" ]] || fail "$label: a doc must not be read through a symlinked .tickets"
  code="$(post t-lv01/status '{"status":"closed"}')"
  [[ "$code" == 403 && "$(pj code)" == unsafe_path ]] || fail "$label: a write through a symlinked .tickets must be refused, got $code"
  rm "$wt/.tickets"; mv "$wt/.tickets.real" "$wt/.tickets"

  # 5c. Odd ticket.md shapes: refused or preserved byte for byte, never wiped or reinterpreted.
  printf -- '---\nstatus: in_progress\ntype: bug\n---' > "$wtf"              # no newline after the closing fence
  code="$(post t-lv01/body "{\"body\":\"hello\",\"base_hash\":\"$(sha "$wtf")\"}")"
  [[ "$code" == 409 && "$(pj code)" == bad_ticket && "$(cat "$wtf")" == $'---\nstatus: in_progress\ntype: bug\n---' ]] || fail "$label: a body save over an unparsable frontmatter must be 409 bad_ticket and write nothing, got $code"
  printf -- '---\r\nid: t-lv01\r\nstatus: in_progress\r\ntype: bug\r\n---\r\n# T\r\n\r\nold\r\n' > "$wtf"
  printf -- '---\r\nid: t-lv01\r\nstatus: open\r\ntype: bug\r\n---\r\n# T\r\n\r\nold\r\n' > "$TMP/$kind/crlf.want"
  code="$(post t-lv01/status '{"status":"open"}')"
  [[ "$code" == 200 ]] && cmp -s "$wtf" "$TMP/$kind/crlf.want" || fail "$label: a CRLF ticket.md must take a status edit with every other byte kept, got $code"
  printf -- '---\nid: t-lv01\nstatus: in_progress\n---\n# T\n\nbad \377\376 byte\n' > "$wtf"       # not valid UTF-8
  printf -- '---\nid: t-lv01\nstatus: open\n---\n# T\n\nbad \377\376 byte\n' > "$TMP/$kind/utf8.want"
  code="$(post t-lv01/status '{"status":"open"}')"
  [[ "$code" == 200 ]] && cmp -s "$wtf" "$TMP/$kind/utf8.want" || fail "$label: bytes that are not valid UTF-8 must survive a status edit unchanged, got $code"
  printf -- '---\nid: t-lv01\nstatus: open\n---\n# T\n' > "$wtf"
  code="$(post t-lv01/demo '{"demo":"false"}')"
  [[ "$code" == 200 && -z "$(grep '^demo:' "$wtf" || true)" ]] || fail "$label: demo \"false\" must not turn Demo on"
  # Lone surrogates are written as 3 bytes each, so they cannot slip a body past the 1 MiB cap.
  cp "$TMP/$kind/ticket.keep" "$wtf"; etag="$(sha "$wtf")"
  python3 -c 'import sys; sys.stdout.write("{\"body\":\"" + "\\ud800" * 1048576 + "\",\"base_hash\":\"" + sys.argv[1] + "\"}")' "$etag" > "$TMP/$kind/surr.json"
  code="$(curl -s -o "$TMP/$kind/post.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @"$TMP/$kind/surr.json" "$base/api/ticket/t-lv01/body")"
  [[ "$code" == 400 && "$(pj code)" == too_large && "$(sha "$wtf")" == "$etag" ]] || fail "$label: a body of lone surrogates over the cap must be 400 too_large, got $code"
  rm -f "$wt/.tickets/ACTIVE"
  cp "$TMP/$kind/ticket.keep" "$wtf"

  # 5d. tkt's close marker, the Description returned with the etag, ASCII-only whitespace, a cap on the trimmed text.
  cp "$TMP/$kind/ticket.keep" "$wtf"
  code="$(post t-lv01/status '{"status":"closed"}')"
  [[ "$code" == 200 && "$(grep -c '^closed: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9:]*Z$' "$wtf")" == 1 ]] || fail "$label: closing must add tkt's closed: marker once (the pre-commit hook blocks a closed ticket without it), got $code"
  [[ "$(pj body)" == *"board edit"* ]] || fail "$label: a status write must return the Description its etag describes, got $(cat "$TMP/$kind/post.json")"
  code="$(post t-lv01/status '{"status":"in_progress"}')"
  [[ "$code" == 200 && -z "$(grep '^closed:' "$wtf" || true)" ]] || fail "$label: reopening must remove the closed: marker, got $code"
  printf -- '---\nid: t-lv01\nstatus: closed\nclosed: 2020-01-01T00:00:00Z\n---\n# T\n' > "$wtf"
  post t-lv01/status '{"status":"in_progress"}' >/dev/null
  [[ -z "$(grep '^closed:' "$wtf" || true)" ]] || fail "$label: a stale closed: line must go when the ticket is reopened"
  code="$(post t-lv01/demo '{"demo":true}')"
  [[ "$code" == 200 && "$(pj body)" == "# T" ]] || fail "$label: a Demo write must return the Description too, got $(cat "$TMP/$kind/post.json")"
  printf -- '---\xc2\xa0\nstatus: open\n---\n# T\n' > "$wtf"                    # a non-breaking space is not whitespace to either server
  code="$(post t-lv01/status '{"status":"in_progress"}')"
  [[ "$code" == 409 && "$(pj code)" == bad_ticket ]] || fail "$label: a fence followed by U+00A0 must be refused identically in both servers, got $code"
  printf -- '---\nstatus: open\xc2\xa0\n---\n# T\n' > "$wtf"
  code="$(post t-lv01/status '{"status":"in_progress"}')"
  [[ "$code" == 200 ]] && grep -q '^status: in_progress$' "$wtf" || fail "$label: a status value followed by U+00A0 must be rewritten identically in both servers, got $code"
  printf -- '---\nid: t-lv01\nstatus: open\n---\n# T\n\nold\n' > "$wtf"; etag="$(sha "$wtf")"
  python3 -c 'import json,sys; print(json.dumps({"body": " " * ((1 << 20) + 1) + "kept", "base_hash": sys.argv[1]}))' "$etag" > "$TMP/$kind/pad.json"
  code="$(curl -s -o "$TMP/$kind/post.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @"$TMP/$kind/pad.json" "$base/api/ticket/t-lv01/body")"
  [[ "$code" == 200 ]] && grep -q '^kept$' "$wtf" || fail "$label: the cap is on the trimmed text (1 MiB of padding around a short body is fine), got $code"
  rm -f "$wt/.tickets/ACTIVE"
  cp "$TMP/$kind/ticket.keep" "$wtf"

  # 5d2. A ticket folder that is itself a link out of the worktree is not bound: nothing reaches what it points at.
  cp "$mainf" "$TMP/$kind/main.keep"
  mv "$wt/.tickets/t-lv01" "$wt/.tickets/t-lv01.real"; mkdir -p "$out/tdirvic"
  printf -- '---\nid: t-lv01\nstatus: open\n---\n# VICTIM\n' > "$out/tdirvic/ticket.md"; ln -s "$out/tdirvic" "$wt/.tickets/t-lv01"
  snap="$(sha "$out/tdirvic/ticket.md")"
  post t-lv01/status '{"status":"closed"}' >/dev/null; post t-lv01/body "{\"body\":\"x\",\"base_hash\":\"deadbeef\"}" >/dev/null
  [[ "$(sha "$out/tdirvic/ticket.md")" == "$snap" ]] || fail "$label: a symlinked ticket folder must never be written through"
  rm "$wt/.tickets/t-lv01"; mv "$wt/.tickets/t-lv01.real" "$wt/.tickets/t-lv01"; cp "$TMP/$kind/main.keep" "$mainf"
  main_before="$(sha "$mainf")"

  # 5e. ACTIVE follows tkt: closing releases it only when it names THIS ticket, never another's.
  cp "$TMP/$kind/ticket.keep" "$wtf"; printf 't-other\n' > "$wt/.tickets/ACTIVE"
  post t-lv01/status '{"status":"closed"}' >/dev/null
  [[ "$(tr -d '[:space:]' < "$wt/.tickets/ACTIVE")" == t-other ]] || fail "$label: closing a ticket must not clear an ACTIVE that names another ticket"
  post t-lv01/status '{"status":"in_progress"}' >/dev/null
  [[ "$(tr -d '[:space:]' < "$wt/.tickets/ACTIVE")" == t-lv01 ]] || fail "$label: starting a ticket must claim ACTIVE"
  rm -f "$wt/.tickets/ACTIVE"; cp "$TMP/$kind/ticket.keep" "$wtf"

  # 6a. Two board writes at once never lose a field: the write lock, not luck, keeps each read-modify-write whole.
  lost=0
  for i in $(seq 1 20); do
    printf -- '---\nid: t-lv01\nstatus: open\ntype: task\n---\n# T\n\nbody\n' > "$wtf"
    curl -s -o /dev/null -X POST -H 'Content-Type: application/json' --data-binary '{"status":"in_progress"}' "$base/api/ticket/t-lv01/status" &
    curl -s -o /dev/null -X POST -H 'Content-Type: application/json' --data-binary '{"demo":true}' "$base/api/ticket/t-lv01/demo" &
    wait
    if ! grep -q '^status: in_progress$' "$wtf" || ! grep -q '^demo: true$' "$wtf"; then lost=$((lost + 1)); fi
  done
  [[ "$lost" -eq 0 ]] || fail "$label: two simultaneous board writes lost a field in $lost of 20 rounds (the write lock is not held across read and rename)"
  rm -f "$wt/.tickets/ACTIVE"; cp "$TMP/$kind/ticket.keep" "$wtf"

  # 6. Concurrency: board writes racing a second writer (as tkt does) never tear the file or lose the id/status.
  ( for i in $(seq 1 40); do
      python3 - "$wtf" "$i" <<'PY'
import os, sys, tempfile
p, i = sys.argv[1], sys.argv[2]
try:
    t = open(p).read()
except OSError:
    sys.exit(0)
import re
t = re.sub(r'^eval_fail_count:.*$', 'eval_fail_count: ' + i, t, flags=re.M)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix='.tkt-')
os.write(fd, t.encode()); os.close(fd); os.replace(tmp, p)
PY
    done ) &
  local writer=$!
  for i in $(seq 1 20); do
    post t-lv01/status '{"status":"closed"}' >/dev/null; post t-lv01/status '{"status":"in_progress"}' >/dev/null
    post t-lv01/demo '{"demo":true}' >/dev/null; post t-lv01/demo '{"demo":false}' >/dev/null
  done
  wait "$writer" 2>/dev/null || true
  python3 - "$wtf" <<'PY' || fail "$label: the worktree ticket.md is torn or lost a field after concurrent writes"
import re, sys
t = open(sys.argv[1]).read()
m = re.match(r'---\n(.*?)\n---\n', t, re.S)
assert m, 'frontmatter lost'
fm = m.group(1)
assert len(re.findall(r'^id: t-lv01$', fm, re.M)) == 1, 'id'
assert len(re.findall(r'^status: (open|in_progress|closed)$', fm, re.M)) == 1, 'status'
assert len(re.findall(r'^demo:', fm, re.M)) <= 1, 'demo'
assert len(re.findall(r'^eval_fail_count:', fm, re.M)) == 1, 'eval_fail_count'
assert 'board edit' in t[m.end():], 'body'
PY
  [[ -z "$(ls -A "$wt/.tickets/t-lv01" | grep -F '.board-' || true)" ]] || fail "$label: a temp file was left behind"
  [[ "$(sha "$mainf")" == "$main_before" ]] || fail "$label: main's ticket.md changed during a bound session"
  echo "  $label: live ticket fields ok"
}

# Trigger paths: both body write sites in the client must send base_hash for a bound ticket.
writes="$(grep -n 'postWrite(`/api/ticket/${[a-zA-Z.]*}/body`' "$ROOT/tools/sprint-check-app/app.html" || true)"
[[ "$(grep -c . <<<"$writes")" -eq 2 ]] || fail "expected exactly 2 body write sites in app.html, got: $writes"
[[ -z "$(grep -v base_hash <<<"$writes")" ]] || fail "a body write site in app.html sends no base_hash: $(grep -v base_hash <<<"$writes")"

run_checks py server.py
if [[ -n "$GO_BIN" ]]; then
  run_checks go main.go
else
  echo "  main.go: go absent — Go half skipped"
fi
echo "sprint-check-live-ticket: ok"
