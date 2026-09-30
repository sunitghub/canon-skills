#!/usr/bin/env bash
# sprint-check-track-changes (t-d538) — GET/POST /api/track-changes behave identically in
# server.py and main.go: a registered non-git folder gets `git init` + a .gitignore-only first
# commit; every refusal (existing .git dir or file, no/unknown project, missing confirm, already
# git, nested repo, git missing) leaves the folder untouched; a failed commit rolls back only what
# the call created; an existing .gitignore is never overwritten; synced folders are flagged.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "sprint-check-track-changes: python3/curl/git absent — skipped"
  exit 0
fi

SERVER_PY="$ROOT/tools/sprint-check-app/server.py"
PY3="$(command -v python3)"
GO_BIN=""
PIDS=()
DIRS=()
cleanup() {
  local p leaked=""
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  for d in "${DIRS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done
  [[ -n "$GO_BIN" ]] && rm -rf "$(dirname "$GO_BIN")"
  # t-8765: a server that survives its own test's kill is a leak — say so and fail.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    leaked=""
    for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && leaked="$leaked $p"; done
    [[ -z "$leaked" ]] && break
    sleep 0.2
  done
  if [[ -n "$leaked" ]]; then
    echo "FAIL: sprint-check-track-changes left servers running (PIDs):$leaked" >&2
    exit 1
  fi
  return 0
}
trap cleanup EXIT

if command -v go >/dev/null 2>&1; then
  GO_BIN="$(mktemp -d)/sprint-check-go-bin"
  (cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)
fi

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

# new_dir → sets NEW_DIR. Not via $(...): DIRS must be updated in this shell (t-8765).
new_dir() {
  [[ "$BASH_SUBSHELL" == 0 ]] || { echo "FAIL: $FUNCNAME called in a subshell — its state would be lost (t-8765)" >&2; kill -TERM "$$"; exit 1; }
  NEW_DIR="$(mktemp -d)"
  NEW_DIR="$(cd "$NEW_DIR" && pwd -P)"
  DIRS+=("$NEW_DIR")
}

# start_server <py|go> <default-root> <home> [path-override] → sets SERVER_PORT. Not via $(...) (t-8765).
start_server() {
  local kind="$1" dflt="$2" home="$3" path_env="${4:-$PATH}" port
  [[ "$BASH_SUBSHELL" == 0 ]] || { echo "FAIL: $FUNCNAME called in a subshell — its state would be lost (t-8765)" >&2; kill -TERM "$$"; exit 1; }
  port="$(free_port)"
  if [[ "$kind" == py ]]; then
    PATH="$path_env" HOME="$home" CANON_HOME="$home/.canon" SPRINT_CHECK_NO_BROWSER=1 SPRINT_CHECK_ROOT="$dflt" \
      "$PY3" "$SERVER_PY" "$port" >/dev/null 2>&1 &
  else
    PATH="$path_env" HOME="$home" CANON_HOME="$home/.canon" SPRINT_CHECK_NO_BROWSER=1 SPRINT_CHECK_ROOT="$dflt" \
      "$GO_BIN" "$port" >/dev/null 2>&1 &
  fi
  PIDS+=("$!")
  disown "$!" 2>/dev/null || true
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/api/git" && break
    sleep 0.1
  done
  SERVER_PORT="$port"
}

jget() { python3 -c "import json,sys; v=json.loads(sys.argv[1]).get(sys.argv[2]); print(v if isinstance(v,str) else json.dumps(v))" "$1" "$2"; }
jkeys() { python3 -c "import json,sys; print(','.join(sorted(json.loads(sys.argv[1]))))" "$1"; }

# req <GET|POST> <port> <query> [body] → "<http-code> <body>"
req() {
  local out code
  out="$(mktemp)"
  if [[ "$1" == GET ]]; then
    code="$(curl -s -o "$out" -w '%{http_code}' "http://127.0.0.1:$2/api/track-changes$3")"
  else
    code="$(curl -s -o "$out" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H "Origin: http://127.0.0.1:$2" --data-binary "$4" "http://127.0.0.1:$2/api/track-changes$3")"
  fi
  printf '%s %s' "$code" "$(cat "$out")"
  rm -f "$out"
}

# register <port> <dir> → sets PROJ_ID
register() {
  local r
  r="$(curl -s -X POST -H 'Content-Type: application/json' -H "Origin: http://127.0.0.1:$1" \
    --data-binary "{\"path\":\"$2\"}" "http://127.0.0.1:$1/api/projects")"
  PROJ_ID="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['project']['id'])" "$r")" || fail "register $2: $r"
}

# snapshot <dir> → a listing (names, types, sizes, content hashes) that changes if anything is written
snapshot() {
  python3 -c '
import hashlib,os,sys
for dp,dns,fns in sorted(os.walk(sys.argv[1])):
    dns.sort()
    print("d", os.path.relpath(dp, sys.argv[1]))
    for f in sorted(fns):
        p=os.path.join(dp,f)
        print("f", os.path.relpath(p, sys.argv[1]), hashlib.sha256(open(p,"rb").read()).hexdigest() if os.path.isfile(p) else "special")
' "$1"
}

EXPECTED_IGNORE="$(python3 -c "import importlib.util,sys; s=importlib.util.spec_from_file_location('s', sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); sys.stdout.write(m.TRACK_CHANGES_GITIGNORE)" "$SERVER_PY" 2>/dev/null)"
[[ -n "$EXPECTED_IGNORE" ]] || fail "could not read TRACK_CHANGES_GITIGNORE from server.py"

check_backend() {
  local kind="$1" home dflt port proj r code body snap
  new_dir; home="$NEW_DIR"
  new_dir; dflt="$NEW_DIR"; echo "default root" > "$dflt/readme.txt"
  start_server "$kind" "$dflt" "$home"; port="$SERVER_PORT"

  # ── happy path: one commit, only .gitignore; user files untouched and untracked ──
  new_dir; proj="$NEW_DIR"; echo notes > "$proj/notes.md"
  register "$port" "$proj"
  r="$(req GET "$port" "?project=$PROJ_ID")"
  assert_eq "200" "${r%% *}"; assert_eq "false" "$(jget "${r#* }" tracking)"; assert_eq "null" "$(jget "${r#* }" synced)"
  r="$(req POST "$port" "?project=$PROJ_ID" '{"confirm":true}')"
  assert_eq "200" "${r%% *}"; assert_eq "true" "$(jget "${r#* }" ok)"
  HAPPY_KEYS_POST="$(jkeys "${r#* }")"
  [[ "$(git -C "$proj" rev-parse --is-inside-work-tree)" == true ]] || fail "$kind: not a work tree after track-changes"
  assert_eq "1" "$(git -C "$proj" rev-list --count HEAD)"
  assert_eq ".gitignore" "$(git -C "$proj" show --name-only --format= HEAD)"
  assert_eq "?? notes.md" "$(git -C "$proj" status --porcelain)"
  [[ "$(cat "$proj/.gitignore")" == "$EXPECTED_IGNORE" ]] || fail "$kind: default .gitignore content differs"
  cp "$proj/.gitignore" "$home/written.gitignore"
  r="$(req GET "$port" "?project=$PROJ_ID")"; assert_eq "true" "$(jget "${r#* }" tracking)"
  HAPPY_KEYS_GET="$(jkeys "${r#* }")"
  # double POST: the second is refused and changes nothing
  snap="$(snapshot "$proj")"
  r="$(req POST "$port" "?project=$PROJ_ID" '{"confirm":true}')"
  assert_eq "400" "${r%% *}"; assert_eq "$snap" "$(snapshot "$proj")"
  REFUSE_KEYS="$(jkeys "${r#* }")"

  # ── an existing .gitignore is committed as-is, never overwritten ──
  new_dir; proj="$NEW_DIR"; printf 'custom\r\nkeep-me\n' > "$proj/.gitignore"; cp "$proj/.gitignore" "$home/orig"
  register "$port" "$proj"
  r="$(req POST "$port" "?project=$PROJ_ID" '{"confirm":true}')"; assert_eq "200" "${r%% *}"
  cmp -s "$proj/.gitignore" "$home/orig" || fail "$kind: existing .gitignore was modified"

  # ── refusals leave the folder byte-for-byte unchanged ──
  new_dir; proj="$NEW_DIR"; mkdir "$proj/.git"; register "$port" "$proj"; snap="$(snapshot "$proj")"
  r="$(req POST "$port" "?project=$PROJ_ID" '{"confirm":true}')"
  assert_eq "400" "${r%% *}"; assert_contains "${r#* }" "already has a .git"; assert_eq "$snap" "$(snapshot "$proj")"

  new_dir; proj="$NEW_DIR"; printf 'gitdir: /nowhere\n' > "$proj/.git"; register "$port" "$proj"; snap="$(snapshot "$proj")"
  r="$(req POST "$port" "?project=$PROJ_ID" '{"confirm":true}')"
  assert_eq "400" "${r%% *}"; assert_contains "${r#* }" "already has a .git"; assert_eq "$snap" "$(snapshot "$proj")"

  # no project → refused, and the (non-git) default root gains no .git
  r="$(req POST "$port" "" '{"confirm":true}')"
  assert_eq "400" "${r%% *}"; [[ ! -e "$dflt/.git" ]] || fail "$kind: default root was initialized without ?project"
  r="$(req GET "$port" "")"; assert_eq "400" "${r%% *}"
  r="$(req POST "$port" "?project=" '{"confirm":true}')"
  assert_eq "400" "${r%% *}"; [[ ! -e "$dflt/.git" ]] || fail "$kind: default root was initialized with an empty ?project"
  # ?project=default names the board's own root explicitly (a standalone board, no Cockpit tab id)
  r="$(req GET "$port" "?project=default")"; assert_eq "200" "${r%% *}"; assert_eq "false" "$(jget "${r#* }" tracking)"
  r="$(req POST "$port" "?project=default" '{"confirm":true}')"
  assert_eq "200" "${r%% *}"; [[ -d "$dflt/.git" ]] || fail "$kind: ?project=default did not initialize the board's own root"
  assert_eq ".gitignore" "$(git -C "$dflt" show --name-only --format= HEAD)"

  # unknown id
  r="$(req POST "$port" "?project=0123456789ab" '{"confirm":true}')"; assert_eq "400" "${r%% *}"

  # confirm must be exactly true
  new_dir; proj="$NEW_DIR"; register "$port" "$proj"; snap="$(snapshot "$proj")"
  local c
  for c in '{}' '{"confirm":false}' '{"confirm":"true"}' '{"confirm":1}' '{"confirm":null}' '{"confirm":[true]}'; do
    r="$(req POST "$port" "?project=$PROJ_ID" "$c")"
    assert_eq "400" "${r%% *}"; assert_eq "$snap" "$(snapshot "$proj")"
  done

  # nested inside a parent repo → refused
  new_dir; git -C "$NEW_DIR" init -q; mkdir "$NEW_DIR/child"; proj="$NEW_DIR/child"
  register "$port" "$proj"
  r="$(req POST "$port" "?project=$PROJ_ID" '{"confirm":true}')"
  assert_eq "400" "${r%% *}"; assert_contains "${r#* }" "already inside a git repository"; [[ ! -e "$proj/.git" ]] || fail "$kind: nested .git created"

  # ── a failing commit rolls back only what this call created ──
  mkdir -p "$home/hooks"; printf '#!/bin/sh\nexit 1\n' > "$home/hooks/pre-commit"; chmod +x "$home/hooks/pre-commit"
  printf '[core]\n\thooksPath = %s\n' "$home/hooks" > "$home/.gitconfig"
  new_dir; proj="$NEW_DIR"; echo notes > "$proj/notes.md"; register "$port" "$proj"; snap="$(snapshot "$proj")"
  r="$(req POST "$port" "?project=$PROJ_ID" '{"confirm":true}')"
  assert_eq "400" "${r%% *}"; assert_contains "${r#* }" "Could not start tracking changes"
  assert_eq "$snap" "$(snapshot "$proj")"
  new_dir; proj="$NEW_DIR"; printf 'mine\n' > "$proj/.gitignore"; register "$port" "$proj"; snap="$(snapshot "$proj")"
  r="$(req POST "$port" "?project=$PROJ_ID" '{"confirm":true}')"
  assert_eq "400" "${r%% *}"; assert_eq "$snap" "$(snapshot "$proj")"
  rm -f "$home/.gitconfig"

  # ── synced folders are flagged ──
  new_dir; mkdir -p "$NEW_DIR/Dropbox (Personal)/plans"; proj="$NEW_DIR/Dropbox (Personal)/plans"
  register "$port" "$proj"
  r="$(req GET "$port" "?project=$PROJ_ID")"; assert_eq "Dropbox" "$(jget "${r#* }" synced)"

  # ── malformed input: structured refusal, never a write, server stays up ──
  new_dir; proj="$NEW_DIR"; register "$port" "$proj"; snap="$(snapshot "$proj")"
  local i body
  for i in $(seq 1 150); do
    body="$(python3 -c '
import json,random,sys
random.seed(int(sys.argv[1]))
vals=[None,False,0,1,-1,1.5,"true","yes","",[],[True],{},{"a":1},"x"*5000]
kind=random.randrange(5)
if kind==0: print(json.dumps({"confirm":random.choice(vals)}))
elif kind==1: print(json.dumps(random.choice(vals)))
elif kind==2: print("NaN" if random.random()<.5 else "{\"confirm\": NaN}")
elif kind==3: print("{\"confirm\":" + "["*200 + "]"*200 + "}")
else: print("not json \r\n \x01")
' "$i")"
    r="$(req POST "$port" "?project=$PROJ_ID" "$body")"
    [[ "${r%% *}" == 400 ]] || fail "$kind: malformed body #$i got HTTP ${r%% *}: $body"
    assert_eq "$snap" "$(snapshot "$proj")"
  done
  r="$(req POST "$port" "?project=..%2F..%2Fetc" '{"confirm":true}')"; assert_eq "400" "${r%% *}"
  # body fields never pick the folder: only the registry-resolved ?project is initialized
  new_dir; local decoy="$NEW_DIR"; new_dir; proj="$NEW_DIR"; register "$port" "$proj"
  r="$(req POST "$port" "?project=$PROJ_ID" "{\"confirm\":true,\"path\":\"$decoy\",\"project\":\"../../x\",\"root\":\"$decoy\"}")"
  assert_eq "200" "${r%% *}"; [[ -d "$proj/.git" ]] || fail "$kind: registered folder not initialized"
  [[ ! -e "$decoy/.git" ]] || fail "$kind: a body field chose the folder"
  curl -s -o /dev/null "http://127.0.0.1:$port/api/git" || fail "$kind: server died during the fuzz"
  printf 'sprint-check-track-changes[%s]: ok\n' "$kind"
  eval "${kind}_KEYS=\"$HAPPY_KEYS_GET|$HAPPY_KEYS_POST|$REFUSE_KEYS\""
  eval "${kind}_IGNORE=\"$home/written.gitignore\""
}

# git missing: the POST refuses before touching anything
check_no_git() {
  local kind="$1" home dflt proj r snap
  new_dir; home="$NEW_DIR"; new_dir; dflt="$NEW_DIR"
  start_server "$kind" "$dflt" "$home" "/var/empty"
  new_dir; proj="$NEW_DIR"; register "$SERVER_PORT" "$proj"; snap="$(snapshot "$proj")"
  r="$(req POST "$SERVER_PORT" "?project=$PROJ_ID" '{"confirm":true}')"
  assert_eq "400" "${r%% *}"; assert_contains "${r#* }" "Version history needs Git, which isn't installed"; assert_eq "$snap" "$(snapshot "$proj")"
}

check_backend py
check_no_git py
if [[ -n "$GO_BIN" ]]; then
  check_backend go
  check_no_git go
  assert_eq "$py_KEYS" "$go_KEYS"
  cmp -s "$py_IGNORE" "$go_IGNORE" || fail "default .gitignore differs between backends"
  echo "sprint-check-track-changes: ok (both backends; JSON keys and .gitignore identical)"
else
  echo "sprint-check-track-changes: ok (python only — go absent)"
fi
