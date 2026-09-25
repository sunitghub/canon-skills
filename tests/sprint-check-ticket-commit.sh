#!/usr/bin/env bash
# sprint-check-ticket-commit (t-d254) — GET/POST /api/ticket-commit/<id> behave
# identically in server.py and main.go, each against its own fresh git repo:
# classification (required / recommended / optional / other_dirty), a commit of
# exactly the chosen eligible paths (unrelated staged work stays staged),
# rejection of forged or incomplete path lists with HEAD unchanged, blocked
# repo states, and a worktree created afterwards actually containing the ticket.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "sprint-check-ticket-commit: python3/curl/git absent — skipped"
  exit 0
fi

SERVER_PY="$ROOT/tools/sprint-check-app/server.py"
GO_BIN=""
PIDS=()
DIRS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  for d in "${DIRS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d" "$d-worktrees"; done
  [[ -n "$GO_BIN" ]] && rm -rf "$(dirname "$GO_BIN")"
  return 0
}
trap cleanup EXIT

if command -v go >/dev/null 2>&1; then
  GO_BIN="$(mktemp -d)/sprint-check-go-bin"
  (cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)
fi

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

# start_server <py|go> <repo> → prints the port once the server answers.
start_server() {
  local kind="$1" repo="$2" port
  port="$(free_port)"
  if [[ "$kind" == py ]]; then
    SPRINT_CHECK_ROOT="$repo" python3 "$SERVER_PY" "$port" >/dev/null 2>&1 &
  else
    SPRINT_CHECK_ROOT="$repo" "$GO_BIN" "$port" >/dev/null 2>&1 &
  fi
  PIDS+=("$!")
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/api/git" && break
    sleep 0.1
  done
  echo "$port"
}

new_repo() {
  local repo
  repo="$(mktemp -d)"
  DIRS+=("$repo")
  git -C "$repo" init -q -b master
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  echo a > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" commit -q -m init
  echo "$repo"
}

jget() { python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1])[sys.argv[2]]))" "$1" "$2"; }

post_commit() { # port id json-paths → "<http-code> <body>"
  local out code
  out="$(curl -s -w $'\n%{http_code}' -X POST "http://127.0.0.1:$1/api/ticket-commit/$2" \
    -H 'Content-Type: application/json' -d "{\"paths\": $3}")"
  code="${out##*$'\n'}"
  echo "$code ${out%$'\n'*}"
}

run_checks() {
  local kind="$1" label="$2" repo port head before plan res code
  repo="$(new_repo)"
  # Untracked ticket (incl. a hostile-but-legal filename), a runtime log, the
  # canon-owned ignore file, another ticket, and an unrelated STAGED file.
  mkdir -p "$repo/.tickets/t-ab12/visuals" "$repo/.tickets/t-zz99"
  printf -- '---\nstatus: open\n---\n# x\n' > "$repo/.tickets/t-ab12/ticket.md"
  echo plan > "$repo/.tickets/t-ab12/plan.md"
  echo png > "$repo/.tickets/t-ab12/visuals/shot.png"
  echo odd > "$repo/.tickets/t-ab12/a\"b <img src=x>.md"
  echo log > "$repo/.tickets/t-ab12/cockpit-sessions.md"
  printf '.cockpit-*\nACTIVE\n' > "$repo/.tickets/.gitignore"
  echo other > "$repo/.tickets/t-zz99/ticket.md"
  echo staged > "$repo/staged.txt"
  git -C "$repo" add staged.txt
  port="$(start_server "$kind" "$repo")"

  plan="$(curl -s "http://127.0.0.1:$port/api/ticket-commit/t-ab12")"
  python3 - "$plan" "$label" <<'EOF'
import json, sys
d, label = json.loads(sys.argv[1]), sys.argv[2]
exp = {
  'required': ['.tickets/t-ab12/a"b <img src=x>.md', '.tickets/t-ab12/plan.md',
               '.tickets/t-ab12/ticket.md', '.tickets/t-ab12/visuals/shot.png'],
  'recommended': ['.tickets/.gitignore'],
  'optional': ['.tickets/t-ab12/cockpit-sessions.md'],
  'other_dirty': ['.tickets/t-zz99/ticket.md', 'staged.txt'],
  'other_dirty_count': 2, 'message': 'chore: add ticket t-ab12', 'blocked': '',
}
assert d == exp, f'{label}: plan mismatch:\n{json.dumps(d, indent=1)}'
EOF

  # Malformed id → 400. A traversal-shaped id never reaches the handler: Go's
  # ServeMux cleans `..` paths with a 301 before routing, Python 400s — either
  # way it must not succeed.
  for bad in t-AB12 t-ab1 t-ab123 x; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/ticket-commit/$bad")"
    [[ "$code" == 400 ]] || fail "$label: malformed ticket id '$bad' must 400, got $code"
  done
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/ticket-commit/..%2fx")"
  [[ "$code" != 200 ]] || fail "$label: traversal-shaped ticket id must not succeed"

  head="$(git -C "$repo" rev-parse HEAD)"
  local req='[".tickets/t-ab12/a\"b <img src=x>.md", ".tickets/t-ab12/plan.md", ".tickets/t-ab12/ticket.md", ".tickets/t-ab12/visuals/shot.png"'
  # Forged paths (traversal, another ticket, source file) → 400, nothing committed.
  for forged in '"../x"' '".tickets/t-zz99/ticket.md"' '"staged.txt"'; do
    res="$(post_commit "$port" t-ab12 "$req, $forged]")"
    [[ "${res%% *}" == 400 ]] || fail "$label: forged path $forged must 400, got: $res"
    [[ "$(git -C "$repo" rev-parse HEAD)" == "$head" ]] || fail "$label: forged path $forged created a commit"
  done
  # Missing a required file → 400.
  res="$(post_commit "$port" t-ab12 '[".tickets/t-ab12/ticket.md"]')"
  [[ "${res%% *}" == 400 ]] || fail "$label: missing required files must 400, got: $res"
  # Not a list → 400.
  res="$(post_commit "$port" t-ab12 '"x"')"
  [[ "${res%% *}" == 400 ]] || fail "$label: non-list paths must 400, got: $res"
  [[ "$(git -C "$repo" rev-parse HEAD)" == "$head" ]] || fail "$label: a rejected request created a commit"

  # Valid: required + recommended. Commits exactly those; staged.txt stays staged.
  res="$(post_commit "$port" t-ab12 "$req, \".tickets/.gitignore\"]")"
  [[ "${res%% *}" == 200 ]] || fail "$label: valid commit must 200, got: $res"
  local committed
  committed="$(git -C "$repo" show -z --name-only --format= HEAD | tr '\0' '\n' | sed '/^$/d' | sort)"
  [[ "$committed" == "$(printf '%s\n' '.tickets/.gitignore' '.tickets/t-ab12/a"b <img src=x>.md' '.tickets/t-ab12/plan.md' '.tickets/t-ab12/ticket.md' '.tickets/t-ab12/visuals/shot.png' | sort)" ]] \
    || fail "$label: committed set wrong:\n$committed"
  [[ "$(git -C "$repo" log -1 --format=%s)" == "chore: add ticket t-ab12" ]] || fail "$label: wrong commit message"
  [[ "$(git -C "$repo" diff --cached --name-only)" == "staged.txt" ]] || fail "$label: unrelated staged work was swept in or unstaged"
  git -C "$repo" status --porcelain -- .tickets/t-ab12/cockpit-sessions.md | grep -q '^??' || fail "$label: optional runtime log was committed though unchecked"

  # Nothing required left → POST 409; a modified required file → "update" message.
  res="$(post_commit "$port" t-ab12 '[".tickets/t-ab12/cockpit-sessions.md"]')"
  [[ "${res%% *}" == 409 ]] || fail "$label: commit with no uncommitted required files must 409, got: $res"
  echo more >> "$repo/.tickets/t-ab12/plan.md"
  plan="$(curl -s "http://127.0.0.1:$port/api/ticket-commit/t-ab12")"
  [[ "$(jget "$plan" message)" == '"chore: update ticket t-ab12"' ]] || fail "$label: modified-only message wrong: $plan"
  git -C "$repo" checkout -q -- .tickets/t-ab12/plan.md

  # The point of it all: a worktree created now contains the ticket.
  local wt
  wt="$(curl -s -X POST "http://127.0.0.1:$port/api/worktrees" -H 'Content-Type: application/json' -d '{"branch":"sprint/t-ab12"}')"
  wt="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['ok'], d; print(d['path'])" "$wt")"
  [[ -f "$wt/.tickets/t-ab12/ticket.md" ]] || fail "$label: new worktree lacks the committed ticket"

  # Blocked states → plan.blocked set, POST 409, HEAD unchanged.
  echo new > "$repo/.tickets/t-ab12/new.md"
  head="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" rev-parse HEAD > "$repo/.git/MERGE_HEAD"
  plan="$(curl -s "http://127.0.0.1:$port/api/ticket-commit/t-ab12")"
  [[ "$(jget "$plan" blocked)" == '"a merge, rebase or cherry-pick is in progress"' ]] || fail "$label: MERGE_HEAD not blocked: $plan"
  res="$(post_commit "$port" t-ab12 '[".tickets/t-ab12/new.md"]')"
  [[ "${res%% *}" == 409 ]] || fail "$label: commit during a merge must 409, got: $res"
  rm "$repo/.git/MERGE_HEAD"
  git -C "$repo" checkout -q --detach
  plan="$(curl -s "http://127.0.0.1:$port/api/ticket-commit/t-ab12")"
  [[ "$(jget "$plan" blocked)" == '"HEAD is detached"' ]] || fail "$label: detached HEAD not blocked: $plan"
  res="$(post_commit "$port" t-ab12 '[".tickets/t-ab12/new.md"]')"
  [[ "${res%% *}" == 409 ]] || fail "$label: commit on detached HEAD must 409, got: $res"
  git -C "$repo" checkout -q master
  [[ "$(git -C "$repo" rev-parse HEAD)" == "$head" ]] || fail "$label: a blocked request created a commit"

  # .tickets/ gitignored (fresh repo) → blocked, empty lists.
  local repo2 port2
  repo2="$(new_repo)"
  mkdir -p "$repo2/.tickets/t-ab12" && echo x > "$repo2/.tickets/t-ab12/ticket.md"
  echo '.tickets/' > "$repo2/.gitignore"
  port2="$(start_server "$kind" "$repo2")"
  plan="$(curl -s "http://127.0.0.1:$port2/api/ticket-commit/t-ab12")"
  [[ "$(jget "$plan" blocked)" == '".tickets/ is gitignored"' && "$(jget "$plan" required)" == '[]' ]] || fail "$label: ignored .tickets not blocked: $plan"

  echo "  $label: ticket-commit ok"
}

run_checks py server.py
if [[ -n "$GO_BIN" ]]; then
  run_checks go main.go
else
  echo "  main.go: go absent — Go half skipped"
fi
echo "sprint-check-ticket-commit: ok"
