#!/usr/bin/env bash
# sprint-check-track-changes (t-d538) — GET/POST /api/track-changes in the Go board
# (t-15d8: the only board): a registered non-git folder gets `git init` + a .gitignore-only first
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

GO_BIN=""
BOARD_TMP="$(mktemp -d)"
PIDS=()
DIRS=()
cleanup() {
  local p leaked=""
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  for d in "${DIRS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done
  rm -rf "$BOARD_TMP"
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

GO_BIN="$(build_board "$BOARD_TMP")"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

# new_dir → sets NEW_DIR. Not via $(...): DIRS must be updated in this shell (t-8765).
new_dir() {
  [[ "$BASH_SUBSHELL" == 0 ]] || { echo "FAIL: $FUNCNAME called in a subshell — its state would be lost (t-8765)" >&2; kill -TERM "$$"; exit 1; }
  NEW_DIR="$(mktemp -d)"
  NEW_DIR="$(cd "$NEW_DIR" && pwd -P)"
  DIRS+=("$NEW_DIR")
}

# start_server <go> <default-root> <home> [path-override] → sets SERVER_PORT. Not via $(...) (t-8765).
# git reads its global config ONLY from $home/.gitconfig (t-c8be): the rollback case plants a hook there, and a
# caller's own GIT_CONFIG_GLOBAL / ~/.gitconfig must neither hide it nor leak in.
start_server() {
  local kind="$1" dflt="$2" home="$3" path_env="${4:-$PATH}" port
  [[ "$BASH_SUBSHELL" == 0 ]] || { echo "FAIL: $FUNCNAME called in a subshell — its state would be lost (t-8765)" >&2; kill -TERM "$$"; exit 1; }
  port="$(free_port)"
  PATH="$path_env" HOME="$home" CANON_HOME="$home/.canon" SPRINT_CHECK_NO_BROWSER=1 SPRINT_CHECK_ROOT="$dflt" \
    GIT_CONFIG_GLOBAL="$home/.gitconfig" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$home/.config" \
    COCKPIT_STATE_DIR="$home/ck" COCKPIT_DAEMON_BIN=/usr/bin/false TMPDIR="$BOARD_TMP" \
    "$GO_BIN" "$port" >/dev/null 2>&1 &
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

# The default .gitignore, written out here as the expected bytes (t-15d8); main.go's
# trackChangesGitignore must say the same. $(...) drops the final newline, as it does for the file read below.
EXPECTED_IGNORE="$(printf '%s\n' '# Added by canon when this folder started tracking changes.' .DS_Store Thumbs.db desktop.ini \
  node_modules/ .venv/ __pycache__/ dist/ build/ '*.mp4' '*.mov' '*.zip' .env '.env.*' '*.pem' id_rsa id_ed25519 .claude/settings.local.json)"

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

# t-a854: GET/POST /api/first-snapshot — the preview stages nothing; a clean folder is saved as one commit; a finding saves nothing,
# resets the index and names path:line:rule (never the value); `ignore` takes only previewed files; every refusal changes nothing.
fsreq() { # fsreq <GET|POST> <port> <query> [body] → "<code> <body>"
  local out code; out="$(mktemp)"
  if [[ "$1" == GET ]]; then code="$(curl -s -o "$out" -w '%{http_code}' "http://127.0.0.1:$2/api/first-snapshot$3")"
  else code="$(curl -s -o "$out" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "Origin: http://127.0.0.1:$2" --data-binary "$4" "http://127.0.0.1:$2/api/first-snapshot$3")"; fi
  printf '%s %s' "$code" "$(cat "$out")"; rm -f "$out"
}
check_first_snapshot() {
  local kind="$1" home dflt port proj r snap secret
  new_dir; home="$NEW_DIR"; new_dir; dflt="$NEW_DIR"
  start_server "$kind" "$dflt" "$home"; port="$SERVER_PORT"
  # not tracking yet: refused, nothing written
  new_dir; proj="$NEW_DIR"; echo notes > "$proj/notes.md"; register "$port" "$proj"; snap="$(snapshot "$proj")"
  r="$(fsreq POST "$port" "?project=$PROJ_ID" '{"confirm":true}')"; assert_eq "400" "${r%% *}"; assert_eq "$snap" "$(snapshot "$proj")"
  r="$(fsreq GET "$port" "?project=$PROJ_ID")"; assert_eq "false" "$(jget "${r#* }" can_snapshot)"
  req POST "$port" "?project=$PROJ_ID" '{"confirm":true}' >/dev/null
  mkdir -p "$proj/src" "$proj/my docs"; echo code > "$proj/src/a.txt"; echo more > "$proj/my docs/b c.txt"
  head -c 6000000 /dev/zero > "$proj/big.bin"
  secret="AKIA""IOSFODNN7ABCDEFG"   # split so this file is not itself a finding
  printf 'aws=%s\n' "$secret" > "$proj/creds.txt"; printf 'TOKEN=%s\n' "$secret" > "$proj/.env"
  # preview: counts, folders, a large file; stages nothing, and the ignored .env is not counted
  r="$(fsreq GET "$port" "?project=$PROJ_ID")"; assert_eq "200" "${r%% *}"
  assert_eq "true" "$(jget "${r#* }" can_snapshot)"; assert_eq "5" "$(jget "${r#* }" files)"
  assert_contains "${r#* }" '"path":"big.bin"'; assert_contains "${r#* }" '"name":"my docs"'
  assert_eq "" "$(git -C "$proj" diff --cached --name-only)"
  # a POST without confirm, an unknown project and a traversal all change nothing
  snap="$(snapshot "$proj")"
  r="$(fsreq POST "$port" "?project=$PROJ_ID" '{}')"; assert_eq "400" "${r%% *}"
  r="$(fsreq POST "$port" "?project=nope" '{"confirm":true}')"; assert_eq "400" "${r%% *}"
  assert_eq "$snap" "$(snapshot "$proj")"
  # a finding: nothing committed, index reset, path:line:rule named, the value never in the answer
  r="$(fsreq POST "$port" "?project=$PROJ_ID" '{"confirm":true}')"
  assert_eq "400" "${r%% *}"; assert_eq "true" "$(jget "${r#* }" blocked)"
  assert_contains "${r#* }" '"path":"creds.txt"'; assert_contains "${r#* }" '"line":"1"'; assert_contains "${r#* }" '"rule":"aws-access-key"'
  [[ "${r#* }" != *"$secret"* ]] || fail "$kind: the answer carries the secret value"
  assert_eq "1" "$(git -C "$proj" rev-list --count HEAD)"; assert_eq "" "$(git -C "$proj" diff --cached --name-only)"
  # ignore only takes previewed files: a made-up path, a traversal and a newline are refused and .gitignore is unchanged
  snap="$(snapshot "$proj")"
  for bad in '"nope.txt"' '"../x"' '"a\nb"'; do
    r="$(fsreq POST "$port" "?project=$PROJ_ID" "{\"confirm\":true,\"ignore\":[$bad]}")"; assert_eq "400" "${r%% *}"
  done
  assert_eq "$snap" "$(snapshot "$proj")"
  # a file whose name a pattern reads specially or holds a newline: `[` is escaped so only that file goes; the newline name is refused
  echo x > "$proj/a[1].txt"; echo y > "$proj/a1.txt"
  if printf z > "$proj/we"$'\n'"ird" 2>/dev/null; then
    snap="$(cat "$proj/.gitignore")"
    r="$(fsreq POST "$port" "?project=$PROJ_ID" "{\"confirm\":true,\"ignore\":[\"we\\nird\"]}")"; assert_eq "400" "${r%% *}"
    assert_eq "$snap" "$(cat "$proj/.gitignore")"; assert_contains "${r#* }" "not part of the snapshot"   # refused as a name, not blocked by the scan
    rm -f "$proj/we"$'\n'"ird"
  fi
  # a .gitignore that is a symlink is never written through
  new_dir; local linkdir="$NEW_DIR"; echo keep > "$linkdir/target"; cp "$proj/.gitignore" "$linkdir/gi.orig"
  rm "$proj/.gitignore"; ln -s "$linkdir/target" "$proj/.gitignore"
  r="$(fsreq POST "$port" "?project=$PROJ_ID" '{"confirm":true,"ignore":["creds.txt"]}')"; assert_eq "400" "${r%% *}"
  assert_eq "keep" "$(cat "$linkdir/target")"
  rm "$proj/.gitignore"; cp "$linkdir/gi.orig" "$proj/.gitignore"
  # ignore the finding, retry: one commit with the neutral message, creds.txt left out, the others in
  r="$(fsreq POST "$port" "?project=$PROJ_ID" '{"confirm":true,"ignore":["creds.txt","a[1].txt"]}')"
  assert_eq "200" "${r%% *}"; assert_eq "true" "$(jget "${r#* }" ok)"
  git -C "$proj" ls-files | grep -qx "a1.txt" || fail "$kind: a1.txt was not saved (an unescaped [1] pattern matched it)"
  ! git -C "$proj" ls-files | grep -qx "a\[1\].txt" || fail "$kind: a[1].txt was saved"
  assert_eq "2" "$(git -C "$proj" rev-list --count HEAD)"
  assert_eq "chore: first snapshot of this folder" "$(git -C "$proj" log -1 --format=%s)"
  git -C "$proj" ls-files | grep -qx "my docs/b c.txt" || fail "$kind: a file with a space was not saved"
  git -C "$proj" ls-files | grep -qx "src/a.txt" || fail "$kind: src/a.txt was not saved"
  ! git -C "$proj" ls-files | grep -qx "creds.txt" || fail "$kind: the flagged file was saved"
  ! git -C "$proj" ls-files | grep -qx ".env" || fail "$kind: .env was saved"
  grep -qx "/creds.txt" "$proj/.gitignore" || fail "$kind: the ignored file is not in .gitignore"
  # a second snapshot is refused (a history beyond canon's start commit)
  r="$(fsreq POST "$port" "?project=$PROJ_ID" '{"confirm":true}')"; assert_eq "400" "${r%% *}"
  assert_eq "2" "$(git -C "$proj" rev-list --count HEAD)"
  printf 'sprint-check-first-snapshot[%s]: ok\n' "$kind"
}

# t-a854: no bash on the PATH means no secret scan, and then nothing is saved: the index is clean, no commit, .gitignore as it was (even after an ignore)
check_snapshot_no_scanner() {
  local kind="$1" home dflt proj r snap bin
  new_dir; home="$NEW_DIR"; new_dir; dflt="$NEW_DIR"; new_dir; bin="$NEW_DIR"; ln -s "$(command -v git)" "$bin/git"
  start_server "$kind" "$dflt" "$home" "$bin"
  new_dir; proj="$NEW_DIR"; echo notes > "$proj/notes.md"; register "$SERVER_PORT" "$proj"
  req POST "$SERVER_PORT" "?project=$PROJ_ID" '{"confirm":true}' >/dev/null
  snap="$(cat "$proj/.gitignore")"
  r="$(fsreq POST "$SERVER_PORT" "?project=$PROJ_ID" '{"confirm":true,"ignore":["notes.md"]}')"
  assert_eq "400" "${r%% *}"; assert_contains "${r#* }" "needs bash"
  assert_eq "$snap" "$(cat "$proj/.gitignore")"; assert_eq "1" "$(git -C "$proj" rev-list --count HEAD)"; assert_eq "" "$(git -C "$proj" diff --cached --name-only)"
}

check_backend go
check_first_snapshot go
check_snapshot_no_scanner go
check_no_git go
# the JSON key sets of GET, a successful POST and a refusal (compared py == go before t-15d8; now explicit)
assert_eq "git_available,ok,synced,tracking|commit,ok|error,ok" "$go_KEYS"
echo "sprint-check-track-changes: ok"
