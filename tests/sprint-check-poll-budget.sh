#!/usr/bin/env bash
# sprint-check-poll-budget (t-c21a) — what the board's polls cost per request. The board polls /api/tickets, /api/handoff
# and /api/git every 8 s per open tab, so a per-request process or a full reply on an unchanged poll is paid on every tick.
# Guard (the default): with git/gh/tkt on PATH replaced by counting shims, an unbound tree's /api/tickets starts no process,
# /api/git starts one at an unchanged HEAD, and each of the three answers a matching If-None-Match with an empty 304 and a
# change with a new ETag. A ticket bound to a worktree still gets its live docs (the positive control: the shims count).
# t-761b: /api/remote-agents (the Agents list's Cloud group, polled by the Cockpit shell) starts no process when nothing is out on GitHub,
# one background `tkt github-status` per ticket out on GitHub on a cold poll (the poll answers at once, never waits for GitHub) and none within the board's 30 s cache, and answers an empty 304.
#   --measure <root>   print the docs table (docs/sprint-check.md "Polling budget") for the project at <root>; read-only GETs

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "sprint-check-poll-budget: python3/curl/git absent — skipped"
  exit 0
fi

MEASURE=""
if [[ "${1:-}" == "--measure" ]]; then
  MEASURE="$(cd "${2:?usage: sprint-check-poll-budget.sh [--measure <root>]}" && pwd)"
fi

PIDS=()
TMP="$(mktemp -d)"
cleanup() {
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

GO_BIN="$(build_board "$TMP/bin")"

# Counting shims: each run appends one line to $CALLS, then runs the real tool.
CALLS="$TMP/calls.log"
mkdir -p "$TMP/shim"
for tool in git gh tkt; do
  real="$(command -v "$tool" || true)"
  [[ "$tool" == tkt ]] && real="$ROOT/tools/tkt"
  [[ -n "$real" ]] || continue
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\nexec "%s" "$@"\n' "$tool" "$CALLS" "$real" > "$TMP/shim/$tool"
  chmod +x "$TMP/shim/$tool"
done

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

# start_board <root> [real-state]: the board on <root> with the shims first on PATH; sets BASE. Hermetic state unless
# real-state is given (--measure reads the running Cockpit's daemon address; GETs only, and the daemon is never launched).
start_board() {
  local port; port="$(free_port)"
  if [[ -n "${2:-}" ]]; then
    PATH="$TMP/shim:$PATH" TKT_BIN="$TMP/shim/tkt" SPRINT_CHECK_ROOT="$1" COCKPIT_DAEMON_BIN=/usr/bin/false SPRINT_CHECK_NO_BROWSER=1 \
      "$GO_BIN" "$port" >/dev/null 2>&1 &
  else
    PATH="$TMP/shim:$PATH" TKT_BIN="$TMP/shim/tkt" SPRINT_CHECK_ROOT="$1" CANON_HOME="$TMP/canon-$port" COCKPIT_STATE_DIR="$TMP/ck-$port" \
      COCKPIT_DAEMON_BIN=/usr/bin/false SPRINT_CHECK_DIVERGENCE_TTL=600 SPRINT_CHECK_NO_BROWSER=1 "$GO_BIN" "$port" >/dev/null 2>&1 &
  fi
  PIDS+=("$!"); disown "$!" 2>/dev/null || true
  BASE="http://127.0.0.1:$port"
  for _ in $(seq 1 100); do curl -s -o /dev/null "$BASE/api/version" && return 0; sleep 0.1; done
  fail "sprint-check-poll-budget: the board did not start on $1"
}

# procs <path> [n]: the processes one request starts, averaged over n requests after a warm-up (the divergence scan and the
# HEAD cache fill on the first).
procs() {
  local n="${2:-3}"
  curl -s -o /dev/null "$BASE$1"
  : > "$CALLS"
  for _ in $(seq 1 "$n"); do curl -s -o /dev/null "$BASE$1"; done
  python3 -c 'import sys; print(round(sum(1 for _ in open(sys.argv[1])) / int(sys.argv[2]), 1))' "$CALLS" "$n"
}
etag() { curl -s -D - -o /dev/null "$BASE$1" | tr -d '\r' | sed -n 's/^[Ee][Tt][Aa][Gg]: //p'; }
cond() { curl -s -o "$TMP/cond.body" -w '%{http_code} %{size_download}' -H "If-None-Match: $2" "$BASE$1"; }

if [[ -n "$MEASURE" ]]; then
  start_board "$MEASURE" real
  echo "| Poll | Median | p95 | Processes per request | Reply | Unchanged poll |"
  echo "|---|---|---|---|---|---|"
  for ep in '/api/tickets?all=1' /api/handoff /api/git /api/cockpit /api/v1/sessions /api/cockpit-interrupted /api/project-stats /api/remote-agents; do
    p="$(procs "$ep" 15)"
    times=""; for _ in $(seq 1 15); do times+="$(curl -s -o /dev/null -w '%{time_total}' "$BASE$ep") "; done
    size="$(curl -s -o /dev/null -w '%{size_download}' "$BASE$ep")"
    tag="$(etag "$ep")"
    if [[ -n "$tag" ]]; then unchanged="$(cond "$ep" "$tag")"; unchanged="${unchanged#* } B (304)"; else unchanged="full reply"; fi
    python3 -c '
import sys
t = sorted(float(x) * 1000 for x in sys.argv[2].split())
def fmt(b): b = int(b); return f"{b / 1048576:.2f} MB" if b >= 1048576 else f"{b / 1024:.1f} KB" if b >= 1024 else f"{b} B"
print(f"| `{sys.argv[1]}` | {t[len(t) // 2]:.0f} ms | {t[min(len(t) - 1, int(len(t) * 0.95))]:.0f} ms | {sys.argv[3]} | {fmt(sys.argv[4])} | {sys.argv[5]} |")' \
      "$ep" "$times" "$p" "$size" "$unchanged"
  done
  exit 0
fi

fm() { printf -- '---\nid: %s\nstatus: %s\ntype: task\npriority: 2\n---\n# %s\n' "$1" "$2" "$1"; }
repo="$TMP/proj"
mkdir -p "$repo/.tickets/t-pb01" "$repo/.tickets/t-pb02" "$repo/.tickets/t-pb03"
git -C "$repo" init -q -b master
git -C "$repo" config user.email t@t && git -C "$repo" config user.name t
fm t-pb01 open > "$repo/.tickets/t-pb01/ticket.md"
fm t-pb02 in_progress > "$repo/.tickets/t-pb02/ticket.md"
fm t-pb03 closed > "$repo/.tickets/t-pb03/ticket.md"
printf '# Handoff\n' > "$repo/HANDOFF.md"
git -C "$repo" add -A && git -C "$repo" commit -q -m init
start_board "$repo"

# 1. No worktree: /api/tickets starts nothing, /api/git one process, /api/handoff nothing.
[[ "$(procs '/api/tickets?all=1')" == 0.0 ]] || fail "poll-budget: /api/tickets on a tree with no worktree started $(procs '/api/tickets?all=1') processes per request: $(sort "$CALLS" | uniq -c)"
[[ "$(procs /api/git)" == 1.0 ]] || fail "poll-budget: /api/git at an unchanged HEAD started $(procs /api/git) processes per request, want 1: $(sort "$CALLS" | uniq -c)"
[[ "$(procs /api/handoff)" == 0.0 ]] || fail "poll-budget: /api/handoff started a process"

# 2. Each poll: an empty 304 on a matching If-None-Match, a new ETag after a change.
changed() { # changed <path> <what> <command…>: run the change, then the old ETag must miss
  local ep="$1" what="$2" old new; shift 2
  old="$(etag "$ep")"
  [[ -n "$old" ]] || fail "poll-budget: $ep sent no ETag"
  [[ "$(cond "$ep" "$old")" == "304 0" ]] || fail "poll-budget: $ep with its own ETag did not answer an empty 304: $(cond "$ep" "$old")"
  "$@"
  new="$(etag "$ep")"
  [[ "$new" != "$old" ]] || fail "poll-budget: $ep kept its ETag after $what"
  [[ "$(cond "$ep" "$old")" == 200* ]] || fail "poll-budget: $ep answered the old ETag with $(cond "$ep" "$old") after $what"
}
changed '/api/tickets?all=1' "a ticket edit" sh -c "printf -- '---\nid: t-pb01\nstatus: in_progress\ntype: task\npriority: 2\n---\n# t-pb01 edited\n' > '$repo/.tickets/t-pb01/ticket.md'"
changed /api/handoff "a HANDOFF edit" sh -c "printf '# Handoff\n\nmore\n' > '$repo/HANDOFF.md'"
changed /api/git "an unstaged edit" sh -c "printf 'x\n' >> '$repo/.tickets/t-pb03/ticket.md'"   # a file not yet modified: modified 2 -> 3
changed /api/git "a commit" git -C "$repo" commit -q -am second
curl -s "$BASE/api/git" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["log"][0]["message"] == "second" and d["total_commits"] == 2 and d["modified"] == 0 else 1)' \
  || fail "poll-budget: /api/git after the commit: $(curl -s "$BASE/api/git")"

# 3. A linked worktree with no ticket bound to it: still no process.
wt="$TMP/proj-worktrees/sprint-t-pb02"
git -C "$repo" worktree add -q -b sprint/t-pb02 "$wt"
[[ "$(procs '/api/tickets?all=1')" == 0.0 ]] || fail "poll-budget: /api/tickets with an unbound worktree started processes: $(sort "$CALLS" | uniq -c)"

# 4. Positive control: bound to it, the ticket's live docs come from the worktree, which takes git (the shims see it).
fm t-pb02 in_progress > "$wt/.tickets/t-pb02/ticket.md"; printf '\nlive text\n' >> "$wt/.tickets/t-pb02/ticket.md"
echo "$wt" > "$repo/.tickets/t-pb02/.cockpit-cwd"
[[ "$(procs '/api/tickets?all=1')" != 0.0 ]] || fail "poll-budget: a bound ticket's poll ran no git: the shims are not counting"
curl -s "$BASE/api/tickets" | python3 -c 'import json,sys; t={x["id"]:x for x in json.load(sys.stdin)}["t-pb02"]; sys.exit(0 if (t.get("docs_from") or {}).get("branch") == "sprint/t-pb02" and "live text" in t["body"] else 1)' \
  || fail "poll-budget: the bound ticket lost its live docs"

# 5. t-761b: /api/remote-agents. Nothing out on GitHub: no process, an ETag, an empty 304.
[[ "$(procs /api/remote-agents)" == 0.0 ]] || fail "poll-budget: /api/remote-agents with nothing out on GitHub started processes per request: $(sort "$CALLS" | uniq -c)"
tag="$(etag /api/remote-agents)"; [[ -n "$tag" ]] || fail "poll-budget: /api/remote-agents sent no ETag"
[[ "$(cond /api/remote-agents "$tag")" == "304 0" ]] || fail "poll-budget: an unchanged /api/remote-agents did not answer an empty 304: $(cond /api/remote-agents "$tag")"
# Two tickets out on GitHub: the first poll runs one tkt github-status each (read together), a poll inside the 30 s cache runs none.
for n in 1 2; do
  mkdir -p "$repo/.tickets/t-pc0$n"
  printf -- '---\nid: t-pc0%s\nstatus: in_progress\ntype: task\npriority: 2\nruns: github\ngithub: acme/app#%s\n---\n# cloud %s\n' "$n" "$n" "$n" > "$repo/.tickets/t-pc0$n/ticket.md"
done
: > "$CALLS"; curl -s -o "$TMP/ra.json" "$BASE/api/remote-agents"
for _ in $(seq 1 100); do [[ "$(grep -c '^tkt github-status' "$CALLS")" -ge 2 ]] && break; sleep 0.1; done   # the statuses load in the background; the poll itself answers at once
for _ in $(seq 1 150); do curl -s -o "$TMP/ra.json" "$BASE/api/remote-agents"; grep -q '"pending":true' "$TMP/ra.json" || break; sleep 0.2; done   # until both statuses landed
[[ "$(grep -c '^tkt github-status' "$CALLS")" == 2 ]] || fail "poll-budget: the first /api/remote-agents poll ran $(grep -c '^tkt github-status' "$CALLS") tkt github-status, want 2 (one per ticket out on GitHub): $(sort "$CALLS" | uniq -c)"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["rows"]; sys.exit(0 if [x["id"] for x in r]==["t-pc01","t-pc02"] else 1)' "$TMP/ra.json" \
  || fail "poll-budget: /api/remote-agents rows: $(cat "$TMP/ra.json")"
: > "$CALLS"; curl -s -o /dev/null "$BASE/api/remote-agents"
[[ ! -s "$CALLS" ]] || fail "poll-budget: a second /api/remote-agents poll inside the 30 s cache started processes: $(sort "$CALLS" | uniq -c)"
# With rows, an unchanged poll is still an empty 304: the body carries the newest activity as a time, not an age that ticks every second.
tag="$(etag /api/remote-agents)"; sleep 1.3
[[ "$(cond /api/remote-agents "$tag")" == "304 0" ]] || fail "poll-budget: /api/remote-agents with rows did not answer an empty 304 a second later (does a row carry an age that changes each second?): $(cond /api/remote-agents "$tag")"

echo "sprint-check-poll-budget: ok"
