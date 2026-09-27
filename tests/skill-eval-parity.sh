#!/usr/bin/env bash
# skill-eval-parity (t-b9a7) — Skill Eval is implemented twice: server.py (tools/skill-check +
# tools/plugin-eval-gen) and the Go board (tools/sprint-check-go/skilleval.go, what Windows runs).
# This locks them together: /api/skill-eval/check answers byte-identically (after json.loads) on
# both boards for the fixture corpus plus a seeded fuzz that aims at the known runtime gaps, and
# for every check-passing skill the Go-generated eval plugin is identical (diff -r) to
# plugin-eval-gen's. Not gated on jq for the /check comparison: the Go side needs none.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v go >/dev/null 2>&1; then
  echo "skill-eval-parity: python3/curl/go absent — skipped"
  exit 0
fi

WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
CACHE="$ROOT/.canon-cache/skill-eval"
BEFORE="$(ls "$CACHE" 2>/dev/null || true)"
GO_BIN="$WORK/bin/sprint-check-go-bin"
PIDS=()
cleanup() {
  local p leaked=""
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    leaked=""
    for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && leaked="$leaked $p"; done
    [[ -z "$leaked" ]] && break
    sleep 0.2
  done
  if [[ -d "$CACHE" ]]; then   # only the run dirs this test created, never a developer's own
    for d in "$CACHE"/*; do [[ -e "$d" ]] || continue; grep -qxF "$(basename "$d")" <<<"$BEFORE" || rm -rf "$d"; done
  fi
  rm -rf "$ROOT/.canon-cache/parity-bash" "$WORK"
  if [[ -n "$leaked" ]]; then echo "FAIL: skill-eval-parity left servers running (PIDs):$leaked" >&2; exit 1; fi
  return 0
}
trap cleanup EXIT

mkdir -p "$WORK/bin" "$WORK/home" "$WORK/proj/skills"
(cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)
PROJ="$WORK/proj"
cp -R "$ROOT/tests/fixtures/skill-check/." "$PROJ/skills/"

# A stub `claude` for the Go run (generation parity only; no model spend): writes the result file.
STUB="$WORK/bin/claude-stub"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --json ] && out="$2"; shift; done
[ -n "$out" ] && printf '{"aggregates":{"casesTotal":1,"casesPassed":1}}' > "$out"
exit 0
SH
chmod +x "$STUB"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

# start_server <py|go> → sets SERVER_PORT. Not via $(...): PIDS must be updated in this shell (t-8765).
start_server() {
  [[ "$BASH_SUBSHELL" == 0 ]] || { echo "FAIL: $FUNCNAME called in a subshell (t-8765)" >&2; kill -TERM "$$"; exit 1; }
  local port; port="$(free_port)"
  if [[ "$1" == py ]]; then
    HOME="$WORK/home" CANON_HOME="$WORK/home/.canon" SPRINT_CHECK_NO_BROWSER=1 SPRINT_CHECK_ROOT="$PROJ" \
      python3 "$ROOT/tools/sprint-check-app/server.py" "$port" >/dev/null 2>&1 &
  else
    # cwd = canon root: a temp-built binary finds app.html (and so canon's root) from there.
    (cd "$ROOT" && exec env HOME="$WORK/home" CANON_HOME="$WORK/home/.canon" SPRINT_CHECK_NO_BROWSER=1 \
      SPRINT_CHECK_ROOT="$PROJ" SKILL_EVAL_CLAUDE_BIN="$STUB" "$GO_BIN" "$port") >/dev/null 2>&1 &
  fi
  PIDS+=("$!")
  disown "$!" 2>/dev/null || true
  for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$port/api/git" && break; sleep 0.1; done
  SERVER_PORT="$port"
}

# Seeded fuzz corpus: each skill aims at one or more places where Python and Go text handling differ.
python3 - "$PROJ/skills" <<'PY'
import json, os, random, sys
root = sys.argv[1]
rnd = random.Random(20260927)
WS = [" ", "\t", " ", "\u0085", "\x1c", "\x1f", " ", "　", "\v"]
def w(): return rnd.choice(WS)
def text(): return rnd.choice(["plain", "ünïcödé", "日本語", "line sep", "a\"b'c", "<tag>&", "tab\there", "emoji 🎉", ""])
FM_KEYS = ['name: fz', 'description: ' , '"h\\x6fooks": x', '"h\\157oks": x', '"h\\u006fooks": x', '"\\N{LATIN SMALL LETTER O}": x',
           "'quoted': v", 'effort: MAX', 'effort: extreme', 'disable-model-invocation: YES', 'user-invocable: maybe', 'background: 1',
           'context: Fork', 'context: thread', 'shell: PowerShell', 'shell: zsh', 'when_to_use: ', 'compatibility: ', 'hooks: {}',
           '"a\\qb": x', '"\\x4": x', '"\\U0010ffff": x', '"\\U00110000": x', 'dés: v']
BODIES = ["We deploy it.", "ädeploy and publishing", "run  git push now", "GIT PUSH", "gh pr create", "rm -rf /", "deploy_x", "x_deploy",
          "!`date`", "```!\nls\n```", "Kelvin: Keep", "no side effects", "publish", "Deploy", "trailing   ", "ſ git push"]
def skill_md(i):
    lines = rnd.sample(FM_KEYS, rnd.randint(0, 6))
    fm = []
    for l in lines:
        if l.endswith(": "):
            l += text() * rnd.choice([1, 1, 400])
        if rnd.random() < .2: l = l + w()
        fm.append(l)
        if rnd.random() < .15: fm.append(w() + "- continuation " + text())
    body = "\n".join(rnd.choice(BODIES) for _ in range(rnd.randint(0, 5)))
    if rnd.random() < .1: body += "\n" + "x\n" * 520
    if rnd.random() < .1: body += "y" * 21000
    top = rnd.choice(["---\n", "---\n", "---\n", "--- \n", ""])
    mid = rnd.choice(["---\n", "---  \n", "---"])
    extra = rnd.choice(["", "", "\n---\nhooks: x\n---\n"])
    s = top + "\n".join(fm) + ("\n" if fm else "") + mid + "\n" + extra + body + rnd.choice(["", "\n", "\n\n"])
    if rnd.random() < .15: s = s.replace("\n", "\r\n")
    if rnd.random() < .08: s = s.replace("\n", "\r")
    b = s.encode("utf-8", "surrogatepass")
    if rnd.random() < .1: b = b"\xef\xbb\xbf" + b
    if rnd.random() < .12:
        cut = rnd.randint(0, len(b)); b = b[:cut] + rnd.choice([b"\xe2\x82", b"\xff\xfe", b"\xc3", b"\xed\xa0\x80", b"\xf0\x9f\x8e"]) + b[cut:]
    return b
IDS = [lambda i: i, lambda i: str(i), lambda i: -i, lambda i: 1.0, lambda i: 1e2, lambda i: True, lambda i: None,
       lambda i: 2**53 + 7, lambda i: "bad id", lambda i: "", lambda i: "dup", lambda i: 9007199254740991]
CT = [lambda: "control", lambda: "edge", lambda: "boundary", lambda: "self-check", lambda: None, lambda: False, lambda: 3, lambda: [1], lambda: {"a": 1}, lambda: "Control"]
PROMPTS = [lambda: "do the thing", lambda: "/fz  run it", lambda: "/fz x\n/fz y", lambda: "", lambda: "  \x1c ", lambda: "ends\n\n\n",
           lambda: "tab\tand \"quotes\" and \\back", lambda: 5, lambda: None, lambda: "uni ünï 🎉"]
EXPS = [lambda: ["works"], lambda: ["Saves to memory", "answers"], lambda: ["MEMORY only"], lambda: [], lambda: ["", " "], lambda: [1, "x"],
        lambda: "notalist", lambda: ["line\nbreak", "ends\n"], lambda: [" "]]
def evals_json(i):
    k = rnd.random()
    if k < .04: return b'{"evals": [NaN]}'
    if k < .06: return b'{"evals": [], "x": -Infinity}'
    if k < .08: return ("{\"evals\": " + "[" * 70 + "]" * 70 + "}").encode()
    if k < .09: return ("{\"evals\": " + "[" * 2000 + "]" * 2000 + "}").encode()
    if k < .11: return b'{"evals": [{"id": 1, "prompt": "a\\ud800b", "expectations": ["x"]}]}'
    if k < .12: return b'{"evals": [{"id": 1, "prompt": "a\\u0000b", "expectations": ["x"]}]}'
    if k < .13: return ('{"evals": [{"id": ' + "9" * 150 + ', "prompt": "p", "expectations": ["x"]}]}').encode()
    if k < .14: return b'{"evals": []} trailing'
    if k < .15: return b'\xef\xbb\xbf{"evals": []}'
    if k < .16: return b'{"evals": [{"id": 1, "prompt": "\xff", "expectations": ["x"]}]}'
    if k < .17: return b'[1, 2]'
    if k < .18: return b'{"evals": {"a": 1}}'
    if k < .19: return b'{"evals": [{"id": 1, "prompt": "ok \\ud83c\\udf89", "expectations": ["x"]}]}'
    cases = []
    for j in range(rnd.randint(0, 5)):
        c = {}
        if rnd.random() < .95: c["id"] = rnd.choice(IDS)(j + 1)
        if rnd.random() < .9: c["case_type"] = rnd.choice(CT)()
        if rnd.random() < .95: c["prompt"] = rnd.choice(PROMPTS)()
        if rnd.random() < .95: c["expectations"] = rnd.choice(EXPS)()
        cases.append(c if rnd.random() < .95 else "not a case")
    return json.dumps({"evals": cases}, ensure_ascii=rnd.random() < .5).encode("utf-8")
for i in range(260):
    d = os.path.join(root, f"fz{i}")
    os.makedirs(os.path.join(d, "evals"))
    with open(os.path.join(d, "SKILL.md"), "wb") as f: f.write(skill_md(i))
    if rnd.random() < .93:
        with open(os.path.join(d, "evals", "evals.json"), "wb") as f: f.write(evals_json(i))
PY

start_server py; PY_PORT="$SERVER_PORT"
start_server go; GO_PORT="$SERVER_PORT"

python3 - "$PY_PORT" "$GO_PORT" "$PROJ/skills" "$ROOT" <<'PY'
import hashlib, json, os, shutil, subprocess, sys, time, urllib.parse, urllib.request
py, go, skills, root = sys.argv[1:5]
def post(port, path, body):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())
def get(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=30) as r:
        return json.loads(r.read())
canon = lambda v: json.dumps(v, sort_keys=True, ensure_ascii=False)
names = sorted(os.listdir(skills))
mismatch, passing = [], []
for n in names:
    d = os.path.join(skills, n)
    a, b = post(py, "/api/skill-eval/check", {"skill_dir": d}), post(go, "/api/skill-eval/check", {"skill_dir": d})
    if canon(a) != canon(b):
        ra = {c["id"]: c for c in a.get("checks", [])}; rb = {c["id"]: c for c in b.get("checks", [])}
        diff = [(k, ra.get(k), rb.get(k)) for k in sorted(set(ra) | set(rb)) if ra.get(k) != rb.get(k)]
        mismatch.append((n, diff[:2] or (a, b)))
    elif a.get("ok") and not any(c["status"] == "fail" for c in a["checks"]):
        passing.append(n)
if mismatch:
    for n, d in mismatch[:8]:
        print("CHECK MISMATCH", n, json.dumps(d, ensure_ascii=False)[:900], file=sys.stderr)
    sys.exit(f"skill-eval-parity: {len(mismatch)} of {len(names)} skills differ between server.py and the Go board")
print(f"skill-eval-parity: /check identical for {len(names)} skills ({len(passing)} pass every check)")

# Generator: plugin-eval-gen (bash + jq) vs the Go board's run (stub claude) — same tree.
if not shutil.which("jq"):
    print("skill-eval-parity: generator comparison skipped (jq absent)"); sys.exit(0)
gen_diffs, compared = [], 0
for n in passing:
    d = os.path.join(skills, n)
    rel = f".canon-cache/parity-bash/{n}"
    g = subprocess.run([os.path.join(root, "tools", "plugin-eval-gen"), "--skill-dir", d, "--plugin-dir", rel], capture_output=True, text=True)
    started = post(go, "/api/skill-eval/run", {"skill_dir": d, "confirm_cost": True, "allow_trust": True})
    if not started.get("ok"):
        gen_diffs.append((n, "run refused: " + str(started))); continue
    for _ in range(300):
        st = get(go, "/api/skill-eval/status?skill_dir=" + urllib.parse.quote(d))
        if st.get("status") != "running": break
        time.sleep(0.05)
    tag = hashlib.sha1(f"{os.path.realpath(os.path.dirname(skills))}|{d}".encode()).hexdigest()[:12]
    gdir = os.path.join(root, ".canon-cache", "skill-eval", tag)
    if g.returncode != 0:
        if st.get("status") != "error":
            gen_diffs.append((n, f"bash refused ({g.stderr.strip()[:120]}) but Go status={st.get('status')}"))
        continue
    compared += 1
    diff = subprocess.run(["diff", "-r", "-x", "last-run.json", "-x", "results", os.path.join(root, rel), gdir], capture_output=True, text=True)
    if diff.returncode != 0:
        gen_diffs.append((n, diff.stdout[:600]))
if gen_diffs:
    for n, d in gen_diffs[:6]:
        print("GEN MISMATCH", n, d, file=sys.stderr)
    sys.exit(f"skill-eval-parity: {len(gen_diffs)} generator differences")
print(f"skill-eval-parity: generated plugin identical for {compared} skills")
PY
echo "skill-eval-parity: ok"
