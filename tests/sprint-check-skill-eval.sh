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
if [ ! -e "${STUB_CTL:-/nonexistent}.no-report" ]; then
  mkdir -p evals/results/2026-01-01T00-00-00Z
  echo '<html>report</html>' > evals/results/2026-01-01T00-00-00Z/report.html
fi
echo '{"schemaVersion":1,"partial":false,"costUsd":0.1,"aggregates":{"casesTotal":3,"casesPassed":3,"overallScore":1,"meanDelta":0.5},"cases":[{"name":"good-1","arms":{"with":[{"score":1},{"score":1}],"without":[{"score":0},{"score":1}]}}]}' > "$out"
SH
chmod +x "$STUB"

# t-15d8: the function-level checks (path gate, refusals, model ids, hostile case ids, the run fuzz, argv, cost clamp,
# report containment, .reports link) are the Go board's: tests/sprint-check-skill-eval-go.sh over HTTP, and
# TestValidateSkillDirRefusesCanon, TestRunSkillEvalExitCodes, TestSkillEvalStateSaveIsSerialized and
# TestSkillEvalKeyResolvesSymlinkedRoot in tools/canon-go/internal/board. This suite keeps the HTTP gate and what only it checked.
# HTTP layer: same Host/Origin gate as every other write; the endpoint refuses escapes.
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
BOARD="$(build_board "$WORK/bin")"
# cwd = canon, so the board finds tools/sprint-check-app and the .canon-cache it writes runs into (as sprint-check-skill-eval-go.sh)
(cd "$ROOT" && exec env SPRINT_CHECK_ROOT="$PROJ" CANON_HOME="$WORK/canon-home" COCKPIT_STATE_DIR="$WORK/state" SPRINT_CHECK_NO_BROWSER=1 \
  TMPDIR="$WORK" STUB_ARGS="$ARGS" SKILL_EVAL_CLAUDE_BIN="$STUB" STUB_CTL="$WORK/ctl" "$BOARD" "$PORT") >/dev/null 2>&1 &
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
for body in '[1]' '"x"' '1'; do   # a non-object body is a 400, not a dropped connection
  assert_eq 400 "$(post -o /dev/null -w '%{http_code}' -d "$body" "$U")"
done
assert_eq false "$(post -d null "$U" | jq -r .ok)"   # `null` is an empty payload in Go (t-15d8): refused, never a run
run_body="$(post -d "{\"skill_dir\":\"$PROJ/.claude/skills/good\"}" "http://127.0.0.1:$PORT/api/skill-eval/run")"
assert_contains "$run_body" "confirm_cost"
G="$PROJ/.claude/skills/good"; H="$PROJ/.claude/skills/hooky"
st_of() { curl -s "http://127.0.0.1:$PORT/api/skill-eval/status?skill_dir=$1" | jq -r .status; }
wait_done() { for _ in $(seq 1 200); do [[ "$(st_of "$1")" != running ]] && return 0; sleep 0.05; done; fail "skill eval run did not finish"; }
runp() { post -d "$1" "http://127.0.0.1:$PORT/api/skill-eval/run"; }
GRUN="$(jq -cn --arg d "$G" '{skill_dir: $d, confirm_cost: true}')"
# Good model ids (not only the default) start a run (t-a350's allow side).
for m in claude-sonnet-5 opus 'sonnet[1m]' us.anthropic.claude-haiku-4-5-20251001-v1:0; do
  rb="$(jq -cn --arg d "$H" --arg m "$m" '{skill_dir: $d, confirm_cost: true, allow_trust: true, model: $m}')"
  assert_eq true "$(runp "$rb" | jq -r .ok)"; wait_done "$H"
  assert_contains "$(cat "$ARGS")" "--model $m"
done
# A run that produces no report must not serve the previous run's report.
assert_eq true "$(runp "$GRUN" | jq -r .ok)"; wait_done "$G"
assert_eq true "$(curl -s "http://127.0.0.1:$PORT/api/skill-eval/report?skill_dir=$G" | jq -r .ok)"
touch "$WORK/ctl.no-report"
assert_eq true "$(runp "$GRUN" | jq -r .ok)"; wait_done "$G"
rm -f "$WORK/ctl.no-report"
assert_eq '{"error":"no report yet","ok":false}' "$(curl -s "http://127.0.0.1:$PORT/api/skill-eval/report?skill_dir=$G" | jq -cS .)"
# A project-controlled state file must not crash the endpoints: hostile fixed bodies, then a seeded fuzz of nested blobs.
# Only for "fresh", a skill no run touches here, so a live run's in-memory state never hides the file (as in the board).
F="$PROJ/.claude/skills/fresh"; cp -R "$PROJ/.claude/skills/good" "$F"; SF="$PROJ/.reports/skillEvalRuns.json"; cp "$SF" "$WORK/state.keep"
python3 - "$F" "$WORK/bodies" <<'PY'
import json, random, sys
gk, out = sys.argv[1], sys.argv[2]
bodies = ["[]", '"x"', "null", "1", "{not json", json.dumps({gk: "x"}), json.dumps({gk: {"status": "done", "report_path": 123}}),
          json.dumps({gk: {"status": "done", "report_path": ["a"]}}), json.dumps({gk: {"status": 5, "summary": "s", "report_path": None}})]
random.seed(20260922)
def blob(n=0):
    return random.choice([None, 1, "x", [], {}, True, 2.5, [blob(n + 1)] if n < 3 else 0, {"a": blob(n + 1)} if n < 3 else 0, {gk: blob(n + 1)} if n < 3 else 0])
bodies += [json.dumps(blob()) for _ in range(100)]
open(out, "w").write("\n".join(b.replace("\n", " ") for b in bodies) + "\n")
PY
while IFS= read -r body; do
  printf '%s' "$body" > "$SF"
  for ep in status report; do
    r="$(curl -s -w '\n%{http_code}' "http://127.0.0.1:$PORT/api/skill-eval/$ep?skill_dir=$F")"
    assert_eq 200 "${r##*$'\n'}"; jq -e 'type == "object"' >/dev/null <<<"${r%$'\n'*}" || fail "skill-eval $ep: not a JSON object for state $body: $r"
  done
done < "$WORK/bodies"
cp "$WORK/state.keep" "$SF"
# The finished run persisted its state, so the board serves its report in a sandboxed origin.
assert_eq true "$(runp "$GRUN" | jq -r .ok)"; wait_done "$G"
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
