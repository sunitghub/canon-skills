#!/usr/bin/env bash
# sprint-check-skill-eval-go (t-b9a7) — the Go board's Skill Eval guards, over HTTP, against the
# Python board: every refusal (path escapes, symlinks and other non-regular entries, bad names,
# confirm_cost, model ids, failing checks, trust warnings, hostile case ids) must answer exactly as
# server.py does, a fuzz of wrong-typed bodies must never start a run, and the Go run path (stub
# claude, no spend) must pass the right argv, clamp the cost cap, persist state, refuse a second
# run while one is going, and serve only its own report. Needs no jq and no Python at runtime on
# the Go side; the "inside canon" refusal is covered by main_test.go.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v go >/dev/null 2>&1; then
  echo "sprint-check-skill-eval-go: python3/curl/go absent — skipped"
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
  if [[ -d "$CACHE" ]]; then
    for d in "$CACHE"/*; do [[ -e "$d" ]] || continue; grep -qxF "$(basename "$d")" <<<"$BEFORE" || rm -rf "$d"; done
  fi
  rm -rf "$WORK"
  if [[ -n "$leaked" ]]; then echo "FAIL: sprint-check-skill-eval-go left servers running (PIDs):$leaked" >&2; exit 1; fi
  return 0
}
trap cleanup EXIT

mkdir -p "$WORK/bin" "$WORK/home"
(cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)

PROJ="$WORK/proj"; OUT="$WORK/outside"; S="$PROJ/.claude/skills"
mkdir -p "$S" "$OUT"
cp -R "$ROOT/tests/fixtures/skill-check/good" "$S/good"
cp -R "$ROOT/tests/fixtures/skill-check/no-evals" "$S/no-evals"
cp -R "$ROOT/tests/fixtures/skill-check/good" "$S/hooky"
printf -- '---\nname: hooky\ndescription: Has a hook.\nhooks:\n  PreToolUse:\n    - command: echo hi\n---\nbody\n' > "$S/hooky/SKILL.md"
cp -R "$ROOT/tests/fixtures/skill-check/good" "$OUT/sneaky"
ln -s "$OUT/sneaky" "$S/escape"
cp -R "$ROOT/tests/fixtures/skill-check/good" "$S/linky"; rm "$S/linky/evals/evals.json"
ln -s "$OUT/sneaky/evals/evals.json" "$S/linky/evals/evals.json"
cp -R "$ROOT/tests/fixtures/skill-check/good" "$S/fifo"; mkfifo "$S/fifo/pipe"
cp -R "$ROOT/tests/fixtures/skill-check/good" "$S/Bad_Name"
cp -R "$ROOT/tests/fixtures/skill-check/good" "$S/hostid"
printf '{"evals":[{"id":"x/../../../../../../tmp/PWN-b9a7","case_type":"a","prompt":"p","expectations":["e"]}]}' > "$S/hostid/evals/evals.json"

# Stub claude: records argv, optionally sleeps (file-controlled, so one server serves every case), writes a
# result file and a report the way `claude plugin eval` does.
STUB="$WORK/bin/claude-stub"
cat > "$STUB" <<SH
#!/usr/bin/env bash
echo "\$@" >> "$WORK/stub-args"
sleep "\$(cat "$WORK/stub-sleep" 2>/dev/null || echo 0)"
out=""; while [ \$# -gt 0 ]; do [ "\$1" = --json ] && out="\$2"; shift; done
mkdir -p evals/results/2026-01-01T00-00-00Z && echo '<html>report</html>' > evals/results/2026-01-01T00-00-00Z/report.html
echo '{"costUsd":0.1,"aggregates":{"casesTotal":3,"casesPassed":3,"overallScore":1,"meanDelta":0.5},"cases":[{"name":"good-1","arms":{"with":[{"score":1},{"score":1}],"without":[{"score":0},{"score":1}]}}]}' > "\$out"
SH
chmod +x "$STUB"; : > "$WORK/stub-args"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
start_server() {  # <py|go> → sets SERVER_PORT; not via $(...) (t-8765)
  [[ "$BASH_SUBSHELL" == 0 ]] || { echo "FAIL: $FUNCNAME called in a subshell (t-8765)" >&2; kill -TERM "$$"; exit 1; }
  local port; port="$(free_port)"
  if [[ "$1" == py ]]; then
    HOME="$WORK/home" CANON_HOME="$WORK/home/.canon" SPRINT_CHECK_NO_BROWSER=1 SPRINT_CHECK_ROOT="$PROJ" \
      python3 "$ROOT/tools/sprint-check-app/server.py" "$port" >/dev/null 2>&1 &
  else
    (cd "$ROOT" && exec env HOME="$WORK/home" CANON_HOME="$WORK/home/.canon" SPRINT_CHECK_NO_BROWSER=1 \
      SPRINT_CHECK_ROOT="$PROJ" SKILL_EVAL_CLAUDE_BIN="$STUB" "$GO_BIN" "$port") >/dev/null 2>&1 &
  fi
  PIDS+=("$!")
  disown "$!" 2>/dev/null || true
  for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$port/api/git" && break; sleep 0.1; done
  SERVER_PORT="$port"
}
start_server py; PY_PORT="$SERVER_PORT"
start_server go; GO_PORT="$SERVER_PORT"

python3 - "$PY_PORT" "$GO_PORT" "$PROJ" "$OUT" "$WORK" "$ROOT" <<'PY'
import hashlib, json, os, random, shutil, sys, time, urllib.error, urllib.parse, urllib.request
py, go, proj, out, work, root = sys.argv[1:7]
S = os.path.join(proj, ".claude", "skills")
def call(port, method, path, body=None):
    data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)
def j(port, method, path, body=None):
    code, raw, _ = call(port, method, path, body)
    return code, (json.loads(raw) if raw[:1] in (b"{", b"[") else raw)
def same(method, path, body=None):
    a, b = j(py, method, path, body), j(go, method, path, body)
    assert a == b, f"{method} {path} {body!r}\n  python: {a}\n  go:     {b}"
    return b[1]
chk = lambda p: same("POST", "/api/skill-eval/check", {"skill_dir": p})
run = lambda p, **kw: same("POST", "/api/skill-eval/run", {"skill_dir": p, **kw})
args = lambda: open(os.path.join(work, "stub-args")).read()

# ── refusals: identical text on both boards ──
for p, want in [(os.path.join(out, "sneaky"), "skill folder must be inside the selected project"),
                (os.path.join(S, "escape"), "skill folder must be inside the selected project"),
                (proj, "skill folder must be inside the selected project"),
                (os.path.join(proj, "nope"), "skill folder not found"),
                (os.path.join(S, "good", "SKILL.md"), "not a folder"),
                (os.path.join(S, "Bad_Name"), "folder name must match [a-z0-9][a-z0-9-]*"),
                (os.path.join(S, "linky"), "skill folder contains a symbolic link (or is too large); remove it and retry"),
                (os.path.join(S, "fifo"), "skill folder contains a symbolic link (or is too large); remove it and retry")]:
    r = chk(p); assert r == {"ok": False, "error": want}, (p, r)
    r = run(p, confirm_cost=True); assert r == {"ok": False, "error": want}, (p, r)
assert chk(os.path.join(S, "good"))["ok"]
for c in (None, "true", 1, False, [True]):
    body = {"skill_dir": os.path.join(S, "good")} | ({} if c is None else {"confirm_cost": c})
    r = same("POST", "/api/skill-eval/run", body); assert r["error"].startswith("confirm_cost required"), r
for m in ("--allow-tools", "-x", "a b", "x;y", "m$(id)", "a/b", "x" * 65, "\n", "--model"):
    r = run(os.path.join(S, "hooky"), confirm_cost=True, allow_trust=True, model=m); assert "model must be" in r["error"], (m, r)
assert run(os.path.join(S, "no-evals"), confirm_cost=True)["error"] == "fix failing check(s) first: evals-present"
assert "trust-hooks" in run(os.path.join(S, "hooky"), confirm_cost=True)["error"]
r = run(os.path.join(S, "hostid"), confirm_cost=True); assert "evals-ids" in r["error"], r
assert not os.path.exists("/tmp/PWN-b9a7")
assert args() == "", "claude ran for a refused request"

# ── fuzz: wrong-typed bodies never start a run (True confirm is the one valid value, covered below) ──
random.seed(20260927)
weird = [None, 1, -1, 2**70, 1.5, "", " ", "x", "--x", "a b", "\x00", "é", [], [1], {}, {"a": 1}, "true", 0, "nan", "1e400"]
paths = [os.path.join(S, n) for n in ("good", "hooky", "hostid", "linky", "fifo")] + [os.path.join(out, "sneaky"), "", "nope", "../..", 7, None, ["x"]]
for i in range(250):
    body = {"skill_dir": random.choice(paths), "model": random.choice(weird), "allow_trust": random.choice(weird),
            "max_cost_usd": random.choice(weird), "confirm_cost": random.choice([w for w in weird if w is not True])}
    body = {k: v for k, v in body.items() if random.random() < .9}
    same("POST", "/api/skill-eval/run", body)
    code, _ = j(go, "POST", "/api/skill-eval/check", {"skill_dir": random.choice(paths)}); assert code == 200
for raw in (b"[]", b"null", b'"x"', b"{", b"\xff", b'{"skill_dir": NaN}', b'{"confirm_cost": true, "max_cost_usd": 1e400}', b"[" * 5000):
    code, r = j(go, "POST", "/api/skill-eval/run", raw)   # a bare 400, or (`null` → empty payload) a JSON refusal
    assert code == 400 or (code == 200 and r.get("ok") is False), (raw[:20], code, r)
assert args() == "", "the fuzz started a run"

# ── the Go run path (stub claude): argv, cost clamp, state, status, report ──
G = os.path.join(S, "good"); q = "?skill_dir=" + urllib.parse.quote(G)
def wait():
    for _ in range(200):
        st = j(go, "GET", "/api/skill-eval/status" + q)[1]
        if st.get("status") != "running": return st
        time.sleep(0.05)
    raise AssertionError("run did not finish")
assert j(go, "GET", "/api/skill-eval/status" + q)[1] == {"ok": True, "status": "never"}
for cap, text in [(None, "3.0"), (2.25, "2.25"), (100, "10.0"), (-5, "0.5"), (0.5, "0.5"), (10, "10.0"), ("nan", "3.0"), ("1e400", "3.0"), ("2", "2.0"), (True, "1.0")]:
    open(os.path.join(work, "stub-args"), "w").close()
    body = {"skill_dir": G, "confirm_cost": True} | ({} if cap is None else {"max_cost_usd": cap})
    started = j(go, "POST", "/api/skill-eval/run", body)[1]
    assert started["ok"] and started["status"] == "running" and float(text) == started["max_cost_usd"], (cap, started)
    st = wait(); assert st["status"] == "done", st
    a = args()
    assert f"--max-cost-usd {text} " in a and "--trust-plugin" in a and "--runs 2" in a and "--no-publish" in a, (cap, a)
    assert "--model claude-haiku-4-5-20251001" in a and "--allow-tools" not in a and "--allow-real-servers" not in a, a
st = wait()
assert st["summary"]["casesPassed"] == 3 and st["summary"]["cases"] == [{"name": "good-1", "with": 1.0, "without": 0.5}], st
rep = j(go, "GET", "/api/skill-eval/report" + q)[1]
assert rep["ok"] and rep["report_path"].endswith("report.html") and rep["summary"]["meanDelta"] == 0.5, rep
code, body, headers = call(go, "GET", "/api/skill-eval/report.html" + q)
assert code == 200 and body == b"<html>report</html>\n", (code, body)
assert headers.get("Content-Security-Policy", "").startswith("sandbox allow-scripts;") and headers.get("X-Content-Type-Options") == "nosniff", headers
state = json.load(open(os.path.join(proj, ".reports", "skillEvalRuns.json")))
assert state[G]["status"] == "done" and state[G]["model"] == "claude-haiku-4-5-20251001", state
assert run(os.path.join(S, "hooky"), confirm_cost=False)["error"].startswith("confirm_cost")
assert j(go, "POST", "/api/skill-eval/run", {"skill_dir": os.path.join(S, "hooky"), "confirm_cost": True, "allow_trust": True})[1]["ok"]  # allow_trust lets hooks through

# busy: a second run while one is going is refused and starts nothing
open(os.path.join(work, "stub-sleep"), "w").write("2")
assert j(go, "POST", "/api/skill-eval/run", {"skill_dir": G, "confirm_cost": True})[1]["ok"]
assert j(go, "POST", "/api/skill-eval/run", {"skill_dir": G, "confirm_cost": True})[1] == {"ok": False, "busy": True, "status": "running"}
wait(); open(os.path.join(work, "stub-sleep"), "w").write("0")

# a report path outside this run's own cache dir is never served (hand-edited state, another run's
# dir). "fresh" never runs, so its state comes only from the file (a live run would win, as in server.py).
F = os.path.join(S, "fresh"); shutil.copytree(os.path.join(S, "good"), F); qf = "?skill_dir=" + urllib.parse.quote(F)
other = os.path.join(root, ".canon-cache", "skill-eval", "0" * 12, "evals", "results", "x"); os.makedirs(other, exist_ok=True)
open(os.path.join(other, "report.html"), "w").write("<html>other</html>")
sf = os.path.join(proj, ".reports", "skillEvalRuns.json")
keep = json.load(open(sf))
for bad in (os.path.join(out, "sneaky", "SKILL.md"), os.path.join(other, "report.html"), "../../etc/passwd", 123, ["a"]):
    json.dump(keep | {F: {"status": "done", "summary": {}, "report_path": bad}}, open(sf, "w"))
    r = j(go, "GET", "/api/skill-eval/report" + qf)[1]
    assert r.get("ok") is False and r["error"] in ("report path outside this run's cache dir", "no report yet"), (bad, r)
    assert call(go, "GET", "/api/skill-eval/report.html" + qf)[0] == 404, bad
json.dump(keep, open(sf, "w"))
shutil.rmtree(os.path.join(root, ".canon-cache", "skill-eval", "0" * 12), ignore_errors=True)

# a project-controlled .reports link must not redirect the state write outside the project
H = os.path.join(S, "hooky")
outr = os.path.join(work, "outside-reports"); os.makedirs(outr)
shutil.rmtree(os.path.join(proj, ".reports")); os.symlink(outr, os.path.join(proj, ".reports"))
assert j(go, "POST", "/api/skill-eval/run", {"skill_dir": H, "confirm_cost": True, "allow_trust": True})[1]["ok"]
for _ in range(200):
    if j(go, "GET", "/api/skill-eval/status?skill_dir=" + urllib.parse.quote(H))[1].get("status") != "running": break
    time.sleep(0.05)
assert os.listdir(outr) == [], "state was written through a project-controlled .reports link"
os.unlink(os.path.join(proj, ".reports"))
print("sprint-check-skill-eval-go: ok (refusals match server.py; fuzz started nothing; run path, cost clamp, busy, report checked)")
PY
