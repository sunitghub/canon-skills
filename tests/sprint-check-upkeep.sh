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

echo "sprint-check-upkeep: ok (resolver prefers .cmd on Windows, bash script elsewhere, env override wins; failed-run output persisted to upkeepRuns.json AND surfaced via get_upkeep_run_state, bounded to the configured 2048-byte tail)"
