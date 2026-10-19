#!/usr/bin/env bash
# sprint-check-upkeep (t-1776, t-be1f): the Upkeep run path. The board's resolver (.cmd wrapper first on Windows, the bash
# script elsewhere, UPKEEP_RUN_BIN first), the persisted and bounded failed-run output and the model-id rule are Go unit
# tests in tools/sprint-check-go (TestResolveUpkeepRunBin, TestUpkeepRunBinCandidates,
# TestRunUpkeepPersistsAndSurfacesBoundedOutput, TestUpkeepModelIDCases; t-15d8). Here: the bash runner's own model check,
# and the board's /api/upkeep/run handler over HTTP.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "sprint-check-upkeep: python3/curl absent — skipped"
  exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# t-be1f: the model string reaches `claude --model`, so the bash runner refuses anything but a plain model id, before doing
# anything else. The good/bad cases live in one shared fixture (tests/fixtures/model-id-cases.json, also read by the Go test).
STUB_OK="$WORKDIR/stub-upkeep-run-ok"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/upkeep-invocations.log"\necho "UPKEEP_REPORT: /x"\nexit 0\n' "$WORKDIR" > "$STUB_OK"
chmod +x "$STUB_OK"
mkdir -p "$WORKDIR/fakebin"
printf '#!/usr/bin/env bash\necho "claude invoked: $*" >> "%s/claude-invocations.log"\nexit 0\n' "$WORKDIR" > "$WORKDIR/fakebin/claude"
chmod +x "$WORKDIR/fakebin/claude"

python3 - "$ROOT" "$WORKDIR" <<'PY'
import sys, os, json, subprocess
from pathlib import Path
root_repo, workdir = sys.argv[1], sys.argv[2]
cases = json.load(open(os.path.join(root_repo, "tests", "fixtures", "model-id-cases.json")))
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
print("sprint-check-upkeep: model id (t-be1f) ok in the bash runner")
PY

# The handlers apply the empty-model default BEFORE the rule (an empty string is not a model id but must still run),
# and a refused model is reported to the caller. The Go board, stub upkeep-run that logs its argv.
BOARD="$(build_board "$WORKDIR/bin")"
if true; then
  PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  mkdir -p "$WORKDIR/proj-http"
  : > "$WORKDIR/upkeep-invocations.log"
  UPKEEP_RUN_BIN="$STUB_OK" SPRINT_CHECK_ROOT="$WORKDIR/proj-http" CANON_HOME="$WORKDIR/canon-home" COCKPIT_STATE_DIR="$WORKDIR/state" \
    SPRINT_CHECK_NO_BROWSER=1 TMPDIR="$WORKDIR" "$BOARD" "$PORT" >/dev/null 2>&1 &
  SRV=$!
  trap 'kill "$SRV" 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/git" && break; sleep 0.1; done
  up_post() { curl -s -X POST -H 'Content-Type: application/json' -d "$1" "http://127.0.0.1:$PORT/api/upkeep/run"; }
  up_wait() { for _ in $(seq 1 100); do [[ "$(curl -s "http://127.0.0.1:$PORT/api/upkeep/status?skill=context-check" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status"))')" != "running" ]] && return 0; sleep 0.05; done; return 1; }
  body="$(up_post '{"skill":"context-check","model":""}')"; up_wait
  assert_eq True "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("ok"))' "$body")"
  assert_contains "$(cat "$WORKDIR/upkeep-invocations.log")" "--model claude-haiku-4-5-20251001"
  : > "$WORKDIR/upkeep-invocations.log"
  body="$(up_post '{"skill":"context-check"}')"; up_wait                       # model omitted: same default
  assert_contains "$(cat "$WORKDIR/upkeep-invocations.log")" "--model claude-haiku-4-5-20251001"
  : > "$WORKDIR/upkeep-invocations.log"
  body="$(up_post '{"skill":"context-check","model":"claude-sonnet-5"}')"; up_wait
  assert_contains "$(cat "$WORKDIR/upkeep-invocations.log")" "--model claude-sonnet-5"
  : > "$WORKDIR/upkeep-invocations.log"
  body="$(up_post '{"skill":"context-check","model":"--allow-tools"}')"
  assert_contains "$body" "model must be a plain model id"
  [[ ! -s "$WORKDIR/upkeep-invocations.log" ]] || fail "a refused model reached upkeep-run"
  kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true
  echo "sprint-check-upkeep: empty-model default and refusal over HTTP (t-be1f) ok"
fi

echo "sprint-check-upkeep: ok (bash runner refuses a non-plain model; the board applies the empty-model default and refuses a bad model over HTTP)"
