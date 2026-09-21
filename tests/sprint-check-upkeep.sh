#!/usr/bin/env bash
# sprint-check-upkeep (t-1776): upkeep-run is a bash script with no Windows-
# native entry point. subprocess.Popen on Windows calls CreateProcess
# directly on an explicit path -- unlike a bare command name, it does NOT
# PATHEXT-probe for a runnable extension, so launching the bash script
# fails outright there. Verifies _resolve_upkeep_run_bin prefers the .cmd
# wrapper on Windows, keeps the bash script everywhere else, honors the env
# override first, and that a completed run's output is persisted (bounded)
# into upkeepRuns.json -- the gap that made this bug harder to diagnose live.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "sprint-check-upkeep: python3 absent — skipped"
  exit 0
fi

python3 - "$ROOT" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "tools", "sprint-check-app"))
import server

nt = server._resolve_upkeep_run_bin("nt")
assert str(nt).endswith(os.path.join("tools", "upkeep-run.cmd")), f"nt resolver did not prefer .cmd: {nt}"

posix = server._resolve_upkeep_run_bin("posix")
assert str(posix).endswith(os.path.join("tools", "upkeep-run")), f"posix resolver: {posix}"
assert not str(posix).endswith("upkeep-run.cmd"), f"posix must not pick .cmd: {posix}"

os.environ["UPKEEP_RUN_BIN"] = "/tmp/stub-upkeep-run"
try:
    got = str(server._resolve_upkeep_run_bin("nt"))
    assert got == "/tmp/stub-upkeep-run", f"env override must win on nt: {got}"
    got = str(server._resolve_upkeep_run_bin("posix"))
    assert got == "/tmp/stub-upkeep-run", f"env override must win on posix: {got}"
finally:
    del os.environ["UPKEEP_RUN_BIN"]

print("sprint-check-upkeep: resolver (t-1776) ok")
PY

# Live run against a stub upkeep-run binary: confirm a completed run's
# output is actually persisted to upkeepRuns.json, bounded to the configured
# tail length — the exact gap that made this session's own diagnosis harder
# than it needed to be (the daemon's own in-memory output was never saved).
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
STUB="$WORKDIR/stub-upkeep-run"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
printf 'Error: something went wrong in the fake skill run\n'
exit 1
SH
chmod +x "$STUB"

python3 - "$ROOT" "$WORKDIR" "$STUB" <<'PY'
import sys, os, json, time
root_repo, workdir, stub = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(root_repo, "tools", "sprint-check-app"))
os.environ["UPKEEP_RUN_BIN"] = stub
import importlib
import server
importlib.reload(server)  # UPKEEP_RUN_BIN is resolved at import time

from pathlib import Path
proj_root = Path(workdir) / "proj"
proj_root.mkdir()
server._run_upkeep(proj_root, "context-check", "claude-haiku-4-5-20251001")

state_path = proj_root / ".reports" / "upkeepRuns.json"
assert state_path.exists(), "upkeepRuns.json was not written"
state = json.loads(state_path.read_text())
entry = state.get("context-check")
assert entry is not None, f"no context-check entry: {state}"
assert entry.get("status") == "error", f"expected status error: {entry}"
assert "something went wrong" in entry.get("output", ""), f"output field missing/wrong: {entry}"

# get_upkeep_run_state must surface the field too — the whole point of
# persisting it is a dashboard API caller can see WHY a run failed, not just
# someone opening upkeepRuns.json by hand (t-1776 reviewer finding).
api_state = server.get_upkeep_run_state(proj_root, "context-check")
assert "something went wrong" in api_state.get("output", ""), f"get_upkeep_run_state dropped output: {api_state}"
print("sprint-check-upkeep: output persistence (t-1776) ok")
PY

# Truncation boundary: output longer than the 2048-byte cap must actually be
# bounded, not just present — a short-string round-trip alone can't tell the
# two apart (reviewer nitpick).
STUB_LONG="$WORKDIR/stub-upkeep-run-long"
cat > "$STUB_LONG" <<'SH'
#!/usr/bin/env bash
python3 -c "print('X' * 5000, end='')"
exit 1
SH
chmod +x "$STUB_LONG"

python3 - "$ROOT" "$WORKDIR" "$STUB_LONG" <<'PY'
import sys, os, json
root_repo, workdir, stub = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(root_repo, "tools", "sprint-check-app"))
os.environ["UPKEEP_RUN_BIN"] = stub
import importlib
import server
importlib.reload(server)

from pathlib import Path
proj_root = Path(workdir) / "proj-long"
proj_root.mkdir()
server._run_upkeep(proj_root, "context-check", "claude-haiku-4-5-20251001")

state = json.loads((proj_root / ".reports" / "upkeepRuns.json").read_text())
persisted_output = state["context-check"]["output"]
assert len(persisted_output) == 2048, f"persisted output not bounded to 2048 bytes: {len(persisted_output)}"

api_state = server.get_upkeep_run_state(proj_root, "context-check")
assert len(api_state["output"]) == 2048, f"API-returned output not bounded to 2048 bytes: {len(api_state['output'])}"
print("sprint-check-upkeep: truncation boundary (t-1776) ok")
PY

# t-be1f: the model string reaches `claude --model`, so all three implementations (bash runner, Python
# server, Go server) refuse anything but a plain model id. The good/bad cases live in one shared fixture.
STUB_OK="$WORKDIR/stub-upkeep-run-ok"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/upkeep-invocations.log"\necho "UPKEEP_REPORT: /x"\nexit 0\n' "$WORKDIR" > "$STUB_OK"
chmod +x "$STUB_OK"
mkdir -p "$WORKDIR/fakebin"
printf '#!/usr/bin/env bash\necho "claude invoked: $*" >> "%s/claude-invocations.log"\nexit 0\n' "$WORKDIR" > "$WORKDIR/fakebin/claude"
chmod +x "$WORKDIR/fakebin/claude"

python3 - "$ROOT" "$WORKDIR" "$STUB_OK" <<'PY'
import sys, os, json, time, random, subprocess
from pathlib import Path
root_repo, workdir, stub = sys.argv[1], sys.argv[2], sys.argv[3]
cases = json.load(open(os.path.join(root_repo, "tests", "fixtures", "model-id-cases.json")))
sys.path.insert(0, os.path.join(root_repo, "tools", "sprint-check-app"))
import server
server.UPKEEP_RUN_BIN = stub
proj = Path(workdir) / "proj-model"; proj.mkdir()
log = Path(workdir) / "upkeep-invocations.log"

# Python server: bad models are refused with a model error and never start a job.
for m in cases["bad"]:
    r = server.start_upkeep_run(proj, "context-check", m)
    assert r.get("ok") is False and "model" in r.get("error", ""), (m, r)
assert not log.exists() and not server._UPKEEP_RUNS, "a refused model started an upkeep job"
# Good models still start (the stub prints a report path and exits 0).
for m in cases["good"][:3] + ["sonnet[1m]"]:
    r = server.start_upkeep_run(proj, "context-check", m)
    assert r.get("ok") is True, (m, r)
    for _ in range(100):
        if server.get_upkeep_run_state(proj, "context-check").get("status") != "running": break
        time.sleep(0.05)
# Seeded fuzz: hostile strings built from parts that can never be a legitimate id are always refused.
random.seed(20260922)
# A dash is only hostile as the FIRST character (ok-tail is a valid id), everything else below is never valid anywhere.
bad_chars = [" ", ";", "$(", "`", "|", "&", "\n", "\r", "\t", "'", '"', "\\", "/", "é", "*", "="]
before = log.read_text() if log.exists() else ""
for _ in range(300):
    if random.random() < 0.3:
        m = random.choice(["-", "--"]) + random.choice(["", "tail", "x y"])
    else:
        m = random.choice(["", "ok", "x" * 5]) + random.choice(bad_chars) + random.choice(["", "tail"])
    r = server.start_upkeep_run(proj, "context-check", m)
    assert r.get("ok") is False and "model" in r.get("error", ""), (m, r)
assert (log.read_text() if log.exists() else "") == before, "fuzz started an upkeep job"

# Bash runner: refuses before doing anything else (a missing root would otherwise be the first error), and never runs claude.
env = dict(os.environ, PATH=os.path.join(workdir, "fakebin") + os.pathsep + os.environ["PATH"])
run = lambda m: subprocess.run([os.path.join(root_repo, "tools", "upkeep-run"), "context-check", "--root", "/nonexistent-t-be1f", "--model", m],
                               env=env, capture_output=True, text=True)
for m in cases["bad"]:
    r = run(m)
    assert r.returncode == 1 and "--model" in r.stderr and "does not exist" not in r.stderr, (m, r.returncode, r.stderr)
for m in cases["good"]:
    r = run(m)
    assert r.returncode == 1 and "does not exist" in r.stderr, (m, r.returncode, r.stderr)   # got past the model check
assert not (Path(workdir) / "claude-invocations.log").exists(), "claude was invoked"
print("sprint-check-upkeep: model id (t-be1f) ok in python and bash")
PY

echo "sprint-check-upkeep: ok (resolver prefers .cmd on Windows, bash script elsewhere, env override wins; failed-run output persisted to upkeepRuns.json AND surfaced via get_upkeep_run_state, bounded to the configured 2048-byte tail)"
