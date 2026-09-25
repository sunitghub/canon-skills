#!/usr/bin/env bash
# sprint-check-live-docs (t-e78b) — for a ticket bound to a worktree, the board
# reads its sprint docs from that worktree's copy and refuses board writes to
# them, identically in server.py and main.go. The binding comes from the
# agent-writable .cockpit-cwd lock (or an in-progress worktree copy), so a lock
# naming anything but a registered worktree of this repo must be ignored.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "sprint-check-live-docs: python3/curl/git absent — skipped"
  exit 0
fi

SERVER_PY="$ROOT/tools/sprint-check-app/server.py"
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

run_checks() {
  local kind="$1" label="$2" repo wt port base
  repo="$TMP/$kind/proj"; wt="$TMP/$kind/proj-worktrees/sprint-t-lv01"
  mkdir -p "$repo/.tickets/t-lv01" "$repo/.tickets/t-lv02" "$TMP/$kind/outside/.tickets/t-lv01"
  git -C "$repo" init -q -b master
  git -C "$repo" config user.email t@t && git -C "$repo" config user.name t
  fm t-lv01 open > "$repo/.tickets/t-lv01/ticket.md"
  printf '# Acceptance\n\n## Criteria\n\n- [ ]\n\n## Test Plan\n\n- [ ]\n' > "$repo/.tickets/t-lv01/acceptance.md"
  fm t-lv02 open > "$repo/.tickets/t-lv02/ticket.md"
  git -C "$repo" add -A && git -C "$repo" commit -q -m init
  git -C "$repo" worktree add -q -b sprint/t-lv01 "$wt"
  # The sprint's live, uncommitted edits in the worktree.
  printf '# Acceptance\n\n## Criteria\n\n- [ ] live criterion\n\n## Test Plan\n\n- [ ] live test\n' > "$wt/.tickets/t-lv01/acceptance.md"
  printf '# Plan\n\n## Approach\n\nlive approach\n' > "$wt/.tickets/t-lv01/plan.md"
  fm t-lv01 in_progress > "$wt/.tickets/t-lv01/ticket.md"
  # A decoy folder shaped like a worktree but NOT registered with git.
  fm t-lv01 in_progress > "$TMP/$kind/outside/.tickets/t-lv01/ticket.md"
  printf 'decoy\n' > "$TMP/$kind/outside/.tickets/t-lv01/plan.md"

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

  tfield() { curl -s "$base/api/tickets" | python3 -c 'import json,sys; t={x["id"]:x for x in json.load(sys.stdin)}[sys.argv[1]]; print(json.dumps({k:t.get(k) for k in ("docs_from","acceptance_has_items","plan_has_approach")}, sort_keys=True))' "$1"; }
  getdoc() { curl -s "$base/api/doc/t-lv01/$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("content","").strip())' 2>/dev/null || echo 404; }

  # 1. In-progress worktree copy, no lock → bound via divergence.
  [[ "$(tfield t-lv01)" == '{"acceptance_has_items": true, "docs_from": {"branch": "sprint/t-lv01"}, "plan_has_approach": true}' ]] \
    || fail "$label: in-progress copy should overlay live docs, got $(tfield t-lv01)"
  [[ "$(tfield t-lv02)" == '{"acceptance_has_items": null, "docs_from": null, "plan_has_approach": null}' ]] \
    || fail "$label: unbound ticket must stay main's, got $(tfield t-lv02)"

  # 2. Lock to the worktree → bound; GET reads the live copy; POST is refused, both files unchanged.
  echo "$wt" > "$repo/.tickets/t-lv01/.cockpit-cwd"
  getdoc plan.md | grep -q 'live approach' || fail "$label: GET plan.md should return the worktree copy"
  local main_before wt_before code
  main_before="$(shasum "$repo/.tickets/t-lv01/acceptance.md")"; wt_before="$(shasum "$wt/.tickets/t-lv01/acceptance.md")"
  code="$(curl -s -o "$TMP/$kind/post.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"content":"board edit"}' "$base/api/doc/t-lv01/acceptance.md")"
  [[ "$code" == 409 ]] || fail "$label: POST to a bound ticket's doc must 409, got $code"
  grep -q 'live in worktree sprint/t-lv01' "$TMP/$kind/post.json" || fail "$label: 409 must name the branch: $(cat "$TMP/$kind/post.json")"
  [[ "$(shasum "$repo/.tickets/t-lv01/acceptance.md")" == "$main_before" && "$(shasum "$wt/.tickets/t-lv01/acceptance.md")" == "$wt_before" ]] \
    || fail "$label: a refused POST changed a file"
  # Unbound ticket: writes still work.
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"content":"plan for lv02"}' "$base/api/doc/t-lv02/plan.md")"
  [[ "$code" == 200 && -f "$repo/.tickets/t-lv02/plan.md" ]] || fail "$label: unbound ticket doc write must still work ($code)"

  # 3. A lock naming anything but a registered worktree is ignored (lock is agent-writable).
  fm t-lv01 open > "$wt/.tickets/t-lv01/ticket.md"      # drop the in-progress fallback
  for bogus in /etc "$TMP/$kind/outside" "$repo"; do
    echo "$bogus" > "$repo/.tickets/t-lv01/.cockpit-cwd"
    [[ "$(tfield t-lv01)" == '{"acceptance_has_items": false, "docs_from": null, "plan_has_approach": null}' ]] \
      || fail "$label: lock '$bogus' must not overlay, got $(tfield t-lv01)"
    [[ "$(getdoc plan.md)" == 404 || "$(getdoc plan.md)" == "" ]] || fail "$label: lock '$bogus' let GET read $(getdoc plan.md)"
  done

  # 4. Worktree removed → main again.
  echo "$wt" > "$repo/.tickets/t-lv01/.cockpit-cwd"
  git -C "$repo" worktree remove --force "$wt"
  [[ "$(tfield t-lv01)" == '{"acceptance_has_items": false, "docs_from": null, "plan_has_approach": null}' ]] \
    || fail "$label: removed worktree must fall back to main, got $(tfield t-lv01)"
  echo "  $label: live docs ok"
}

run_checks py server.py
if [[ -n "$GO_BIN" ]]; then
  run_checks go main.go
else
  echo "  main.go: go absent — Go half skipped"
fi
echo "sprint-check-live-docs: ok"
