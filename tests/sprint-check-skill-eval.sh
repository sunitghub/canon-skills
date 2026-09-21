#!/usr/bin/env bash
# sprint-check-skill-eval (t-23d8): the Skill Eval backend runs a user-picked skill
# folder through skill-check and `claude plugin eval`. Path escapes, canon's own
# skills, missing cost confirmation, failing checks and trust warnings must all be
# refused server-side; the run itself is wired against a stub `claude` (no spend).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "sprint-check-skill-eval: python3/jq/curl absent — skipped"
  exit 0
fi

WORK="$(mktemp -d)"
CACHE="$ROOT/.canon-cache/skill-eval"
BEFORE="$(ls "$CACHE" 2>/dev/null || true)"
PID=""
cleanup() {
  if [[ -n "$PID" ]]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  # Remove only the per-run dirs this test created, never a developer's real runs.
  if [[ -d "$CACHE" ]]; then
    for d in "$CACHE"/*; do
      [[ -e "$d" ]] || continue
      grep -qxF "$(basename "$d")" <<<"$BEFORE" || rm -rf "$d"
    done
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Project with a good skill, a no-evals skill, a hooks skill (valid frontmatter, trust warn),
# an outside skill, and a symlink inside the project pointing at that outside skill.
PROJ="$WORK/proj"; OUT="$WORK/outside"
mkdir -p "$PROJ/.claude/skills" "$OUT"
cp -R "$ROOT/tests/fixtures/skill-check/good" "$PROJ/.claude/skills/good"
cp -R "$ROOT/tests/fixtures/skill-check/no-evals" "$PROJ/.claude/skills/no-evals"
cp -R "$ROOT/tests/fixtures/skill-check/good" "$PROJ/.claude/skills/hooky"
printf -- '---\nname: hooky\ndescription: Has a hook.\nhooks:\n  PreToolUse:\n    - command: echo hi\n---\nbody\n' > "$PROJ/.claude/skills/hooky/SKILL.md"
cp -R "$ROOT/tests/fixtures/skill-check/good" "$OUT/sneaky"
ln -s "$OUT/sneaky" "$PROJ/.claude/skills/escape"

STUB="$WORK/stub-claude"; ARGS="$WORK/stub-args"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
echo "$@" > "$STUB_ARGS"
sleep "${STUB_SLEEP:-0}"
while [ $# -gt 0 ]; do [ "$1" = "--json" ] && out="$2"; shift; done
if [ -z "${NO_REPORT:-}" ]; then
  mkdir -p evals/results/2026-01-01T00-00-00Z
  echo '<html>report</html>' > evals/results/2026-01-01T00-00-00Z/report.html
fi
echo '{"schemaVersion":1,"partial":false,"costUsd":0.1,"aggregates":{"casesTotal":3,"casesPassed":3,"overallScore":1,"meanDelta":0.5},"cases":[{"name":"good-1","arms":{"with":[{"score":1},{"score":1}],"without":[{"score":0},{"score":1}]}}]}' > "$out"
SH
chmod +x "$STUB"

STUB_ARGS="$ARGS" SKILL_EVAL_CLAUDE_BIN="$STUB" python3 - "$ROOT" "$PROJ" "$OUT" <<'PY'
import json, os, shutil, sys, time
from pathlib import Path
sys.path.insert(0, os.path.join(sys.argv[1], "tools", "sprint-check-app"))
import server
root, proj, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
skills = proj / ".claude" / "skills"

def err(raw, project=proj):
    return server.validate_skill_dir(project, str(raw))[1]

# Path gate: accepted inside the project; every escape refused.
assert err(skills / "good") is None
assert err(out / "sneaky") == "skill folder must be inside the selected project", err(out / "sneaky")
assert err(skills / "escape") == "skill folder must be inside the selected project"   # symlink resolves outside
assert err(proj / "nope") == "skill folder not found"
assert err(skills / "good" / "SKILL.md") == "not a folder"
assert err(proj) == "skill folder must be inside the selected project"                  # the root itself
assert "canon's own skills" in err(root / "skills" / "capture", root.parent)          # project containing canon
bad = skills / "Bad_Name"; bad.mkdir()
assert err(bad) == "folder name must match [a-z0-9][a-z0-9-]*"

# Check endpoint: ok + JSON for a good skill; a fail check still returns ok (the UI shows it).
r = server.skill_eval_check(proj, str(skills / "good"))
assert r["ok"] and r["skill"] == "good" and r["checks"], r
r = server.skill_eval_check(proj, str(skills / "no-evals"))
assert r["ok"] and any(c["id"] == "evals-present" and c["status"] == "fail" for c in r["checks"]), r
assert not server.skill_eval_check(proj, str(out / "sneaky"))["ok"]

# Run refusals: no cost confirmation, failing check, trust warning without allow_trust, escapes.
run = lambda d, **kw: server.start_skill_eval_run(proj, str(d), "", kw.get("confirm", True), kw.get("trust"), 3.0)
assert "confirm_cost" in run(skills / "good", confirm=None)["error"]
assert "confirm_cost" in run(skills / "good", confirm="true")["error"]                 # truthy string is not True
assert "evals-present" in run(skills / "no-evals")["error"]
assert "trust-hooks" in run(skills / "hooky")["error"]
assert not run(skills / "escape")["ok"] and not run(out / "sneaky")["ok"]
assert not server._SKILL_EVAL_RUNS, "a refused run must not start a job"

# Happy path against the stub claude: async run, read-only tools, report + summary served.
def wait(d):
    for _ in range(100):
        st = server.get_skill_eval_state(proj, str(d))
        if st.get("status") not in ("running",):
            return st
        time.sleep(0.1)
    raise AssertionError("run did not finish")
started = run(skills / "good")
assert started["ok"] and started["status"] == "running", started
st = wait(skills / "good")
assert st["status"] == "done" and st["summary"]["casesPassed"] == 3, st
rep = server.get_skill_eval_report(proj, str(skills / "good"))
assert rep["ok"] and rep["report_path"].endswith("report.html") and rep["summary"]["meanDelta"] == 0.5, rep
args = Path(os.environ["STUB_ARGS"]).read_text()
assert rep["summary"]["cases"] == [{"name": "good-1", "with": 1.0, "without": 0.5}], rep["summary"]
assert "--trust-plugin" in args and "--max-cost-usd 3.0" in args and "--runs 2" in args, args
assert "--allow-tools" not in args and "--allow-real-servers" not in args, args
assert (proj / ".reports" / "skillEvalRuns.json").is_file(), "run state was not persisted"

# allow_trust lets the hooks skill through (stage 1/2 has no fail for it).
assert run(skills / "hooky", trust=True)["ok"]
wait(skills / "hooky")

# A report path that round-tripped through state but sits outside the cache is refused.
server._SKILL_EVAL_RUNS[server._skill_eval_key(proj, (skills / "good").resolve())]["report_path"] = "/etc/hosts"
assert "outside this run's cache dir" in server.get_skill_eval_report(proj, str(skills / "good"))["error"]
# ...and so is a real report belonging to a different run (another tag dir under the same cache).
other = server.SKILL_EVAL_CACHE / "0123456789ab" / "evals" / "results" / "x"
other.mkdir(parents=True, exist_ok=True); (other / "report.html").write_text("<html>other</html>")
server._SKILL_EVAL_RUNS[server._skill_eval_key(proj, (skills / "good").resolve())]["report_path"] = str(other / "report.html")
assert "outside this run's cache dir" in server.get_skill_eval_report(proj, str(skills / "good"))["error"]
import shutil; shutil.rmtree(server.SKILL_EVAL_CACHE / "0123456789ab")

# A link inside the picked folder refuses it everywhere (it could pull outside files into eval prompts).
lk = skills / "linky"; lk.mkdir(); (lk / "SKILL.md").write_text((skills / "good" / "SKILL.md").read_text())
(lk / "evals").mkdir(); (lk / "evals" / "evals.json").symlink_to(out / "sneaky" / "evals" / "evals.json")
assert "symbolic link" in err(lk), err(lk)
assert not server.skill_eval_check(proj, str(lk))["ok"]
assert not run(lk)["ok"]

# t-a350: the model string reaches the claude argv, so only plain model ids are accepted.
server._SKILL_EVAL_RUNS.clear()
Path(os.environ["STUB_ARGS"]).write_text("")
for bad in ("--allow-tools", "-x", "a b", "x;y", "m$(id)", "a/b", "x" * 65, "\n", "--model"):
    r = server.start_skill_eval_run(proj, str(skills / "hooky"), bad, True, True, 3.0)
    assert not r["ok"] and "model" in r["error"], (bad, r)
assert not server._SKILL_EVAL_RUNS, "a refused model must not start a job"
assert Path(os.environ["STUB_ARGS"]).read_text() == "", "claude was invoked for a refused model"
for good in ("", "claude-sonnet-5", "claude-haiku-4-5-20251001", "opus", "sonnet[1m]", "us.anthropic.claude-haiku-4-5-20251001-v1:0"):
    assert server.start_skill_eval_run(proj, str(skills / "hooky"), good, True, True, 3.0)["ok"], good
    wait(skills / "hooky")

# A hostile case id fails the check, so the run is refused before any file is generated.
hid = skills / "hostid"; (hid / "evals").mkdir(parents=True); (hid / "SKILL.md").write_text((skills / "good" / "SKILL.md").read_text())
(hid / "evals" / "evals.json").write_text('{"evals":[{"id":"x/../../../../../../tmp/PWN-a350","case_type":"a","prompt":"p","expectations":["e"]}]}')
r = run(hid); assert not r["ok"] and "evals-ids" in r["error"], r
assert not Path("/tmp/PWN-a350").exists()

# Seeded fuzz of the run entry point: hostile argument types never raise and never start a job.
import random
random.seed(20260921)
weird = [None, 1, -1, 2**70, 1.5, float("nan"), float("inf"), "", " ", "x", "--x", "a b", "\x00", "é", [], [1], {}, {"a": 1}, "true", 0]
paths = [skills / "good", skills / "hooky", skills / "hostid", skills / "linky", out / "sneaky", "", "nope", "../..", "\x00"]
before = dict(server._SKILL_EVAL_RUNS)
for i in range(300):
    model, cap, allow = str(random.choice(weird)), random.choice(weird), random.choice(weird)
    confirm = random.choice([w for w in weird if w is not True])          # True is the one valid value, covered above
    try:
        r = server.start_skill_eval_run(proj, str(random.choice(paths)), model, confirm, allow, cap)
    except Exception as e:                                                # noqa: BLE001 — the point of the fuzz
        raise AssertionError(f"start_skill_eval_run raised {e!r} for {(model, cap, allow, confirm)!r}")
    assert isinstance(r, dict) and r.get("ok") is False, r
assert server._SKILL_EVAL_RUNS == before, "the fuzz started a job"
# With confirm_cost True the model check is the guard that must fire: hostile models built from parts
# that can never be legitimate (leading dash, whitespace, shell or control characters) are always refused.
for i in range(200):
    m = random.choice(["-", "--", "-x", "a ", " a", "a;b", "a$(x)", "a`b`", "a|b", "a&b", "a\x00", "a\n", "a\r", "a\t", "é", "a'b", 'a"b'])
    m = random.choice(["", "ok", "x" * 5]) + m if not m.startswith("-") else m
    r = server.start_skill_eval_run(proj, str(skills / "hooky"), m, True, True, 3.0)
    assert r.get("ok") is False and "model" in r["error"], (m, r)
assert server._SKILL_EVAL_RUNS == before, "a refused model started a job"
print("sprint-check-skill-eval: run fuzz ok")

# The busy guard is keyed by the resolved project root: a symlinked spelling cannot start a second run.
G = skills / "good"
link = proj.parent / "projlink"; link.symlink_to(proj)
os.environ["STUB_SLEEP"] = "2"
a = server.start_skill_eval_run(proj, str(G), "", True, False, 3.0)
b = server.start_skill_eval_run(link, str(G), "", True, False, 3.0)
assert a["ok"] and b.get("busy") is True, (a, b)
wait(G); os.environ["STUB_SLEEP"] = "0"; link.unlink()

# A run that produces no report must not serve the previous run's report.
assert server.get_skill_eval_report(proj, str(G))["ok"]
os.environ["NO_REPORT"] = "1"
assert server.start_skill_eval_run(proj, str(G), "", True, False, 3.0)["ok"]; wait(G)
del os.environ["NO_REPORT"]
assert server.get_skill_eval_report(proj, str(G)) == {"ok": False, "error": "no report yet"}, server.get_skill_eval_report(proj, str(G))

# A project-controlled state file (or .reports link) must not crash the endpoints or redirect a write.
sf = server._skill_eval_state_path(proj); gk = str(G.resolve())
bodies = ["[]", '"x"', "null", "1", "{not json", json.dumps({gk: "x"}), json.dumps({gk: {"status": "done", "report_path": 123}}),
          json.dumps({gk: {"status": "done", "report_path": ["a"]}}), json.dumps({gk: {"status": 5, "summary": "s", "report_path": None}})]
random.seed(20260922)
def blob(n=0):
    return random.choice([None, 1, "x", [], {}, True, 2.5, [blob(n + 1)] if n < 3 else 0, {"a": blob(n + 1)} if n < 3 else 0, {gk: blob(n + 1)} if n < 3 else 0])
bodies += [json.dumps(blob()) for _ in range(100)]
for body in bodies:
    sf.write_text(body); server._SKILL_EVAL_RUNS.clear()
    for fn in (server.get_skill_eval_state, server.get_skill_eval_report):
        r = fn(proj, str(G)); assert isinstance(r, dict), (body, r)
shutil.rmtree(proj / ".reports", ignore_errors=True)
outr = proj.parent / "outside-reports"; outr.mkdir(exist_ok=True); (proj / ".reports").symlink_to(outr)
assert server.start_skill_eval_run(proj, str(G), "", True, False, 3.0)["ok"]; wait(G)
assert not any(outr.iterdir()), "state was written through a project-controlled .reports link"
(proj / ".reports").unlink()
assert server.start_skill_eval_run(proj, str(G), "", True, False, 3.0)["ok"]; wait(G)   # leave a good persisted run for the HTTP layer below

# A huge integer cost cap must fall back like any other bad number.
assert server.start_skill_eval_run(proj, str(skills / "hooky"), "", True, True, 10**400)["max_cost_usd"] == 3.0
wait(skills / "hooky")

# A non-finite cost cap must fall back to the default, never reach claude as 'nan'/'inf'.
for cap in (float("nan"), float("inf"), "nan", None):
    assert server.start_skill_eval_run(proj, str(skills / "hooky"), "", True, True, cap)["max_cost_usd"] == 3.0, cap
    wait(skills / "hooky")
assert "--max-cost-usd 3.0" in Path(os.environ["STUB_ARGS"]).read_text()
assert server.start_skill_eval_run(proj, str(skills / "hooky"), "", True, True, 99)["max_cost_usd"] == 10.0
wait(skills / "hooky")
print("sprint-check-skill-eval: functions ok")
PY

# HTTP layer: same Host/Origin gate as every other write; the endpoint refuses escapes.
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
SPRINT_CHECK_ROOT="$PROJ" python3 "$ROOT/tools/sprint-check-app/server.py" "$PORT" >/dev/null 2>&1 &
PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/git" && break; sleep 0.1; done
post() { curl -s -X POST -H 'Content-Type: application/json' "$@"; }
U="http://127.0.0.1:$PORT/api/skill-eval/check"

body="$(post -d "{\"skill_dir\":\"$PROJ/.claude/skills/good\"}" "$U")"
assert_eq true "$(jq -r .ok <<<"$body")"
body="$(post -d "{\"skill_dir\":\"$OUT/sneaky\"}" "$U")"
assert_eq false "$(jq -r .ok <<<"$body")"
assert_eq 403 "$(post -o /dev/null -w '%{http_code}' -H 'Origin: http://evil.example' -d '{}' "$U")"
assert_eq 403 "$(post -o /dev/null -w '%{http_code}' -H 'Host: evil.example' -d '{}' "$U")"
assert_eq 400 "$(post -o /dev/null -w '%{http_code}' -d '{}' "$U?project=nope")"
for body in '[1]' '"x"' 'null' '1'; do   # every POST route reads payload.get: a non-object body is a 400, not a dropped connection
  assert_eq 400 "$(post -o /dev/null -w '%{http_code}' -d "$body" "$U")"
done
run_body="$(post -d "{\"skill_dir\":\"$PROJ/.claude/skills/good\"}" "http://127.0.0.1:$PORT/api/skill-eval/run")"
assert_contains "$run_body" "confirm_cost"
# The finished run above persisted its state, so a fresh server serves its report in a sandboxed origin.
G="$PROJ/.claude/skills/good"
assert_eq "done" "$(curl -s "http://127.0.0.1:$PORT/api/skill-eval/status?skill_dir=$G" | jq -r .status)"
hdrs="$(curl -s -D - -o "$WORK/report.out" "http://127.0.0.1:$PORT/api/skill-eval/report.html?skill_dir=$G")"
assert_contains "$hdrs" "200"
assert_contains "$hdrs" "text/html"
assert_contains "$hdrs" "sandbox allow-scripts"
assert_contains "$(cat "$WORK/report.out")" "<html>report</html>"
assert_eq 404 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/skill-eval/report.html?skill_dir=$PROJ/.claude/skills/no-evals")"
assert_eq 404 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/skill-eval/report.html?skill_dir=$OUT/sneaky")"
status="$(curl -s "http://127.0.0.1:$PORT/api/skill-eval/status?skill_dir=$OUT/sneaky")"
assert_eq false "$(jq -r .ok <<<"$status")"

echo "sprint-check-skill-eval: ok"
