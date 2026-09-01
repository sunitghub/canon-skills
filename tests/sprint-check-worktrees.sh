#!/usr/bin/env bash
# sprint-check-worktrees (t-cd06) — /api/worktrees (list + create) behaves
# identically in server.py and main.go: lists `git worktree list --porcelain`
# verbatim, creates a sibling `<repo>-worktrees/<branch>` checkout, falls back
# to a plain checkout when the branch already exists, and rejects a malformed
# branch name with 400 before any `git worktree add` runs. Also covers the
# t-cd06 amendment's advisory `/api/worktree-lock/<id>` (locked/cwd/main_dirty).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "sprint-check-worktrees: python3/curl/git absent — skipped"
  exit 0
fi

SERVER_PY="$ROOT/tools/sprint-check-app/server.py"
GO_BIN=""
PY_PID=""; GO_PID=""
cleanup() {
  [[ -n "$PY_PID" ]] && kill "$PY_PID" 2>/dev/null || true
  [[ -n "$GO_PID" ]] && kill "$GO_PID" 2>/dev/null || true
  [[ -n "$GO_BIN" ]] && rm -rf "$(dirname "$GO_BIN")"
  rm -rf "$WORK" "$WORK-worktrees"
}
trap cleanup EXIT

WORK="$(mktemp -d)"
build_tickets_fixture "$WORK"
git -C "$WORK" init -q
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name test
cat > "$WORK/.worktreeinclude" <<'EOF'
.env
config/secrets.json
EOF
mkdir -p "$WORK/config"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m init
# Gitignored fixtures for the .worktreeinclude test below — created AFTER the
# commit so they stay untracked, matching real .env/.env.local usage.
cat > "$WORK/.gitignore" <<'EOF'
.env
config/secrets.json
config/other.json
EOF
echo 'SECRET=fixture' > "$WORK/.env"
echo '{"k":"v"}' > "$WORK/config/secrets.json"
# Gitignored but matches no .worktreeinclude pattern — must NOT be copied,
# proving the match is selective, not "copy every ignored file."
echo 'not matched by any pattern' > "$WORK/config/other.json"
git -C "$WORK" add .gitignore
git -C "$WORK" commit -q -m gitignore

if command -v go >/dev/null 2>&1; then
  GO_BIN="$(mktemp -d)/sprint-check-go-bin"
  (cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)
fi

PY_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
SPRINT_CHECK_ROOT="$WORK" python3 "$SERVER_PY" "$PY_PORT" >/dev/null 2>&1 &
PY_PID=$!
disown "$PY_PID" 2>/dev/null || true

for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PY_PORT/api/git" && break
  sleep 0.1
done

run_checks() {
  local port="$1" label="$2"

  # list_worktrees: main checkout only, is_main true.
  local list_json main_count
  list_json="$(curl -s "http://127.0.0.1:$port/api/worktrees")"
  main_count="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(sum(1 for e in d if e.get('is_main')))" "$list_json")"
  [[ "$main_count" == "1" ]] || fail "$label: expected exactly one is_main worktree, got: $list_json"

  # t-e5ff: with .tickets/ NOT gitignored (fixture default), every worktree can
  # see tickets -> tickets_visible is true on every entry.
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert all(e.get('tickets_visible') is True for e in d), d" "$list_json"

  # invalid branch name -> 400, no worktree created.
  local bad_code
  bad_code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/api/worktrees" \
    -H 'Content-Type: application/json' -d '{"branch":"; rm -rf /"}')"
  [[ "$bad_code" == "400" ]] || fail "$label: malformed branch name must 400, got $bad_code"
  [[ ! -d "$WORK-worktrees/; rm -rf /" ]] || fail "$label: a rejected branch name still created a worktree dir"

  # valid branch -> sibling worktree created, appears in the list.
  local create_json created_path
  create_json="$(curl -s -X POST "http://127.0.0.1:$port/api/worktrees" \
    -H 'Content-Type: application/json' -d '{"branch":"feat/auth-tokens"}')"
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['ok'] is True, d" "$create_json"
  created_path="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['path'])" "$create_json")"
  [[ -d "$created_path" ]] || fail "$label: created worktree path does not exist on disk: $created_path"
  [[ "$(cd "$created_path" && pwd -P)" == "$(cd "$WORK-worktrees" && pwd -P)/feat-auth-tokens" ]] || \
    fail "$label: expected sibling path $WORK-worktrees/feat-auth-tokens, got $created_path"

  list_json="$(curl -s "http://127.0.0.1:$port/api/worktrees")"
  python3 -c "
import json, sys
entries = json.loads(sys.argv[1])
branches = {e.get('branch') for e in entries}
assert 'feat/auth-tokens' in branches, entries
" "$list_json"

  # branch already exists (but no worktree checked out yet) -> fallback to a
  # plain checkout (no -b), per the ticket's resolved design.
  git -C "$WORK" branch existing-branch >/dev/null 2>&1 || true
  local fallback_json fallback_path
  fallback_json="$(curl -s -X POST "http://127.0.0.1:$port/api/worktrees" \
    -H 'Content-Type: application/json' -d '{"branch":"existing-branch"}')"
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['ok'] is True, d" "$fallback_json"
  fallback_path="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['path'])" "$fallback_json")"
  [[ -d "$fallback_path" ]] || fail "$label: branch-exists fallback worktree not created on disk: $fallback_path"
  git -C "$WORK" worktree remove -f "$fallback_path" >/dev/null 2>&1 || true
  git -C "$WORK" branch -D existing-branch >/dev/null 2>&1 || true
  git -C "$WORK" worktree prune >/dev/null 2>&1 || true

  # .worktreeinclude: gitignored files matching a pattern are copied into the
  # fresh worktree (a worktree checkout never carries untracked/gitignored
  # content on its own); a gitignored file matching NO pattern is not.
  local wti_json wti_path
  wti_json="$(curl -s -X POST "http://127.0.0.1:$port/api/worktrees" \
    -H 'Content-Type: application/json' -d '{"branch":"feat/wti-test"}')"
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['ok'] is True, d" "$wti_json"
  wti_path="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['path'])" "$wti_json")"
  [[ -f "$wti_path/.env" ]] || fail "$label: .worktreeinclude did not copy .env into the new worktree"
  [[ "$(cat "$wti_path/.env")" == "SECRET=fixture" ]] || fail "$label: copied .env has wrong content"
  [[ -f "$wti_path/config/secrets.json" ]] || fail "$label: .worktreeinclude did not copy config/secrets.json"
  [[ ! -f "$wti_path/config/other.json" ]] || fail "$label: a gitignored file matching no pattern was copied anyway"
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
copied = set(d.get('worktreeinclude_copied') or [])
assert copied == {'.env', 'config/secrets.json'}, copied
" "$wti_json"
  git -C "$WORK" worktree remove -f "$wti_path" >/dev/null 2>&1 || true
  git -C "$WORK" branch -D feat/wti-test >/dev/null 2>&1 || true
  git -C "$WORK" worktree prune >/dev/null 2>&1 || true

  # same branch again -> path-exists failure (ok:false), not a 500/crash.
  local dup_json
  dup_json="$(curl -s -X POST "http://127.0.0.1:$port/api/worktrees" \
    -H 'Content-Type: application/json' -d '{"branch":"feat/auth-tokens"}')"
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['ok'] is False, d" "$dup_json"

  # clean up so the two backends (Python then Go) start from the same fixture state.
  git -C "$WORK" worktree remove -f "$created_path" >/dev/null 2>&1 || true
  git -C "$WORK" worktree prune >/dev/null 2>&1 || true

  # /api/worktree-lock/<id>: unlocked (no .cockpit-cwd) reports locked:false,
  # cwd:null, and main_dirty reflects the real working tree state.
  mkdir -p "$WORK/.tickets/t-lok1"
  local lock_json
  lock_json="$(curl -s "http://127.0.0.1:$port/api/worktree-lock/t-lok1")"
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert d == {'locked': False, 'cwd': None, 'main_dirty': False}, d
" "$lock_json"

  echo dirty > "$WORK/scratch-dirty.txt"
  lock_json="$(curl -s "http://127.0.0.1:$port/api/worktree-lock/t-lok1")"
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert d['locked'] is False and d['cwd'] is None and d['main_dirty'] is True, d
" "$lock_json"
  rm -f "$WORK/scratch-dirty.txt"

  # locked: a .cockpit-cwd file (the daemon's own write, simulated here) flips
  # locked:true and surfaces the exact path. (main_dirty is untested here on
  # purpose — writing this very file into the fixture's own .tickets/ makes
  # the working tree dirty as a side effect of the test, not the endpoint.)
  echo "/some/worktree/path" > "$WORK/.tickets/t-lok1/.cockpit-cwd"
  lock_json="$(curl -s "http://127.0.0.1:$port/api/worktree-lock/t-lok1")"
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert d['locked'] is True and d['cwd'] == '/some/worktree/path', d
" "$lock_json"
  rm -rf "$WORK/.tickets/t-lok1"

  # t-e5ff: when .tickets/ IS gitignored AND untracked, a git worktree can't
  # materialize it, so a non-main worktree reports tickets_visible:false while
  # the main checkout (which physically holds .tickets/) stays true. A *tracked*
  # .tickets is never ignored (git materializes it in worktrees), so the fixture
  # must untrack it to reproduce the real case. Save/restore fixture state so the
  # other backend's run starts identically.
  local vis_json vis_path
  vis_json="$(curl -s -X POST "http://127.0.0.1:$port/api/worktrees" \
    -H 'Content-Type: application/json' -d '{"branch":"feat/vis-check"}')"
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['ok'] is True, d" "$vis_json"
  vis_path="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['path'])" "$vis_json")"
  cp "$WORK/.gitignore" "$WORK/.gitignore.e5ffbak"
  printf '.tickets/\n' >> "$WORK/.gitignore"
  git -C "$WORK" rm -r --cached --quiet .tickets >/dev/null 2>&1 || true
  local vis_list
  vis_list="$(curl -s "http://127.0.0.1:$port/api/worktrees")"
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
main = [e for e in d if e.get('is_main')]
others = [e for e in d if not e.get('is_main')]
assert main and main[0].get('tickets_visible') is True, ('main should stay visible', d)
assert others and all(e.get('tickets_visible') is False for e in others), ('non-main should be invisible when .tickets/ gitignored+untracked', d)
" "$vis_list"
  # restore: put .gitignore back first (so .tickets is addable again), re-track it.
  mv "$WORK/.gitignore.e5ffbak" "$WORK/.gitignore"
  git -C "$WORK" add .tickets >/dev/null 2>&1 || true
  git -C "$WORK" worktree remove -f "$vis_path" >/dev/null 2>&1 || true
  git -C "$WORK" branch -D feat/vis-check >/dev/null 2>&1 || true
  git -C "$WORK" worktree prune >/dev/null 2>&1 || true
}

run_checks "$PY_PORT" "server.py"

kill "$PY_PID" 2>/dev/null || true
PY_PID=""

if [[ -n "$GO_BIN" ]]; then
  GO_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  SPRINT_CHECK_ROOT="$WORK" "$GO_BIN" "$GO_PORT" >/dev/null 2>&1 &
  GO_PID=$!
  disown "$GO_PID" 2>/dev/null || true
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$GO_PORT/api/git" && break
    sleep 0.1
  done
  run_checks "$GO_PORT" "main.go"
  kill "$GO_PID" 2>/dev/null || true
  GO_PID=""
else
  echo "sprint-check-worktrees: go absent — main.go backend skipped"
fi

printf 'sprint-check-worktrees: ok\n'
