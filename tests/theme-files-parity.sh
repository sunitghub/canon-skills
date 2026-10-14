#!/usr/bin/env bash
# theme-files-parity (t-f889) — user themes in $CANON_HOME/themes are untrusted files, checked by three ports with no
# shared code: server.py, sprint-check-go and the page's checkTheme()/validateTheme() (static/theme-data.js). This test
# holds them to each other and to theme.schema.json:
#   1. a fixed corpus (tests/theme-files-corpus.py build): both servers' GET /api/themes are equal, every file gets its
#      expected reason, the schema's verdict matches on every file that parses to JSON, and the page's checkTheme()
#      gives the same reason for every file that reaches the object checks;
#   2. 51 files: the 51st is refused; a symlinked themes folder is read;
#   3. a seeded fuzz (THEME_FUZZ_N files, default 350, 50 per round): the three agree on every file, no 5xx;
#   4. POST /api/themes/open with a stub launcher: seeds only a folder it creates, never overwrites, launches exactly
#      the folder path, ignores the body, refuses a foreign Origin/Host, launches nothing under SPRINT_CHECK_NO_BROWSER.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

for tool in python3 curl go node; do
  command -v "$tool" >/dev/null 2>&1 || fail "theme-files-parity: $tool not found (all four are needed; nothing was checked)"
done

SERVER_PY="$ROOT/tools/sprint-check-app/server.py"
CORPUS="$ROOT/tests/theme-files-corpus.py"
THEME_DATA="$ROOT/tools/sprint-check-app/static/theme-data.js"
SCHEMA="$ROOT/tools/sprint-check-app/theme.schema.json"
SEED="$ROOT/tools/sprint-check-app/theme-seed"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/theme-parity.XXXXXX")" && pwd -P)"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

GO_BIN="$TMP/sprint-check-go-bin"
(cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)
mkdir -p "$TMP/proj/.tickets" "$TMP/ck"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

# start <py|go> <canon_home> [VAR=value ...] -> prints the port; the PID is recorded here, not in a subshell
PORT=""
start() {
  local kind="$1" home="$2"; shift 2
  PORT="$(free_port)"
  if [[ "$kind" == py ]]; then
    env SPRINT_CHECK_ROOT="$TMP/proj" CANON_HOME="$home" COCKPIT_STATE_DIR="$TMP/ck" COCKPIT_DAEMON_BIN=/usr/bin/false \
      SPRINT_CHECK_NO_BROWSER=1 "$@" python3 "$SERVER_PY" "$PORT" >/dev/null 2>&1 &
  else
    (cd "$ROOT" && exec env SPRINT_CHECK_ROOT="$TMP/proj" CANON_HOME="$home" COCKPIT_STATE_DIR="$TMP/ck" COCKPIT_DAEMON_BIN=/usr/bin/false \
      SPRINT_CHECK_NO_BROWSER=1 "$@" "$GO_BIN" "$PORT") >/dev/null 2>&1 &
  fi
  PIDS+=("$!")
  disown "$!" 2>/dev/null || true
  local i
  for i in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/themes" && return 0; sleep 0.1; done
  fail "theme-files-parity: $kind server did not start"
}

# compare <label> <py json file> <go json file> [expected json file] — parity, expectations, schema, and the page
compare() {
  python3 - "$1" "$2" "$3" "${4:-}" "$CORPUS" "$SCHEMA" "$THEME_DATA" <<'PY'
import importlib.util, json, os, subprocess, sys
label, py_f, go_f, exp_f, corpus, schema_f, theme_data = sys.argv[1:8]
spec = importlib.util.spec_from_file_location('corpus', corpus); C = importlib.util.module_from_spec(spec); spec.loader.exec_module(C)
py, go = json.load(open(py_f)), json.load(open(go_f))
errs = []
if py != go:
    errs.append(f'server.py and main.go differ:\n  py={json.dumps(py, sort_keys=True)[:3000]}\n  go={json.dumps(go, sort_keys=True)[:3000]}')
d = py['dir']
verdict = {t['file']: '' for t in py['themes']}
verdict.update({r['file']: r['reason'] for r in py['rejected']})
if exp_f:
    exp = json.load(open(exp_f))
    for f, want in exp.items():
        if verdict.get(f) != want:
            errs.append(f'{f}: expected {want!r}, got {verdict.get(f)!r}')
    extra = set(verdict) - set(exp)
    if extra:
        errs.append(f'listed but not in the corpus: {sorted(extra)}')
known = {C.R_OBJ, C.R_NAME, C.R_MODE, C.R_KEYS, C.R_FILE, C.R_JSON, 'symbolic links are not read', 'not a regular file',
         'larger than 16 KiB', 'starts with a byte order mark', 'not valid UTF-8', 'nested too deeply', 'cannot be read',
         'too many theme files (at most 50)'} | {f'colors.{k} must be #rgb or #rrggbb' for k in C.KEYS}
for f, r in verdict.items():
    if r and r not in known:
        errs.append(f'{f}: unknown reason {r!r}')
# the schema (an independent reading) and the page's checkTheme() on every file that reached the object checks
object_stage = {'', C.R_OBJ, C.R_NAME, C.R_MODE, C.R_KEYS} | {f'colors.{k} must be #rgb or #rrggbb' for k in C.KEYS}
schema = json.load(open(schema_f))
cases = []
for f, r in sorted(verdict.items()):
    if r not in object_stage or r == C.R_FILE:
        continue
    raw = open(os.path.join(d, f), 'rb').read().decode('utf-8')
    val = json.loads(raw, parse_int=lambda s: 0)  # reached the object checks, so it parsed on both servers (no NaN/Infinity)
    ok = C.schema_ok(schema, val, schema)
    if ok != (r == ''):
        errs.append(f'{f}: schema says {"valid" if ok else "invalid"}, servers say {r or "accepted"!r}')
    cases.append({'file': f, 'raw': raw, 'want': r})
entries = py['themes']
node = subprocess.run(['node', '--input-type=module', '-e', '''
import { readFileSync } from 'node:fs';
const m = await import(process.argv[1]);
const { cases, entries } = JSON.parse(readFileSync(0, 'utf8'));
const out = [];
for (const c of cases) { let got; try { got = m.checkTheme(JSON.parse(c.raw)); } catch (e) { got = 'THROW ' + e.message; } if (got !== c.want) out.push(`${c.file}: page says ${JSON.stringify(got)}, servers ${JSON.stringify(c.want)}`); }
for (const e of entries) { const t = m.validateTheme(e); if (!t) out.push(`${e.file}: page refused a server-accepted entry`); else if (!Object.values(t.c).every(v => /^#[0-9a-f]{6}$/.test(v))) out.push(`${e.file}: not normalised`); }
console.log(JSON.stringify(out));
''', theme_data], input=json.dumps({'cases': cases, 'entries': entries}), capture_output=True, text=True)
if node.returncode != 0:
    errs.append('node failed: ' + node.stderr[-2000:])
else:
    errs += json.loads(node.stdout)
if errs:
    print(f'theme-files-parity: FAIL ({label})'); print('\n'.join('  ' + e for e in errs[:60])); sys.exit(1)
print(f'  {label}: {len(verdict)} files, {len(py["themes"])} accepted, {len(cases)} checked by the page and the schema')
PY
}

get() { curl -s -o "$2" -w '%{http_code}' "http://127.0.0.1:$1/api/themes"; }

# ── 1. fixed corpus ──
HOME_C="$TMP/home-corpus"; mkdir -p "$HOME_C"
python3 "$CORPUS" build "$TMP/corpus" > "$TMP/expected-all.json"
start py "$HOME_C"; PY_PORT="$PORT"
start go "$HOME_C"; GO_PORT="$PORT"
for b in $(python3 -c "import json,sys; print(' '.join(sorted(json.load(open(sys.argv[1])))))" "$TMP/expected-all.json"); do
  mv "$TMP/corpus/$b" "$HOME_C/themes"
  python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))[sys.argv[2]]))" "$TMP/expected-all.json" "$b" > "$TMP/expected.json"
  [[ "$(get "$PY_PORT" "$TMP/py.json")" == 200 ]] || fail "theme-files-parity: server.py /api/themes not 200"
  [[ "$(get "$GO_PORT" "$TMP/go.json")" == 200 ]] || fail "theme-files-parity: main.go /api/themes not 200"
  compare "corpus $b" "$TMP/py.json" "$TMP/go.json" "$TMP/expected.json"
  mv "$HOME_C/themes" "$TMP/corpus/$b"
done

# ── 2. the 50-file limit; a symlinked folder; an absent folder (nothing created) ──
rm -rf "$HOME_C/themes"; python3 "$CORPUS" many "$HOME_C/themes"
get "$PY_PORT" "$TMP/py.json" >/dev/null; get "$GO_PORT" "$TMP/go.json" >/dev/null
python3 -c "import json; exp = {f't{i:02d}.json': '' for i in range(50)}; exp['t50.json'] = 'too many theme files (at most 50)'; print(json.dumps(exp))" > "$TMP/expected.json"
compare "51 files" "$TMP/py.json" "$TMP/go.json" "$TMP/expected.json"
mv "$HOME_C/themes" "$TMP/real-themes"; ln -s "$TMP/real-themes" "$HOME_C/themes"
get "$PY_PORT" "$TMP/py.json" >/dev/null; get "$GO_PORT" "$TMP/go.json" >/dev/null
compare "symlinked folder" "$TMP/py.json" "$TMP/go.json" "$TMP/expected.json"
rm "$HOME_C/themes"
get "$PY_PORT" "$TMP/py.json" >/dev/null; get "$GO_PORT" "$TMP/go.json" >/dev/null
python3 - "$TMP/py.json" "$TMP/go.json" "$HOME_C/themes" <<'PY' || fail "theme-files-parity: an absent folder must list nothing and create nothing"
import json, os, sys
for f in sys.argv[1:3]:
    d = json.load(open(f))
    assert d['themes'] == [] and d['rejected'] == [] and 'error' not in d, d
assert not os.path.lexists(sys.argv[3])
PY
echo "  absent folder: empty lists, nothing created"

# ── 3. fuzz ──
N="${THEME_FUZZ_N:-350}"; SEED_N="${THEME_FUZZ_SEED:-8891}"
python3 "$CORPUS" fuzz "$TMP/fuzz" "$N" "$SEED_N"
round=0
while IFS= read -r batch; do
  rm -rf "$HOME_C/themes"; mkdir -p "$HOME_C/themes"
  for f in $batch; do cp "$TMP/fuzz/$f" "$HOME_C/themes/"; done
  [[ "$(get "$PY_PORT" "$TMP/py.json")" == 200 ]] || fail "theme-files-parity: server.py failed on fuzz round $round"
  [[ "$(get "$GO_PORT" "$TMP/go.json")" == 200 ]] || fail "theme-files-parity: main.go failed on fuzz round $round"
  compare "fuzz round $round" "$TMP/py.json" "$TMP/go.json"
  round=$((round + 1))
done < <(ls "$TMP/fuzz" | sort | paste -d' ' $(printf -- '- %.0s' $(seq 1 50)))
echo "  fuzz: $N files (seed $SEED_N) in $round rounds, all three agree"

# ── 4. Open themes folder ──
STUB="$TMP/open-stub.sh"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
# records each call: the argument count, then each argument on its own line
{ echo "argc=$#"; for a in "$@"; do echo "arg=$a"; done; } >> "$OPEN_LOG"
SH
chmod +x "$STUB"
post_open() { curl -s -o "$TMP/open.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' "${@:2}" "http://127.0.0.1:$1/api/themes/open"; }
calls() { if [[ -f "$1" ]]; then grep -c '^argc=' "$1"; else echo 0; fi; }
wait_calls() { local i; for i in $(seq 1 50); do [[ "$(calls "$1")" == "$2" ]] && return 0; sleep 0.1; done; return 1; }

for kind in py go; do
  H="$TMP/home-open-$kind"; LOG="$TMP/open-$kind.log"
  mkdir -p "$H"
  start "$kind" "$H" CANON_OPEN_BIN="$STUB" OPEN_LOG="$LOG"; P="$PORT"
  D="$(cd "$H" && pwd -P)/themes"
  [[ "$(post_open "$P" -H 'Origin: http://localhost' -d '{}')" == 200 ]] || fail "$kind: open must succeed: $(cat "$TMP/open.json")"
  python3 -c "import json,sys; d=json.load(open('$TMP/open.json')); assert d['ok'] and d['created'] is True and d['launched'] is True, d" \
    || fail "$kind: first open must create and launch"
  wait_calls "$LOG" 1 || fail "$kind: the launcher was not run once"
  [[ "$(cat "$LOG")" == "$(printf 'argc=1\narg=%s' "$D")" ]] || fail "$kind: launcher argv must be exactly the folder, got: $(cat "$LOG")"
  cmp -s "$D/example.json" "$SEED/example.json" || fail "$kind: example.json is not the seed"
  cmp -s "$D/README.md" "$SEED/README.md" || fail "$kind: README.md is not the seed"
  get "$P" "$TMP/list.json" >/dev/null
  python3 -c "import json; d=json.load(open('$TMP/list.json')); assert [t['id'] for t in d['themes']] == ['user-example'] and d['rejected'] == [], d" \
    || fail "$kind: the seeded example must be listed as valid"
  # an existing folder: nothing seeded, nothing overwritten; the body is never read
  echo 'mine' > "$D/README.md"; rm "$D/example.json"
  [[ "$(post_open "$P" -d '{"path":"/etc","dir":"/tmp","args":["-a","Terminal"]}')" == 200 ]] || fail "$kind: second open must succeed"
  python3 -c "import json; d=json.load(open('$TMP/open.json')); assert d['created'] is False, d" || fail "$kind: second open must not report created"
  wait_calls "$LOG" 2 || fail "$kind: the second open did not launch"
  [[ "$(tail -2 "$LOG")" == "$(printf 'argc=1\narg=%s' "$D")" ]] || fail "$kind: a body path reached the launcher: $(tail -2 "$LOG")"
  [[ "$(cat "$D/README.md")" == mine && ! -e "$D/example.json" ]] || fail "$kind: an existing folder was re-seeded or overwritten"
  # foreign Origin / Host: 403, no launch
  for o in 'http://evil.example' 'http://127.0.0.1.attacker.example' 'null'; do
    [[ "$(post_open "$P" -H "Origin: $o" -d '{}')" == 403 ]] || fail "$kind: Origin $o must 403"
  done
  [[ "$(post_open "$P" -H 'Host: evil.example' -d '{}')" == 403 ]] || fail "$kind: a foreign Host must 403"
  sleep 0.3; [[ "$(calls "$LOG")" == 2 ]] || fail "$kind: a refused request launched something"
  # the themes path is a file: refused, no launch
  rm -rf "$D"; echo x > "$D"
  [[ "$(post_open "$P" -d '{}')" == 400 ]] || fail "$kind: a file at the themes path must 400"
  sleep 0.3; [[ "$(calls "$LOG")" == 2 ]] || fail "$kind: a refused open launched something"
  # break-it: the route reads no body, so both servers treat every body alike; it needs a JSON content type
  rm "$D"; mkdir "$D"
  for ct in 'text/plain' 'application/x-www-form-urlencoded' 'multipart/form-data; boundary=x' 'application/jsonx'; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: $ct" -d '{}' "http://127.0.0.1:$P/api/themes/open")"
    [[ "$code" == 415 ]] || fail "$kind: Content-Type '$ct' must 415, got $code"
  done
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type:' -d '{}' "http://127.0.0.1:$P/api/themes/open")"
  [[ "$code" == 415 ]] || fail "$kind: no Content-Type must 415, got $code"
  sleep 0.3; [[ "$(calls "$LOG")" == 2 ]] || fail "$kind: a wrong content type launched something"
  printf '\xff\xfe{\x00}\x00' > "$TMP/utf16.bin"
  for body in 'null' '{"a":NaN}' '[]' 'not json' "@$TMP/utf16.bin"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json; charset=utf-8' --data-binary "$body" "http://127.0.0.1:$P/api/themes/open")"
    [[ "$code" == 200 ]] || fail "$kind: body $body must be ignored (200), got $code"
  done
  wait_calls "$LOG" 7 || fail "$kind: each ignored-body open must launch once ($(calls "$LOG") calls)"
  [[ "$(grep -c "^arg=$D\$" "$LOG")" == 7 && "$(grep -c '^argc=1$' "$LOG")" == 7 ]] || fail "$kind: a launch got something other than the folder"
  # SPRINT_CHECK_NO_BROWSER=1 without an override: nothing launched (t-269d)
  H2="$TMP/home-nolaunch-$kind"; mkdir -p "$H2"
  start "$kind" "$H2"
  [[ "$(post_open "$PORT" -d '{}')" == 200 ]] || fail "$kind: open without a launcher must still succeed"
  python3 -c "import json; d=json.load(open('$TMP/open.json')); assert d['launched'] is False and d['created'] is True, d" \
    || fail "$kind: SPRINT_CHECK_NO_BROWSER=1 must launch nothing"
  # break-it: a path that cannot be checked or created is refused the same way on both, never a dropped connection
  H3="$TMP/home-bad-$kind"; mkdir -p "$H3"
  echo x > "$H3/file-home"                                          # CANON_HOME is a file (ENOTDIR)
  mkdir -p "$H3/loop"; ln -s themes "$H3/loop/themes"               # themes is a link to itself (ELOOP)
  homes=("$H3/file-home" "$H3/loop")
  if [[ "$(id -u)" != 0 ]]; then mkdir -p "$H3/acc/in"; chmod 000 "$H3/acc/in"; homes+=("$H3/acc/in"); else echo "  (root: the no-permission case is skipped)"; fi
  for h in "${homes[@]}"; do
    start "$kind" "$h" CANON_OPEN_BIN="$STUB" OPEN_LOG="$LOG"
    code="$(post_open "$PORT" -d '{}')" || true
    [[ "$code" == 400 ]] || fail "$kind: CANON_HOME=$h must 400, got '$code'"
    python3 -c "import json; d=json.load(open('$TMP/open.json')); assert d == {'ok': False, 'error': 'the themes path is not a folder'}, d" \
      || fail "$kind: CANON_HOME=$h: wrong error $(cat "$TMP/open.json")"
  done
  [[ -d "$H3/acc/in" ]] && chmod 755 "$H3/acc/in"
  sleep 0.3; [[ "$(calls "$LOG")" == 7 ]] || fail "$kind: a refused folder launched something"
  # sixteen opens at once on a missing folder, 30 times: each time exactly one creates it (and seeds it), the others
  # open it (break-it: Go reported created five times of eight)
  H4="$TMP/home-race-$kind"; mkdir -p "$H4"; LOG4="$TMP/open-race-$kind.log"
  start "$kind" "$H4" CANON_OPEN_BIN="$STUB" OPEN_LOG="$LOG4"
  for round in $(seq 1 30); do
    rm -rf "$H4/themes"
    for i in $(seq 1 16); do
      curl -s -X POST -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$PORT/api/themes/open" > "$TMP/race-$kind-$i.json" &
    done
    wait
    python3 - "$TMP" "$kind" <<'PY' || fail "$kind: parallel opens (round $round): exactly one must create the folder"
import json, sys
r = [json.load(open(f'{sys.argv[1]}/race-{sys.argv[2]}-{i}.json')) for i in range(1, 17)]
assert all(x['ok'] for x in r) and sum(x['created'] for x in r) == 1, [x.get('created') for x in r]
PY
    cmp -s "$H4/themes/example.json" "$SEED/example.json" || fail "$kind: parallel opens (round $round): the seed is not intact"
  done
  echo "  open ($kind): seeds once, launches only the folder, refuses foreign Origin/Host and other content types, ignores the body, refuses an unusable path, one creator under a race"
done

# ── 5. a theme file swapped for a FIFO between the server's check and its open never hangs a request (break-it) ──
for kind in py go; do
  H5="$TMP/home-fifo-$kind"; mkdir -p "$H5/themes"
  start "$kind" "$H5"; P="$PORT"
  python3 - "$H5/themes" "$SEED/example.json" 8 <<'PY' &
import os, sys, time
d, seed, secs = sys.argv[1], open(sys.argv[2], 'rb').read(), float(sys.argv[3])
end, n = time.time() + secs, 0
while time.time() < end:
    n += 1
    f, r = os.path.join(d, f'.fifo{n}'), os.path.join(d, f'.reg{n}')
    os.mkfifo(f); os.replace(f, os.path.join(d, 'race.json'))
    with open(r, 'wb') as h: h.write(seed)
    os.replace(r, os.path.join(d, 'race.json'))
PY
  SWAP=$!
  hung=0; tries=0
  while kill -0 "$SWAP" 2>/dev/null; do
    tries=$((tries + 1))
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$P/api/themes" || hung=$((hung + 1))
  done
  wait "$SWAP" || true
  [[ "$tries" -gt 50 ]] || fail "$kind: the FIFO stress ran only $tries requests"
  [[ "$hung" == 0 ]] || fail "$kind: $hung of $tries requests hung on a file swapped for a FIFO"
  echo "  fifo swap ($kind): $tries requests, none hung"
done

echo "theme-files-parity: ok"
