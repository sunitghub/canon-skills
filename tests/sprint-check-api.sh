#!/usr/bin/env bash
# sprint-check-api — the Go board's HTTP API against one fixture project (t-15d8: was sprint-check-api-parity.sh, which
# compared the Python board with main.go; with one board left every check is an absolute assertion on it). Pins the
# /api/ route set, /api/tickets fields, ticket-image/-feature serving and traversal refusal, /visual uploads, headless-run
# dispatch, ticket create/demo/ci-workflow writes, worktrees, cockpit-docs, cockpit stale detection, version, the
# project registry and scoped reads/writes, register-skill, model tiers and /static/.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

MAIN_GO="$ROOT/tools/canon-go/internal/board/main.go"

# The /api/ route set, read from main.go's dispatch:
#   exact:  case "/api/foo":  or  path == "/api/foo"
#   regex:  `^/api/foo/
go_routes() {
  {
    grep -oE 'case "/api/[^"]+"' "$MAIN_GO" | sed 's/case "//;s/"$//' || true
    grep -oE 'path == "/api/[^"]+"' "$MAIN_GO" | sed 's/path == "//;s/"$//' || true
    grep -oE '`\^/api/[^`/()\$\\]+' "$MAIN_GO" | sed 's/`\^//' || true
  } | sed 's|/$||' | sort -u
}
# The pinned set: a route that disappears (or appears) changes what the board and the Cockpit can call, so it must
# be an edit here too, never a silent change.
want_routes="/api/admin/model-tiers /api/admin/model-tiers/apply /api/admin/model-tiers/refresh /api/admin/model-tiers/remove /api/admin/model-tiers/retire /api/browse-dirs /api/ci-workflow /api/cockpit /api/cockpit-changes /api/cockpit-debug
/api/cockpit-docs /api/cockpit-interrupted /api/cockpit-interrupted-dismiss /api/cockpit-restart /api/cockpit-sessions
/api/cockpit-status /api/cockpit-stop /api/commit /api/doc /api/git /api/github/doctor /api/github/intake /api/github/push-main /api/github/sync
/api/github/sync-preview /api/handoff /api/project-stats /api/projects /api/register-skill /api/skill-eval/check
/api/skill-eval/report /api/skill-eval/report.html /api/skill-eval/run /api/skill-eval/status /api/themes /api/themes/open
/api/ticket /api/ticket-feature /api/ticket-image /api/tickets /api/track-changes
/api/version /api/why /api/worktree-lock /api/worktree-unlock /api/worktrees"
go="$(go_routes)"
[[ "$go" == "$(printf '%s\n' $want_routes)" ]] || fail "sprint-check-api: the /api/ route set changed:
$(diff <(printf '%s\n' $want_routes) <(printf '%s\n' "$go") || true)"

# t-d271: the per-ticket GitHub routes are regexes, which the extractor above collapses to /api/ticket: pin their
# sub-route names.
gh_subroutes() { grep -oE "github/\((send|import|merge|take-back|send-preview|merge-check)[a-z|-]*\)" "$1" | tr '()|' '\n\n\n' | grep -v '^github/$' | grep . | sort -u; }
assert_eq "import land merge merge-check merge-stop open-pr send send-preview status take-back" "$(gh_subroutes "$MAIN_GO" | tr '\n' ' ' | sed 's/ $//')"

route_count="$(echo "$go" | wc -l | tr -d ' ')"

command -v curl >/dev/null 2>&1 || fail "sprint-check-api: curl is required"
command -v python3 >/dev/null 2>&1 || fail "sprint-check-api: python3 is required (test-only JSON parsing and stub daemons)"

WORK="$(mktemp -d)"
BOARD_DIR="$(mktemp -d)"
# t-74d6: a controlled cockpit state dir + fake on-disk daemon binary so the stale-detection case is deterministic
# (independent of any real daemon the dev machine may have running in the default /tmp/canon-cockpit-board).
CK_STATE="$(mktemp -d)"
CK_BIN="$(mktemp)"
CK_STUB_PID=""
GO_PID=""
SGO_PID=""; SAPP=""   # t-9b2d: the /static/ board, on a temp copy of the app folder
# SPRINT_HEADLESS_BIN/SPRINT_HEADLESS_EVAL_BIN point the board at throwaway temp stubs from the moment it starts
# (t-1781) — the headless-run section below only ever rewrites these temp files' *content*, never the real
# tools/sprint-headless(-eval).
SPRINT_HEADLESS_BIN="$(mktemp)"
SPRINT_HEADLESS_EVAL_BIN="$(mktemp)"
chmod +x "$SPRINT_HEADLESS_BIN" "$SPRINT_HEADLESS_EVAL_BIN"
export SPRINT_HEADLESS_BIN SPRINT_HEADLESS_EVAL_BIN
# t-7485: hermetic stub for `skills.sh add sprint <dir>` so the register-skill endpoint's argv shell-out is exercised
# WITHOUT running the real onboarding (which would write a git hook + touch ~/.config/canon). The stub only
# appends/upserts the AGENTS.md AI-SKILLS row, idempotently.
SKILLS_SH_BIN="$WORK/stub-skills.sh"
ASSUME_YES_LOG="$WORK/assume-yes.log"
export ASSUME_YES_LOG
cat > "$SKILLS_SH_BIN" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# t-b47a: record whether the caller set SKILLS_SH_ASSUME_YES, so the
# register-skill block below can assert the board passes it to every
# invocation (the actual auto-yes prompt behavior is covered by
# tests/skills-assume-yes.sh against the real skills.sh — this just proves
# the board threads the flag through).
echo "${SKILLS_SH_ASSUME_YES:-<unset>}" >> "$ASSUME_YES_LOG"
[ "${1:-}" = "add" ] || exit 0
skill="${2:-sprint}"; dir="${3:-$PWD}"; af="$dir/AGENTS.md"
grep -q "^| $skill " "$af" 2>/dev/null && exit 0    # idempotent: row already present
if grep -q "AI-SKILLS:BEGIN" "$af" 2>/dev/null; then
  tmp="$(mktemp)"; awk -v r="| $skill | dev | /x/skills/$skill/SKILL.md |" '/AI-SKILLS:END/{print r} {print}' "$af" > "$tmp" && mv "$tmp" "$af"
else
  printf '<!-- AI-SKILLS:BEGIN -->\n## Active canon skills\n\n| Skill | Category | Source |\n|-------|----------|--------|\n| %s | dev | /x/skills/%s/SKILL.md |\n<!-- AI-SKILLS:END -->\n' "$skill" "$skill" >> "$af"
fi
STUB
chmod +x "$SKILLS_SH_BIN"
export SKILLS_SH_BIN
cleanup() {
  [[ -n "$GO_PID" ]] && kill "$GO_PID" 2>/dev/null || true
  [[ -n "$CK_STUB_PID" ]] && kill "$CK_STUB_PID" 2>/dev/null || true
  [[ -n "$SGO_PID" ]] && kill "$SGO_PID" 2>/dev/null || true
  rm -f "$SPRINT_HEADLESS_BIN" "$SPRINT_HEADLESS_EVAL_BIN" "$CK_BIN"
  rm -rf "$WORK" "$BOARD_DIR" "$CK_STATE"
  [[ -n "$SAPP" ]] && rm -rf "$SAPP"
}
trap cleanup EXIT

build_tickets_fixture "$WORK"

# Real git history so /api/git's total_commits check (below) exercises
# the actual git rev-list path.
(cd "$WORK" && git init -q && git config user.email "t@t.com" && git config user.name "t" \
  && git commit -q --allow-empty -m "first" && git commit -q --allow-empty -m "second")

# Dedicated fixture for models_used (t-a19e) — not added to the shared
# build_tickets_fixture helper since other tests assert against its exact
# ticket set/content; a standalone ticket here keeps this check isolated.
mkdir -p "$WORK/.tickets/t-model"
cat > "$WORK/.tickets/t-model/ticket.md" <<'EOF'
---
id: t-model
status: open
type: task
priority: 2
created: 2026-06-08T00:00:00Z
---
# Model mention fixture
EOF
# t-1f22: the gate reports list under their writer's name on both servers (display-only; the file field is unchanged).
printf '# Eval Report\n' > "$WORK/.tickets/t-model/eval-report.md"
printf '# Review Notes\n' > "$WORK/.tickets/t-model/review-notes.md"
printf '# GitHub\n\n## 2026-10-22T00:00:00Z — sent\nissue: https://github.com/acme/app/issues/1\n' > "$WORK/.tickets/t-model/github.md"   # t-1dec
cat > "$WORK/.tickets/t-model/acceptance.md" <<'EOF'
# Acceptance

## Criteria
- [x] Has criteria
- [x] Mentions the convention itself, e.g. `(model: <model>)`, in prose — not a real usage (t-1720 false-positive regression)

## Test Plan
- [x] Has tests

## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| reviewer | ran | verdict: YES (model: claude-sonnet-5) |
| eval | ran | verdict: pass (model: HAIKU) |
EOF

# Dedicated fixture for ci: true/false (t-978c) — asserted on /api/tickets below.
mkdir -p "$WORK/.tickets/t-cion" "$WORK/.tickets/t-cioff"
cat > "$WORK/.tickets/t-cion/ticket.md" <<'EOF'
---
id: t-cion
status: open
type: task
priority: 2
created: 2026-06-08T00:00:00Z
ci: true
---
# CI-eligible fixture
EOF
cat > "$WORK/.tickets/t-cioff/ticket.md" <<'EOF'
---
id: t-cioff
status: open
type: task
priority: 2
created: 2026-06-08T00:00:00Z
---
# Non-CI fixture (ci field absent)
EOF

# Dedicated fixture for gate:eval (t-4e57) — asserted on /api/tickets and by
# the headless-run dispatch below.
mkdir -p "$WORK/.tickets/t-gate"
cat > "$WORK/.tickets/t-gate/ticket.md" <<'EOF'
---
id: t-gate
status: open
type: task
priority: 2
created: 2026-06-08T00:00:00Z
ci: true
gate: eval
---
# Eval-gate fixture
EOF
cat > "$WORK/.tickets/t-gate/acceptance.md" <<'EOF'
# Acceptance
## Criteria
- [ ] something holds
## Test Plan
- [ ] a check
## QA
- [ ] Tested locally
EOF

# Dedicated fixture for type_outcome (t-cdeb) — needs 2+ closed tickets of a
# shared type (the field's visibility threshold) plus an open ticket of that
# type to receive it, which the shared build_tickets_fixture doesn't provide.
mkdir -p "$WORK/.tickets/t-oc1" "$WORK/.tickets/t-oc2" "$WORK/.tickets/t-ocopen"
cat > "$WORK/.tickets/t-oc1/ticket.md" <<'EOF'
---
id: t-oc1
status: closed
type: chore
priority: 2
eval_fail_count: 0
created: 2026-06-08T00:00:00Z
---
# Closed clean chore fixture
EOF
cat > "$WORK/.tickets/t-oc2/ticket.md" <<'EOF'
---
id: t-oc2
status: closed
type: chore
priority: 2
eval_fail_count: 1
created: 2026-06-08T00:00:00Z
---
# Closed rework chore fixture
EOF
cat > "$WORK/.tickets/t-ocopen/ticket.md" <<'EOF'
---
id: t-ocopen
status: open
type: chore
priority: 2
created: 2026-06-08T00:00:00Z
---
# Open chore fixture, receives type_outcome
EOF

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
json_get() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1:]: d=d[k]
print(d)' "$@"; }

GO_PORT="$(free_port)"
# The board binary sits in $BOARD_DIR/tools/sprint-check-bin, so its toolsDir is $BOARD_DIR/tools and it reads the
# semver from $BOARD_DIR/VERSION (t-5c20); started from $ROOT so its app.html, cockpit.html and model-tiers seed resolve.
GO_BIN="$(build_board "$BOARD_DIR/tools")"
cp "$ROOT/VERSION" "$BOARD_DIR/VERSION"
GO_CANON="$WORK/canon-go"

(cd "$ROOT" && SPRINT_CHECK_ROOT="$WORK" CANON_HOME="$GO_CANON" SPRINT_CHECK_NO_BROWSER=1 COCKPIT_STATE_DIR="$CK_STATE" COCKPIT_DAEMON_BIN="$CK_BIN" TMPDIR="$WORK" exec "$GO_BIN" "$GO_PORT") >/dev/null 2>&1 &
GO_PID=$!
disown "$GO_PID" 2>/dev/null || true

wait_for_port() {
  local port="$1" i
  for i in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/api/tickets" && return 0
    sleep 0.1
  done
  return 1
}
wait_for_port "$GO_PORT" || fail "sprint-check-api: the board did not start on port $GO_PORT"
B="http://127.0.0.1:$GO_PORT"

# ── /api/tickets fields ─────────────────────────────────────────────────────
python3 - "$(curl -s "$B/api/tickets")" <<'PY'
import json, sys
n = {t["id"]: t for t in json.loads(sys.argv[1])}
for tid in ("t-model", "t-cion", "t-cioff", "t-gate", "t-ocopen"):
    if tid not in n:
        print(f"sprint-check-api: FAIL — /api/tickets lacks fixture ticket {tid}: {sorted(n)}"); sys.exit(1)
# t-1720 regression: a Criteria line describing the (model: X) convention itself must never leak into models_used —
# only real Wrapup Gates rows count. Exact equality, so any other stray extraction fails loud too.
if n["t-model"]["models_used"] != ["claude-sonnet-5", "haiku"]:
    print(f"sprint-check-api: FAIL — t-1720 regression, t-model.models_used should be exactly ['claude-sonnet-5', 'haiku'], got {n['t-model']['models_used']!r}"); sys.exit(1)
# t-978c / t-4e57: ci and gate come from the frontmatter.
# ci is the frontmatter string ("true"), absent when the ticket has none.
if n["t-cion"].get("ci") != "true" or "ci" in n["t-cioff"]:
    print(f"sprint-check-api: FAIL — ci: t-cion={n['t-cion'].get('ci')!r} (want 'true'), t-cioff={n['t-cioff'].get('ci', '<absent>')!r} (want absent)"); sys.exit(1)
if n["t-gate"].get("gate") != "eval":
    print(f"sprint-check-api: FAIL — t-gate gate={n['t-gate'].get('gate')!r}, want 'eval'"); sys.exit(1)
# t-cdeb: an open ticket of a type with 2+ closed tickets carries type_outcome.
if not n["t-ocopen"].get("type_outcome"):
    print(f"sprint-check-api: FAIL — t-ocopen lacks type_outcome: {n['t-ocopen']}"); sys.exit(1)
# t-1f22: the gate reports are named for their writer, every other doc keeps its title-cased name, the file is unchanged.
docs = {d["file"]: d["name"] for d in n["t-model"]["docs"]}
want = {"t-model/eval-report.md": "Eval Agent", "t-model/review-notes.md": "Review Agent", "t-model/acceptance.md": "Acceptance"}
order = [d["file"] for d in n["t-model"]["docs"]]
if order != ["t-model/acceptance.md", "t-model/review-notes.md", "t-model/eval-report.md", "t-model/github.md"]:
    print(f"sprint-check-api: FAIL — t-1f22 doc order: {order!r}"); sys.exit(1)
if {f: docs.get(f) for f in want} != want:
    print(f"sprint-check-api: FAIL — t-1f22 doc names: want {want!r}, got {docs!r}"); sys.exit(1)
# t-1dec: a ticket's github.md (the trail tkt appends to) lists as GitHub, not Github.
gh_doc = [d for d in n["t-model"]["docs"] if d["file"] == "t-model/github.md"]
if len(gh_doc) != 1 or gh_doc[0]["name"] != "GitHub":
    print(f"sprint-check-api: FAIL — t-1dec github.md doc: {gh_doc!r}, want one named 'GitHub'"); sys.exit(1)
PY

# ── /api/git (t-9cde, t-d218) ────────────────────────────────────────────────
go_git="$(curl -s "$B/api/git")"
[[ "$(printf '%s' "$go_git" | json_get total_commits)" == 2 ]] || fail "sprint-check-api: /api/git total_commits should be 2 (fixture has 2 commits): $go_git"
[[ "$(printf '%s' "$go_git" | json_get is_git)" == True ]] || fail "sprint-check-api: /api/git lacks is_git: true: $go_git"

# ── /api/ticket-image: the fixture image byte for byte; traversal, non-image and missing refused ─────────────
# A canonical t-[a-z0-9]{4} id: build_tickets_fixture's longer ids never match the route's pattern.
mkdir -p "$WORK/.tickets/t-mock/visuals"
printf '\x89PNG\r\n\x1a\n' > "$WORK/.tickets/t-mock/visuals/test.png"
cat > "$WORK/.tickets/t-mock/ticket.md" <<'EOF'
---
id: t-mock
status: open
type: task
priority: 2
created: 2026-06-08T00:00:00Z
---
# Mock ticket for ticket-image
EOF

IMG_BODY="$WORK/img-body"
check_ticket_image() { # <label> <path> <want status>
  local got
  got="$(curl -s -o "$IMG_BODY" -w '%{http_code}' "$B/api/ticket-image/$2")"
  [[ "$got" == "$3" ]] || fail "sprint-check-api: ticket-image $1 gave $got, want $3"
  if [[ "$3" == 200 ]]; then cmp -s "$IMG_BODY" "$WORK/.tickets/t-mock/visuals/test.png" || fail "sprint-check-api: ticket-image $1 served other bytes"; fi
  if grep -q 'root:' "$IMG_BODY"; then fail "sprint-check-api: ticket-image $1 leaked a system file"; fi
}
check_ticket_image "valid image"              "t-mock/visuals/test.png" 200
check_ticket_image "traversal attempt"         "t-mock/../../../../etc/passwd" 404
check_ticket_image "non-image extension (real file, wrong ext)" "t-mock/ticket.md" 404
check_ticket_image "missing file"              "t-mock/visuals/does-not-exist.png" 404
check_ticket_image "malformed ticket id"       "t-ready/visuals/test.png" 404

# ── POST /api/ticket/<id>/visual (t-626d): accept + reject cases ─────────────

VISUAL_PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
reset_visuals() { rm -rf "$WORK/.tickets/t-mock/visuals"; mkdir -p "$WORK/.tickets/t-mock/visuals"; }

reset_visuals
for body in "{\"filename\":\"x.txt\",\"data\":\"$VISUAL_PNG_B64\"}" '{"filename":"x.png","data":"!!!not-base64!!!"}' \
            "{\"filename\":\"../../x.png\",\"data\":\"$VISUAL_PNG_B64\"}"; do
  res="$(curl -s -X POST "$B/api/ticket/t-mock/visual" -d "$body")"
  [[ "$(printf '%s' "$res" | json_get ok)" == False ]] || fail "sprint-check-api: /visual accepted a bad upload ($body): $res"
done
[[ -z "$(ls -A "$WORK/.tickets/t-mock/visuals")" ]] || fail "sprint-check-api: a rejected /visual upload wrote $(ls -A "$WORK/.tickets/t-mock/visuals")"
[[ ! -e "$WORK/x.png" && ! -e "$WORK/.tickets/x.png" ]] || fail "sprint-check-api: a traversal /visual upload wrote outside visuals/"

# Oversized payload (>8MB decoded, the maxVisualBytes cap) — built to a temp file, too large for a shell argument.
OVERSIZED_BODY="$(mktemp "$WORK/oversized.XXXXXX")"
{
  printf '{"filename":"x.png","data":"'
  head -c 9000000 /dev/zero | base64 | tr -d '\n'
  printf '"}'
} > "$OVERSIZED_BODY"
res="$(curl -s -X POST "$B/api/ticket/t-mock/visual" --data-binary "@$OVERSIZED_BODY")"
rm -f "$OVERSIZED_BODY"
[[ "$(printf '%s' "$res" | json_get ok)" == False ]] || fail "sprint-check-api: an oversized (>8MB) /visual upload was accepted: ${res:0:200}"
[[ ! -e "$WORK/.tickets/t-mock/visuals/x.png" ]] || fail "sprint-check-api: an oversized /visual upload wrote a file to disk"

# A valid upload keeps its name; the same name again auto-suffixes, never overwrites.
reset_visuals
up="$(curl -s -X POST "$B/api/ticket/t-mock/visual" -d "{\"filename\":\"pasted-1.png\",\"data\":\"$VISUAL_PNG_B64\"}")"
python3 - "$up" <<'PY' || fail "sprint-check-api: a valid /visual upload: $up"
import json, sys
sys.exit(0 if json.loads(sys.argv[1]) == {"ok": True, "filename": "pasted-1.png"} else 1)
PY
dup="$(curl -s -X POST "$B/api/ticket/t-mock/visual" -d "{\"filename\":\"pasted-1.png\",\"data\":\"$VISUAL_PNG_B64\"}")"
[[ "$(printf '%s' "$dup" | json_get filename)" == pasted-1-2.png ]] || fail "sprint-check-api: a name collision did not auto-suffix: $dup"
[[ -f "$WORK/.tickets/t-mock/visuals/pasted-1.png" && -f "$WORK/.tickets/t-mock/visuals/pasted-1-2.png" ]] || fail "sprint-check-api: the two uploads are not both on disk"
reset_visuals

# ── /api/ticket/<id>/headless-run (t-200b): trigger + poll ─────────────────
# The board started with SPRINT_HEADLESS_BIN/SPRINT_HEADLESS_EVAL_BIN pointed at the temp stubs: fill in their content
# so this never makes a real claude -p call. No real tools/ file is touched.
cat > "$SPRINT_HEADLESS_BIN" <<'EOF'
#!/usr/bin/env bash
sleep 1
echo "STUB-TOOL: full-pipeline"
echo "HEADLESS_VERDICT: PASS"
exit 0
EOF
# A distinct marker, so the gate-mode dispatch (t-4e57) is asserted: a gate:eval ticket must invoke this tool, a full
# ticket sprint-headless above.
cat > "$SPRINT_HEADLESS_EVAL_BIN" <<'EOF'
#!/usr/bin/env bash
sleep 1
echo "STUB-TOOL: eval-only"
echo "HEADLESS_VERDICT: PASS"
exit 0
EOF
chmod +x "$SPRINT_HEADLESS_BIN" "$SPRINT_HEADLESS_EVAL_BIN"

[[ "$(curl -s "$B/api/ticket/t-mock/headless-run" | json_get status)" == idle ]] || fail "sprint-check-api: headless-run should start idle"
trig="$(curl -s -X POST "$B/api/ticket/t-mock/headless-run" -d '{"base_ref":"main"}')"
[[ "$(printf '%s' "$trig" | json_get status)" == running ]] || fail "sprint-check-api: headless-run trigger did not return status=running: $trig"

# headless_running field on /api/tickets (t-dd51)
python3 - "$(curl -s "$B/api/tickets?all=1")" <<'PY'
import json, sys
t = next((t for t in json.loads(sys.argv[1]) if t.get("id") == "t-mock"), None)
if not t or t.get("headless_running") is not True:
    print(f"sprint-check-api: FAIL — /api/tickets missing headless_running=true for t-mock while the run is in progress: {t}"); sys.exit(1)
PY

sleep 3
python3 - "$(curl -s "$B/api/ticket/t-mock/headless-run")" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
if d.get("status") != "done" or "HEADLESS_VERDICT: PASS" not in d.get("output", "") or d.get("exit_code") != 0:
    print(f"sprint-check-api: FAIL — headless-run did not finish done/PASS/exit 0: {d}"); sys.exit(1)
if "STUB-TOOL: full-pipeline" not in d.get("output", ""):
    print(f"sprint-check-api: FAIL — a full-gate ticket did not dispatch sprint-headless (full pipeline): {d}"); sys.exit(1)
PY
python3 - "$(curl -s "$B/api/tickets?all=1")" <<'PY'
import json, sys
t = next((t for t in json.loads(sys.argv[1]) if t.get("id") == "t-mock"), None)
if t and t.get("headless_running"):
    print(f"sprint-check-api: FAIL — /api/tickets still reports headless_running after the run completed: {t}"); sys.exit(1)
PY

# gate-mode dispatch (t-4e57): a gate:eval ticket invokes sprint-headless-eval, never the full pipeline
gtrig="$(curl -s -X POST "$B/api/ticket/t-gate/headless-run" -d '{"base_ref":"main"}')"
[[ "$(printf '%s' "$gtrig" | json_get status)" == running ]] || fail "sprint-check-api: t-gate headless-run did not start: $gtrig"
sleep 3
python3 - "$(curl -s "$B/api/ticket/t-gate/headless-run")" <<'PY'
import json, sys
out = json.loads(sys.argv[1]).get("output", "")
if "STUB-TOOL: eval-only" not in out or "STUB-TOOL: full-pipeline" in out:
    print(f"sprint-check-api: FAIL — a gate:eval ticket must dispatch only sprint-headless-eval: {out!r}"); sys.exit(1)
PY

# ── POST /api/tickets writes ────────────────────────────────────────────────
new_ticket() { curl -s -X POST "$B/api/tickets" -d "$1" | json_get id; }
# create-with-gate (t-4e57)
eid="$(new_ticket '{"title":"gate create","type":"task","ci":true,"gate":"eval"}')"
grep -q '^gate: eval$' "$WORK/.tickets/$eid/ticket.md" || fail "sprint-check-api: create with gate:eval did not write 'gate: eval' ($eid)"
fid="$(new_ticket '{"title":"full create","type":"task","ci":true}')"
if grep -q '^gate:' "$WORK/.tickets/$fid/ticket.md"; then fail "sprint-check-api: a full create wrote a gate line ($fid)"; fi
# eval_override is human-only (t-e53c): a client's eval_override:true is ignored
oid="$(new_ticket '{"title":"override create","type":"task","eval_override":true}')"
grep -q '^eval_override: false$' "$WORK/.tickets/$oid/ticket.md" || fail "sprint-check-api: create did not write 'eval_override: false' ($oid)"
if grep -q 'eval_override: true' "$WORK/.tickets/$oid/ticket.md"; then fail "sprint-check-api: create honored a client's eval_override:true ($oid)"; fi
# create-with-skills (t-354b): an allowlisted, deduped skills line; absent otherwise
sid="$(new_ticket '{"title":"skills create","type":"chore","skills":"context-check,dead-code-cleanup,bogus,context-check"}')"
grep -q '^skills: context-check,dead-code-cleanup$' "$WORK/.tickets/$sid/ticket.md" || fail "sprint-check-api: create with skills did not write the allowlisted/deduped 'skills:' line ($sid)"
if grep -q 'bogus' "$WORK/.tickets/$sid/ticket.md"; then fail "sprint-check-api: create leaked a non-allowlisted skill ($sid)"; fi
ns="$(new_ticket '{"title":"noskills create","type":"chore"}')"
if grep -q '^skills:' "$WORK/.tickets/$ns/ticket.md"; then fail "sprint-check-api: create without skills wrote a skills line ($ns)"; fi
# create-with-demo (t-dfaa): demo: true; absent otherwise; created is a full UTC timestamp (t-19d1)
did="$(new_ticket '{"title":"demo create","type":"task","demo":true}')"
grep -q '^demo: true$' "$WORK/.tickets/$did/ticket.md" || fail "sprint-check-api: create with demo:true did not write 'demo: true' ($did)"
nd="$(new_ticket '{"title":"nodemo create","type":"task"}')"
if grep -q '^demo:' "$WORK/.tickets/$nd/ticket.md"; then fail "sprint-check-api: create without demo wrote a demo line ($nd)"; fi
grep -qE '^created: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$WORK/.tickets/$did/ticket.md" \
  || fail "sprint-check-api: create wrote a non-ISO created: $(grep '^created:' "$WORK/.tickets/$did/ticket.md")"

# ── demo toggle (t-64a0): ON inserts once, idempotent, OFF removes; a non-t-xxxx id is not the route ─────────
tog="$(new_ticket '{"title":"demo toggle","type":"task"}')"
if grep -q '^demo:' "$WORK/.tickets/$tog/ticket.md"; then fail "sprint-check-api: a new toggle ticket has a demo line ($tog)"; fi
curl -s -X POST "$B/api/ticket/$tog/demo" -d '{"demo":true}' >/dev/null
grep -q '^demo: true$' "$WORK/.tickets/$tog/ticket.md" || fail "sprint-check-api: demo toggle ON did not write 'demo: true' ($tog)"
again="$(curl -s -X POST "$B/api/ticket/$tog/demo" -d '{"demo":true}')"
[[ "$(printf '%s' "$again" | json_get ok)" == True ]] || fail "sprint-check-api: idempotent demo ON did not return ok:true ($tog): $again"
[[ "$(grep -c '^demo:' "$WORK/.tickets/$tog/ticket.md")" == 1 ]] || fail "sprint-check-api: idempotent demo ON duplicated the demo line ($tog)"
curl -s -X POST "$B/api/ticket/$tog/demo" -d '{"demo":false}' >/dev/null
if grep -q '^demo:' "$WORK/.tickets/$tog/ticket.md"; then fail "sprint-check-api: demo toggle OFF did not remove the demo line ($tog)"; fi
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/api/ticket/notaticket/demo" -d '{"demo":true}')"
[[ "$code" == 404 ]] || fail "sprint-check-api: the demo route accepted a non-t-xxxx id (status $code)"

# ── /api/ci-workflow (t-344e): writes the shipped template, then refuses on exists ─────────
rm -rf "$WORK/.github"
ci1="$(curl -s -X POST "$B/api/ci-workflow" -d '{}')"
[[ "$(printf '%s' "$ci1" | json_get ok)" == True ]] || fail "sprint-check-api: ci-workflow create not ok: $ci1"
# t-04f4: the written file is the template with the canon ref pinned to this install's release tag.
sed "s/__CANON_REF__/v$(tr -d '[:space:]' < "$ROOT/VERSION")/" "$ROOT/tools/canon-gate-template.yml" > "$WORK/canon-gate.expected"
cmp -s "$WORK/.github/workflows/canon-gate.yml" "$WORK/canon-gate.expected" || fail "sprint-check-api: the written canon-gate.yml is not the template with the canon ref pinned"
grep -q "ref: v[0-9]*\.[0-9]*\.[0-9]* " "$WORK/.github/workflows/canon-gate.yml" || fail "sprint-check-api: the written canon-gate.yml has no pinned canon ref"
ci2="$(curl -s -X POST "$B/api/ci-workflow" -d '{}')"
[[ "$(printf '%s' "$ci2" | json_get ok)" == False && "$(printf '%s' "$ci2" | json_get reason)" == exists ]] || fail "sprint-check-api: ci-workflow did not refuse on exists: $ci2"
rm -rf "$WORK/.github"

# ── /api/ticket-feature (t-f89a): the fixture text; traversal, non-feature and missing refused ─────────
mkdir -p "$WORK/.tickets/t-mock/features"
printf 'Scenario: api\n  Given a\n  Then b\n' > "$WORK/.tickets/t-mock/features/spec.feature"
FEAT_BODY="$WORK/feat-body"
check_ticket_feature() { # <label> <path> <want status>
  local got
  got="$(curl -s -o "$FEAT_BODY" -w '%{http_code}' "$B/api/ticket-feature/$2")"
  [[ "$got" == "$3" ]] || fail "sprint-check-api: ticket-feature $1 gave $got, want $3"
  if grep -q 'root:' "$FEAT_BODY"; then fail "sprint-check-api: ticket-feature $1 leaked a system file"; fi
}
check_ticket_feature "valid feature"     "t-mock/features/spec.feature" 200
[[ "$(json_get content < "$FEAT_BODY")" == "$(cat "$WORK/.tickets/t-mock/features/spec.feature")" ]] || fail "sprint-check-api: ticket-feature did not return the file text: $(cat "$FEAT_BODY")"
check_ticket_feature "traversal attempt" "t-mock/../../../../etc/passwd" 404
check_ticket_feature "non-feature ext"   "t-mock/ticket.md" 404
check_ticket_feature "missing file"      "t-mock/features/none.feature" 404
rm -rf "$WORK/.tickets/t-mock/features"

# ── /api/worktrees ticket_present (t-2a1c) ──────────────────────────────────
# A real sibling worktree — a checkout of HEAD, whose commits are empty, so nothing under .tickets/ is materialized —
# reports ticket_present:false; the main checkout (which physically holds .tickets/t-mock, untracked) is exempt → true.
# Without ?ticket the field is absent.
WT_PARENT="$(mktemp -d)"
WT="$WT_PARENT/api-wt"
git -C "$WORK" worktree add -q "$WT" -b api-wt
python3 - "$(curl -s "$B/api/worktrees?ticket=t-mock")" "$(curl -s "$B/api/worktrees")" "$(curl -s "$B/api/worktrees?ticket=t-abcd%0A")" <<'PY'
import json, sys
wt, no, nl = (json.loads(a) for a in sys.argv[1:4])
main = [e for e in wt if e.get("is_main")]
other = [e for e in wt if not e.get("is_main")]
if not main or main[0].get("ticket_present") is not True:
    print(f"sprint-check-api: FAIL — the main checkout should report ticket_present=true: {main}"); sys.exit(1)
if not other or any(e.get("ticket_present") is not False for e in other):
    print(f"sprint-check-api: FAIL — a sibling worktree (no committed .tickets/) should report ticket_present=false: {other}"); sys.exit(1)
if any("ticket_present" in e for e in no):
    print(f"sprint-check-api: FAIL — ticket_present must be absent when no ticket is passed: {no}"); sys.exit(1)
# t-2a1c reviewer finding: a trailing newline makes the id invalid, which reads as no ticket.
if any("ticket_present" in e for e in nl):
    print(f"sprint-check-api: FAIL — a trailing-newline ?ticket must be rejected (no ticket_present): {nl}"); sys.exit(1)
PY

# ── /api/cockpit-docs (t-1357): plan/acceptance/HANDOFF read from the session's WORKTREE, never an arbitrary path ─────
mkdir -p "$WT/.tickets/t-mock"
printf '# Plan (worktree)\nWorktree plan body\n' > "$WT/.tickets/t-mock/plan.md"
printf '# Acceptance (worktree)\n' > "$WT/.tickets/t-mock/acceptance.md"
printf '## Current Focus\nWorktree handoff focus.\n' > "$WT/HANDOFF.md"
WT_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$WT")"
python3 - "$(curl -s "$B/api/cockpit-docs/t-mock?cwd=$WT_ENC")" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
for k, want in (("plan", "Worktree plan body"), ("acceptance", "Acceptance (worktree)"), ("handoff", "Worktree handoff focus")):
    if want not in (d.get(k) or ""):
        print(f"sprint-check-api: FAIL — cockpit-docs did not return the worktree {k}: {d}"); sys.exit(1)
PY
code="$(curl -s -o /dev/null -w '%{http_code}' "$B/api/cockpit-docs/t-mock?cwd=%2Ftmp")"
[[ "$code" == 400 ]] || fail "sprint-check-api: cockpit-docs accepted a non-worktree cwd (status $code)"
code="$(curl -s -o /dev/null -w '%{http_code}' "$B/api/cockpit-docs/t-mock")"
[[ "$code" == 400 ]] || fail "sprint-check-api: cockpit-docs accepted a missing cwd (status $code)"
rm -rf "$WT/.tickets" "$WT/HANDOFF.md"
# A stale worktree (removed from disk, still registered in `git worktree list`) is a 400 too.
rm -rf "$WT"
code="$(curl -s -o /dev/null -w '%{http_code}' "$B/api/cockpit-docs/t-mock?cwd=$WT_ENC")"
[[ "$code" == 400 ]] || fail "sprint-check-api: cockpit-docs did not 400 for a stale (removed) worktree (status $code)"
git -C "$WORK" worktree remove --force "$WT" 2>/dev/null || true
rm -rf "$WT_PARENT"

# ── /api/cockpit stale detection (t-74d6) ───────────────────────────────────
# A stub daemon serves /healthz + /version{version,commit,exe_mtime}; daemon.json in CK_STATE points the board at it.
# The board compares exe_mtime with CK_BIN's on-disk mtime: unequal → stale, equal → not.
start_daemon_stub() { # <json for /version>
  CK_STUB_PORT="$(free_port)"
  python3 - "$CK_STUB_PORT" "$1" <<'PY' >/dev/null 2>&1 &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
PORT, BODY = int(sys.argv[1]), sys.argv[2].encode()
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/healthz':
            self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
        elif self.path == '/version':
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(BODY)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(('127.0.0.1', PORT), H).serve_forever()
PY
  CK_STUB_PID=$!
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$CK_STUB_PORT/healthz" && break; sleep 0.1; done
  printf '{"addr":"127.0.0.1:%s","token":"x"}' "$CK_STUB_PORT" > "$CK_STATE/daemon.json"
}
ck_check() { # <want stale true|false> <want running_build.commit>
  python3 - "$(curl -s "$B/api/cockpit")" "$1" "$2" <<'PY'
import json, sys
d, want, commit = json.loads(sys.argv[1]), sys.argv[2] == 'true', sys.argv[3]
for k in ("running", "addr", "stale", "running_build", "latest_build", "shell_uptime_secs"):
    if k not in d:
        print(f"/api/cockpit lacks {k}: {d}"); sys.exit(1)
if d["running"] is not True:
    print(f"/api/cockpit running={d['running']!r}, want True: {d}"); sys.exit(1)
up = d["shell_uptime_secs"]
if not isinstance(up, int) or isinstance(up, bool) or up < 0:
    print(f"/api/cockpit shell_uptime_secs not a non-negative int: {up!r}"); sys.exit(1)
if d["stale"] is not want:
    print(f"/api/cockpit stale={d['stale']!r}, want {want}: {d}"); sys.exit(1)
# t-4487: running_build carries the daemon's build stamp ("" for an older daemon that sends none).
if d["running_build"].get("commit") != commit:
    print(f"/api/cockpit running_build.commit={d['running_build'].get('commit')!r}, want {commit!r}"); sys.exit(1)
PY
}
start_daemon_stub '{"version": "stub", "commit": "abc12345", "exe_mtime": 1000000000}'
python3 -c "import os,sys; os.utime(sys.argv[1], (1500000000, 1500000000))" "$CK_BIN"
ck_check true abc12345 || fail "sprint-check-api: /api/cockpit with a stale daemon binary"
python3 -c "import os,sys; os.utime(sys.argv[1], (1000000000, 1000000000))" "$CK_BIN"
ck_check false abc12345 || fail "sprint-check-api: /api/cockpit with a current daemon binary"
kill "$CK_STUB_PID" 2>/dev/null || true; wait "$CK_STUB_PID" 2>/dev/null || true; CK_STUB_PID=""
start_daemon_stub '{"version": "old", "exe_mtime": 1000000000}'
ck_check false "" || fail "sprint-check-api: /api/cockpit with a daemon that sends no commit"
kill "$CK_STUB_PID" 2>/dev/null || true; wait "$CK_STUB_PID" 2>/dev/null || true; CK_STUB_PID=""
rm -f "$CK_STATE/daemon.json"

# ── /api/version (t-5c20): {version, commit, daemon}, version = the VERSION file ───────────────
python3 - "$(curl -s "$B/api/version")" "$(tr -d ' \t\n\r' < "$ROOT/VERSION")" <<'PY' || fail "sprint-check-api: /api/version"
import json, sys
d, semver = json.loads(sys.argv[1]), sys.argv[2]
if set(d) != {"version", "commit", "daemon"}:
    print(f"/api/version keys {sorted(d)}, want commit/daemon/version"); sys.exit(1)
if d["version"] != semver:
    print(f"/api/version semver {d['version']} != VERSION file {semver}"); sys.exit(1)
PY

# ── project-scoped ticket assets (t-7d83): /api/ticket-image and /api/ticket-feature serve from the project named by
# ?project=, not the board's default project. A ticket that exists ONLY in a second registered project makes an ignored
# param a 404 instead of a silent pass.
SCOPED="$WORK/scopedproj"
mkdir -p "$SCOPED/.git" "$SCOPED/.tickets/t-prj1/visuals" "$SCOPED/.tickets/t-prj1/features"
printf '\x89PNG\r\n\x1a\nscoped' > "$SCOPED/.tickets/t-prj1/visuals/scoped.png"
printf 'Scenario: scoped\n  Given only in the second project\n' > "$SCOPED/.tickets/t-prj1/features/scoped.feature"
# Real files OUTSIDE .tickets/: a traversal that escaped containment would return 200 for these.
printf '\x89PNG\r\n\x1a\nsecret' > "$SCOPED/outside.png"
printf 'Scenario: secret\n' > "$SCOPED/outside.feature"
printf -- '---\nid: t-prj1\nstatus: open\ntype: task\npriority: 2\ncreated: 2026-06-08T00:00:00Z\n---\n# Scoped\n' > "$SCOPED/.tickets/t-prj1/ticket.md"
post_json() { curl -s -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d "$2" "$B$1"; }
project_id() { curl -s "$B/api/projects" | python3 -c "import sys,json;print(next((e['id'] for e in json.load(sys.stdin) if e['path'].endswith(sys.argv[1])),''))" "$1"; }
post_json /api/projects "{\"path\":\"$SCOPED\",\"description\":\"scoped assets\"}" >/dev/null
SID="$(project_id /scopedproj)"
[ -n "$SID" ] || fail "sprint-check-api: the scoped project did not register"
OUT="$WORK/scoped-body"
scoped_code() { curl -s -o "$OUT" -w '%{http_code}' "$B/api/$1"; }
for route in "ticket-image/t-prj1/visuals/scoped.png" "ticket-feature/t-prj1/features/scoped.feature"; do
  case "$route" in ticket-image/*) traversal="ticket-image/t-prj1/..%2F..%2Foutside.png";; *) traversal="ticket-feature/t-prj1/..%2F..%2Foutside.feature";; esac
  [ "$(scoped_code "$route?project=$SID")" = 200 ] || fail "sprint-check-api: $route with ?project= should be 200"
  case "$route" in
    ticket-image/*) cmp -s "$OUT" "$SCOPED/.tickets/t-prj1/visuals/scoped.png" || fail "sprint-check-api: $route served other bytes for ?project=" ;;
    *) [[ "$(json_get content < "$OUT")" == "$(cat "$SCOPED/.tickets/t-prj1/features/scoped.feature")" ]] || fail "sprint-check-api: $route served other text for ?project=" ;;
  esac
  [ "$(scoped_code "$route")" = 404 ] || fail "sprint-check-api: $route without ?project= must 404 (the ticket is not in the default project)"
  [ "$(scoped_code "$route?project=ffffffffffff")" = 400 ] || fail "sprint-check-api: $route with an unknown ?project= must be 400"
  # Go's ServeMux answers an encoded `..` with a 301 path-clean redirect: a rejection. What must never happen is a 200
  # or the outside file's contents coming back.
  code="$(scoped_code "$traversal?project=$SID")"
  { [ "$code" != 200 ] && ! grep -q secret "$OUT"; } || fail "sprint-check-api: a traversal out of .tickets/ with ?project= must be rejected (got $code)"
done
curl -s -X DELETE -H 'Origin: http://localhost' "$B/api/projects/$SID" >/dev/null

# ── /api/projects registry (t-9917) ─────────────────────────────────────────
REGPROJ="$WORK/regproj"
mkdir -p "$REGPROJ/.git"
add="$(post_json /api/projects "{\"path\":\"$REGPROJ\",\"description\":\"reg & api < test >\"}")"
list="$(curl -s "$B/api/projects")"
python3 - "$add" "$list" "$GO_CANON/cockpit/projects.json" "$REGPROJ" <<'PY' || fail "sprint-check-api: /api/projects add/list/on-disk registry"
import json, os, sys
add, lst, disk, path = json.loads(sys.argv[1]), json.loads(sys.argv[2]), json.load(open(sys.argv[3])), sys.argv[4]
real = os.path.realpath(path)
assert add.get("ok") is True and "warning" not in add, f"add: {add}"
p = add["project"]
assert p["path"] == real and p["description"] == "reg & api < test >" and len(p["id"]) == 12, f"add project: {p}"
assert lst == [p], f"list: {lst}"
assert disk == lst, f"on-disk projects.json {disk} != list {lst}"
PY
# t-07c8: a non-git dir REGISTERS with a non-blocking warning (git relaxed)
mkdir -p "$WORK/regplain"
plain="$(post_json /api/projects "{\"path\":\"$WORK/regplain\",\"description\":\"x\"}")"
python3 - "$plain" <<'PY' || fail "sprint-check-api: /api/projects non-git ok+warning"
import json, sys
a = json.loads(sys.argv[1])
assert a.get("ok") is True, f"a non-git dir should register (ok:true), got {a}"
assert a.get("warning") == "Path is not a git repository!", f"expected the git warning, got {a.get('warning')}"
PY
# t-d538: GET /api/track-changes for the registered non-git dir, and a POST without confirm is refused.
plain_id="$(printf '%s' "$plain" | json_get project id)"
python3 - "$(curl -s "$B/api/track-changes?project=$plain_id")" "$(post_json "/api/track-changes?project=$plain_id" '{}')" <<'PY' || fail "sprint-check-api: /api/track-changes"
import json, sys
a, c = json.loads(sys.argv[1]), json.loads(sys.argv[2])
assert a.get("ok") is True and set(a) == {"ok", "tracking", "synced", "git_available"} and isinstance(a["tracking"], bool), f"track-changes GET {a}"
assert c.get("ok") is False, f"track-changes POST (no confirm) {c}"
PY
[[ ! -e "$WORK/regplain/.git" ]] || fail "sprint-check-api: a POST without confirm initialized regplain"
curl -s -X DELETE -H 'Origin: http://localhost' "$B/api/projects/$plain_id" >/dev/null
# t-07c8: served HTML carries Cache-Control: no-store (t-9b2d: the board page itself too)
for page in /cockpit /; do
  cc="$(curl -s -D - -o /dev/null "$B$page" | grep -io 'cache-control: no-store' | head -1)"
  [ -n "$cc" ] || fail "sprint-check-api: $page missing Cache-Control: no-store"
done

reg_id="$(printf '%s' "$list" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")"

# ── Phase 2a: project-scoped reads + stats + unknown-id 400 (t-a55a) ────────
mkdir -p "$REGPROJ/.tickets/t-aaa1" "$REGPROJ/.tickets/t-aaa2"
printf '# t\n' > "$REGPROJ/.tickets/t-aaa1/ticket.md"
printf '# t\n' > "$REGPROJ/.tickets/t-aaa2/ticket.md"
REGPROJ2="$WORK/regproj2"; mkdir -p "$REGPROJ2/.git/x" "$REGPROJ2/.tickets/t-bbb1"
printf '# t\n' > "$REGPROJ2/.tickets/t-bbb1/ticket.md"
post_json /api/projects "{\"path\":\"$REGPROJ2\",\"description\":\"p2\"}" >/dev/null
reg_id2="$(project_id /regproj2)"

n1="$(curl -s "$B/api/tickets?project=$reg_id" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')"
n2="$(curl -s "$B/api/tickets?project=$reg_id2" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')"
[[ "$n1" == 2 && "$n2" == 1 ]] || fail "sprint-check-api: project-scoped /api/tickets wrong (regproj=$n1 want 2, regproj2=$n2 want 1)"

# scoped /api/handoff, /api/git, /api/doc, /api/why read the named project
( cd "$REGPROJ" && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -qm init )
printf '# Handoff\n## Current Focus\nRegproj focus line for the scoped read.\n' > "$REGPROJ/HANDOFF.md"
printf '# Acceptance\n## Criteria\n- [ ] regproj scoped doc\n' > "$REGPROJ/.tickets/t-aaa1/acceptance.md"
python3 - "$(curl -s "$B/api/handoff?project=$reg_id")" "$(curl -s "$B/api/git?project=$reg_id")" \
  "$(curl -s "$B/api/why?project=$reg_id")" "$(curl -s "$B/api/doc/t-aaa1/acceptance.md?project=$reg_id")" <<'PY' || fail "sprint-check-api: scoped reads"
import json, sys
h, g, w, d = (json.loads(a) for a in sys.argv[1:5])
assert "Regproj focus line" in json.dumps(h), f"handoff not regproj-scoped: {h}"
assert g.get("project") == "regproj" and g.get("total_commits") == 1, f"git not regproj-scoped: {g}"
assert w.get("message") == "Enter a file path." and w.get("results") == [], f"why: {w}"
assert "regproj scoped doc" in d.get("content", ""), f"doc not regproj-scoped: {d}"
PY

# project-stats ticket_count + t-7485 skills field (from the project's AGENTS.md AI-SKILLS table)
printf '# regproj\n<!-- AI-SKILLS:BEGIN -->\n## Active canon skills\n\n| Skill | Category | Source |\n|-------|----------|--------|\n| sprint | dev | /x/skills/sprint/SKILL.md |\n<!-- AI-SKILLS:END -->\n' > "$REGPROJ/AGENTS.md"
python3 - "$(curl -s "$B/api/project-stats?project=$reg_id")" "$(curl -s "$B/api/project-stats?project=$reg_id2")" <<'PY' || fail "sprint-check-api: /api/project-stats"
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
assert a["ticket_count"] == 2 and "updated" in a, f"stats {a}"
assert a.get("skills") == ["sprint"], f'skills should be ["sprint"], got {a.get("skills")}'
assert b.get("skills") == [], f'a project without AGENTS.md should have skills [] (not null), got {b.get("skills")}'
PY

code="$(curl -s -o /dev/null -w '%{http_code}' "$B/api/tickets?project=deadbeef0000")"
[[ "$code" == 400 ]] || fail "sprint-check-api: an unknown project id should 400 (got $code)"
code="$(curl -s -o /dev/null -w '%{http_code}' "$B/api/tickets")"
[[ "$code" == 200 ]] || fail "sprint-check-api: no-param /api/tickets should still 200 (got $code)"

# ── t-1b88 /api/browse-dirs (Add-Project folder picker) ─────────────────────
# Subdirs only (never files or their contents), dotfolders hidden unless ?hidden=1 (t-340d).
BROWSEFIX="$WORK/browsefix"; mkdir -p "$BROWSEFIX/alpha" "$BROWSEFIX/beta" "$BROWSEFIX/.hiddendir"; printf 'x' > "$BROWSEFIX/afile.txt"
python3 - "$(curl -s "$B/api/browse-dirs?path=$BROWSEFIX")" "$(curl -s "$B/api/browse-dirs?path=$BROWSEFIX&hidden=1")" <<'PY' || fail "sprint-check-api: /api/browse-dirs listing"
import json, sys
a, h = json.loads(sys.argv[1]), json.loads(sys.argv[2])
assert [e["name"] for e in a["entries"]] == ["alpha", "beta"], f"want dirs-only [alpha,beta], got {a['entries']}"
assert a["parent"], "parent should be set for a non-root dir"
assert [e["name"] for e in h["entries"]] == [".hiddendir", "alpha", "beta"], f"?hidden=1 should add the dotfolder, got {h['entries']}"
PY
for ep in "$BROWSEFIX/afile.txt" "/no/such/dir/xyz123"; do
  has_err="$(curl -s "$B/api/browse-dirs?path=$ep" | python3 -c 'import sys,json;print("error" in json.load(sys.stdin))')"
  [[ "$has_err" == True ]] || fail "sprint-check-api: browse-dirs should error on '$ep'"
done
hp="$(curl -s "$B/api/browse-dirs" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(bool(d.get("path")) and "error" not in d)')"
[[ "$hp" == True ]] || fail "sprint-check-api: browse-dirs with no path should list the home folder"

# ── Phase 2b-ii: project-scoped WRITES land in the tab's project (t-8485) ────
cid="$(post_json "/api/tickets?project=$reg_id" '{"title":"scoped write","type":"task","status":"open"}' | json_get id)"
[[ -f "$REGPROJ/.tickets/$cid/ticket.md" ]] || fail "sprint-check-api: a scoped create did not land in regproj (id=$cid)"
[[ ! -e "$REGPROJ2/.tickets/$cid" && ! -e "$WORK/.tickets/$cid" ]] || fail "sprint-check-api: a scoped create leaked into another project"
post_json "/api/ticket/$cid/status?project=$reg_id" '{"status":"in_progress"}' >/dev/null
[[ "$(tr -d '[:space:]' < "$REGPROJ/.tickets/ACTIVE" 2>/dev/null)" == "$cid" ]] || fail "sprint-check-api: a scoped status did not write regproj's ACTIVE"
post_json "/api/doc/$cid/plan.md?project=$reg_id" '{"content":"# Scoped plan\nbody"}' >/dev/null
grep -q "Scoped plan" "$REGPROJ/.tickets/$cid/plan.md" || fail "sprint-check-api: a scoped doc write did not land in regproj"
wcode="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' \
        -d '{"status":"open"}' "$B/api/ticket/$cid/status?project=deadbeef0000")"
[[ "$wcode" == 400 ]] || fail "sprint-check-api: a scoped write with an unknown id should 400 (got $wcode)"

# ── t-7485 register-skill ──────────────────────────────────────────────────
# Unknown ?project → 400. Then (via the hermetic SKILLS_SH_BIN stub) regproj2 registers `sprint`: the AGENTS.md
# AI-SKILLS row appears and a re-POST is idempotent.
rcode="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d '{}' "$B/api/register-skill?project=deadbeef0000")"
[[ "$rcode" == 400 ]] || fail "sprint-check-api: register-skill with an unknown id should 400 (got $rcode)"
reg_ok="$(post_json "/api/register-skill?project=$reg_id2" '{}' | json_get ok)"
[[ "$reg_ok" == True ]] || fail "sprint-check-api: register-skill did not report ok (got $reg_ok)"
grep -q "^| sprint " "$REGPROJ2/AGENTS.md" || fail "sprint-check-api: register-skill did not add the sprint row to regproj2 AGENTS.md"
post_json "/api/register-skill?project=$reg_id2" '{}' >/dev/null
[[ "$(grep -c '^| sprint ' "$REGPROJ2/AGENTS.md")" == 1 ]] || fail "sprint-check-api: register-skill is not idempotent (duplicate sprint rows)"
# t-b47a: the board passes SKILLS_SH_ASSUME_YES=1 to the skills.sh subprocess (both calls above logged one line each).
[[ "$(cat "$ASSUME_YES_LOG")" == $'1\n1' ]] || fail "sprint-check-api: SKILLS_SH_ASSUME_YES not set to 1 on every call (log: $(tr '\n' ',' < "$ASSUME_YES_LOG"))"
sk="$(curl -s "$B/api/project-stats?project=$reg_id2" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("skills"))')"
[[ "$sk" == "['sprint']" ]] || fail "sprint-check-api: skills after register wrong (got $sk)"
# t-96c3: the allowlist covers `efficiency`; an out-of-allowlist skill is refused and writes nothing.
[[ "$(post_json "/api/register-skill?project=$reg_id2&skill=efficiency" '{}' | json_get ok)" == True ]] || fail "sprint-check-api: register-skill skill=efficiency should succeed"
grep -q "^| efficiency " "$REGPROJ2/AGENTS.md" || fail "sprint-check-api: register-skill skill=efficiency did not add the efficiency row"
[[ "$(post_json "/api/register-skill?project=$reg_id2&skill=wrapup" '{}' | json_get ok)" == False ]] || fail "sprint-check-api: an out-of-allowlist skill should be refused"
if grep -q "^| wrapup " "$REGPROJ2/AGENTS.md"; then fail "sprint-check-api: an out-of-allowlist skill was written to AGENTS.md"; fi

curl -s -X DELETE -H 'Origin: http://localhost' "$B/api/projects/$reg_id2" >/dev/null
curl -s -X DELETE -H 'Origin: http://localhost' "$B/api/projects/$reg_id" >/dev/null
after="$(curl -s "$B/api/projects")"
[[ "$after" == "[]" ]] || fail "sprint-check-api: /api/projects not empty after delete: $after"

# ── t-5df2: Admin > Model Tiers edits land in the Cockpit data dir ($CANON_HOME/cockpit), never the tracked seed ──
SEED_TIERS="$ROOT/tools/sprint-check-app/model-tiers.json"
seed_sha="$(shasum "$SEED_TIERS" | cut -d' ' -f1)"
tiers_post() { curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d "$1" "$B/api/admin/model-tiers"; }
tiers_json() { curl -s "$B/api/admin/model-tiers" | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin), sort_keys=True))'; }
seed_json="$(python3 -c 'import sys,json; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$SEED_TIERS")"
user_file="$GO_CANON/cockpit/model-tiers.json"
[[ "$(tiers_json)" == "$seed_json" ]] || fail "sprint-check-api: GET without a data-dir copy is not the seed"
edited="$(python3 -c 'import sys,json; d=json.load(open(sys.argv[1])); d["models"]["anthropic"].append({"id":"probe-zz","alias":"probe-zz"}); print(json.dumps(d))' "$SEED_TIERS")"
[[ "$(tiers_post "$edited")" == 200 ]] || fail "sprint-check-api: a valid model-tiers save was rejected"
[[ -f "$user_file" ]] || fail "sprint-check-api: the save did not write $user_file"
[[ "$(shasum "$SEED_TIERS" | cut -d' ' -f1)" == "$seed_sha" ]] || fail "sprint-check-api: the save changed the tracked seed"
tiers_json | grep probe-zz >/dev/null || fail "sprint-check-api: GET did not return the data-dir copy"
saved_sha="$(shasum "$user_file" | cut -d' ' -f1)"
for bad in '{"models":"x","defaults":{}}' '[]' 'null' '{"reset":"yes"}' '{"reset":true,"x":1}' '{"reset":false}' \
           '{"models":{"anthropic":[{"id":"../x"}]},"defaults":{}}'; do
  [[ "$(tiers_post "$bad")" == 400 ]] || fail "sprint-check-api: model-tiers payload $bad should 400"
  [[ "$(shasum "$user_file" | cut -d' ' -f1)" == "$saved_sha" ]] || fail "sprint-check-api: rejected payload $bad changed the data-dir copy"
done
for corrupt in '[]' 'null' 'not json'; do   # a data-dir copy that is not a registry object falls back to the seed
  printf '%s' "$corrupt" > "$user_file"
  [[ "$(tiers_json)" == "$seed_json" ]] || fail "sprint-check-api: GET with a corrupt data-dir copy ($corrupt) is not the seed"
done
[[ "$(tiers_post '{"reset":true}')" == 200 ]] || fail "sprint-check-api: model-tiers reset failed"
[[ ! -e "$user_file" ]] || fail "sprint-check-api: reset left $user_file"
[[ "$(tiers_post '{"reset":true}')" == 200 ]] || fail "sprint-check-api: reset is not idempotent when no copy exists"
[[ "$(tiers_json)" == "$seed_json" ]] || fail "sprint-check-api: GET after reset is not the seed"

# t-d40b: retire and Remove-with-a-move go through the same validation and land in the data dir, never the seed.
tiers_act() { curl -s -w '\n%{http_code}' -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d "$2" "$B/api/admin/model-tiers/$1"; }
[[ "$(tiers_act retire '{"old":"claude-sonnet-5","new":"claude-sonnet-5-5"}' | tail -1)" == 200 ]] || fail "sprint-check-api: retire sonnet 5 -> 5.5 was rejected"
tiers_json | python3 -c 'import sys,json
d=json.load(sys.stdin); m={e["id"]:e for e in d["models"]["anthropic"]}
assert m["claude-sonnet-5-5"].get("alias")=="sonnet" and m["claude-sonnet-5"].get("legacy") is True and not m["claude-sonnet-5"].get("alias"), m
assert d["defaults"]["eval"]["anthropic"]=="claude-sonnet-5-5", d["defaults"]' || fail "sprint-check-api: retire did not move the alias and the eval default and mark the old entry legacy"
[[ "$(shasum "$SEED_TIERS" | cut -d' ' -f1)" == "$seed_sha" ]] || fail "sprint-check-api: retire changed the tracked seed"
retired_sha="$(shasum "$user_file" | cut -d' ' -f1)"
for bad in retire:'{"old":"claude-sonnet-5","new":"claude-sonnet-5"}' retire:'{"old":"nope","new":"claude-sonnet-5-5"}' retire:'{"old":"claude-haiku-4-5-20251001","new":"gpt-6-sol"}' \
           remove:'{"id":"claude-haiku-4-5-20251001"}' remove:'{"id":"claude-haiku-4-5-20251001","move_to":"claude-opus-5-5"}'; do
  [[ "$(tiers_act "${bad%%:*}" "${bad#*:}" | tail -1)" == 400 ]] || fail "sprint-check-api: ${bad%%:*} ${bad#*:} should 400"
  [[ "$(shasum "$user_file" | cut -d' ' -f1)" == "$retired_sha" ]] || fail "sprint-check-api: a refused ${bad%%:*} changed the data-dir copy"
done
first_line="$(tiers_act remove '{"id":"claude-haiku-4-5-20251001"}')"; first_line="${first_line%%$'\n'*}"
[[ "$first_line" == *"holds the alias haiku"* ]] || fail "sprint-check-api: remove without a move target did not say what the entry holds"
[[ "$(tiers_act remove '{"id":"claude-haiku-4-5-20251001","move_to":"claude-haiku-5-5"}' | tail -1)" == 200 ]] || fail "sprint-check-api: remove with a move target was rejected"
tiers_json | python3 -c 'import sys,json
d=json.load(sys.stdin); m={e["id"]:e for e in d["models"]["anthropic"]}
assert "claude-haiku-4-5-20251001" not in m and m["claude-haiku-5-5"].get("alias")=="haiku", m' || fail "sprint-check-api: remove-with-a-move did not delete the entry and hand over the alias"
# a save that gives two active entries one alias, or points a default at a legacy entry, is refused
dup="$(tiers_json | python3 -c 'import sys,json
d=json.load(sys.stdin); m={e["id"]:e for e in d["models"]["anthropic"]}; m["claude-opus-5-5"]["alias"]="haiku"; print(json.dumps(d))')"
[[ "$(tiers_post "$dup")" == 400 ]] || fail "sprint-check-api: a duplicate active alias was accepted"
legdef="$(tiers_json | python3 -c 'import sys,json
d=json.load(sys.stdin); d["defaults"]["eval"]["anthropic"]="claude-sonnet-5"; print(json.dumps(d))')"
[[ "$(tiers_post "$legdef")" == 400 ]] || fail "sprint-check-api: a default on a legacy entry was accepted"
# t-d40b: Refresh answers from the SAVED sources only (a url in the request is ignored and nothing is fetched for it), reports a source
# that is refused as one line, and never reads the network for a loopback or private address; Apply adds first, then retires.
[[ "$(tiers_post '{"reset":true}')" == 200 ]] || fail "sprint-check-api: reset before the refresh checks failed"
refresh_json() { curl -s -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d "$1" "$B/api/admin/model-tiers/refresh"; }
priv_src="$(tiers_json | python3 -c 'import sys,json
d=json.load(sys.stdin); d["sources"]=[{"url":"https://127.0.0.1/models","kind":"docs","provider":"anthropic"}]; print(json.dumps(d))')"
[[ "$(tiers_post "$priv_src")" == 400 ]] || fail "sprint-check-api: a loopback source was saved"
http_src="$(tiers_json | python3 -c 'import sys,json
d=json.load(sys.stdin); d["sources"]=[{"url":"http://example.com/models","kind":"docs","provider":"anthropic"}]; print(json.dumps(d))')"
[[ "$(tiers_post "$http_src")" == 400 ]] || fail "sprint-check-api: an http source was saved"
keyhost_src="$(tiers_json | python3 -c 'import sys,json
d=json.load(sys.stdin); d["sources"]=[{"url":"https://example.com/v1/models","kind":"api","provider":"anthropic"}]; print(json.dumps(d))')"
[[ "$(tiers_post "$keyhost_src")" == 400 ]] || fail "sprint-check-api: a Models API source on another host was saved"
tiers_json | python3 -c 'import sys,json
d=json.load(sys.stdin); s=d["sources"]; assert [x["kind"] for x in s]==["docs","docs","api","api"], s' || fail "sprint-check-api: the seed's four sources are not served"
# a request url is ignored: with no keys, the two API sources are skipped and nothing else is fetched when only an index is asked for
out="$(env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY curl -s -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d '{"index":2,"url":"https://127.0.0.1/x"}' "$B/api/admin/model-tiers/refresh")"
printf '%s' "$out" | python3 -c 'import sys,json
r=json.load(sys.stdin); assert r["ok"] is True and len(r["sources"])==1 and r["sources"][0]["index"]==2, r
assert r["proposal"]["add"]==[] and r["proposal"]["retire"], r' || fail "sprint-check-api: refresh with one index answered unexpectedly: $out"
# t-d40b: the check time and result are kept with the source that was visited, in the data dir, and only for that one
tiers_json | python3 -c 'import sys,json,datetime
d=json.load(sys.stdin); s=d["sources"]
assert "checked_at" not in s[0] and "checked_at" not in s[3], s
assert s[2]["last_ok"] is False and s[2]["last_status"]=="key not set", s[2]
datetime.datetime.strptime(s[2]["checked_at"], "%Y-%m-%dT%H:%M:%SZ")' || fail "sprint-check-api: refresh did not record when the visited source was checked"
[[ "$(shasum "$SEED_TIERS" | cut -d' ' -f1)" == "$seed_sha" ]] || fail "sprint-check-api: refresh changed the tracked seed"
printf '%s' "$out" | python3 -c 'import sys,json
r=json.load(sys.stdin); assert r["data"]["sources"][2]["checked_at"], r' || fail "sprint-check-api: the refresh answer does not carry the registry with the check times"
apply_ok="$(curl -s -w '\n%{http_code}' -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' \
  -d '{"add":[{"id":"claude-haiku-5-6","provider":"anthropic","name":"Claude Haiku 5.6","input_price":0.1,"output_price":0.5}],"retire":[{"old":"claude-haiku-4-5-20251001","new":"claude-haiku-5-6"}]}' "$B/api/admin/model-tiers/apply")"
[[ "$(printf '%s' "$apply_ok" | tail -1)" == 200 ]] || fail "sprint-check-api: apply was rejected: $apply_ok"
tiers_json | python3 -c 'import sys,json
d=json.load(sys.stdin); m={e["id"]:e for e in d["models"]["anthropic"]}
assert m["claude-haiku-5-6"].get("alias")=="haiku" and m["claude-haiku-4-5-20251001"].get("legacy") is True, m' || fail "sprint-check-api: apply did not add the model and retire the old one"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d '{"add":[{"id":"claude-opus-5-5","provider":"anthropic","name":"x"}]}' "$B/api/admin/model-tiers/apply")" == 400 ]] || fail "sprint-check-api: apply of an id already in the registry should 400"
[[ "$(tiers_post '{"reset":true}')" == 200 ]] || fail "sprint-check-api: reset after the t-d40b checks failed"

# ── t-9b2d: GET /static/<name> — the board's own CSS/JS ─────────────────────
# A second board runs from a temp copy of the app folder, so fixture files and links never touch the tracked tree; its
# binary is built into that copy's tools/ so its toolsDir finds the copied app.html.
SAPP="$(mktemp -d)"
mkdir -p "$SAPP/tools/sprint-check-app/static/sub"
cp "$ROOT/tools/sprint-check-app/app.html" "$SAPP/tools/sprint-check-app/"
SGO_BIN="$(build_board "$SAPP/tools")"
S="$SAPP/tools/sprint-check-app/static"
printf 'body{color:red}' > "$S/board-a.css"
printf 'export const x = 1;' > "$S/editor.js"
printf 'secret-html' > "$S/page.html"
printf 'secret-sub' > "$S/sub/x.css"
printf 'secret-txt' > "$S/notes.txt"
ln -s "$SAPP/tools/sprint-check-app/app.html" "$S/out.css"   # leads out of static/
ln -s "$S/notes.txt" "$S/in.css"                             # stays inside, but is not static/in.css
SGO_PORT="$(free_port)"
SPRINT_CHECK_ROOT="$WORK" CANON_HOME="$GO_CANON" SPRINT_CHECK_NO_BROWSER=1 COCKPIT_STATE_DIR="$CK_STATE" COCKPIT_DAEMON_BIN="$CK_BIN" TMPDIR="$WORK" "$SGO_BIN" "$SGO_PORT" >/dev/null 2>&1 &
SGO_PID=$!
disown "$SGO_PID" 2>/dev/null || true
wait_for_port "$SGO_PORT" || fail "sprint-check-api: the /static/ board did not start"
SBODY="$SAPP/body"
# static_get <path> [curl args...] -> prints "<code> <content-type> | <cache-control>"; body in $SBODY
static_get() {
  local p="$1"; shift
  curl -s --path-as-is -o "$SBODY" -D "$SAPP/hdr" -w '%{http_code}' "$@" "http://127.0.0.1:$SGO_PORT$p" || true
  printf ' %s | %s' "$(grep -i '^content-type:' "$SAPP/hdr" | cut -d' ' -f2- | tr -d '\r')" \
    "$(grep -i '^cache-control:' "$SAPP/hdr" | cut -d' ' -f2- | tr -d '\r')"
}
for c in "board-a.css|text/css; charset=utf-8|body{color:red}" "editor.js|text/javascript; charset=utf-8|export const x = 1;"; do
  IFS='|' read -r name ctype body <<<"$c"
  got="$(static_get "/static/$name")"
  [[ "$got" == "200 $ctype | no-store" ]] || fail "sprint-check-api: /static/$name gave '$got'"
  [[ "$(cat "$SBODY")" == "$body" ]] || fail "sprint-check-api: /static/$name body differs"
done
# Every spelling below must be refused: no 200, and no fixture secret or app.html bytes (__canonProject).
for p in '/static/../app.html' '/static/%2e%2e/app.html' '/static/..%2fapp.html' '/static/%2e%2e%2fcockpit.html' \
         '/static/sub/x.css' '/static/BOARD-A.CSS' '/static/board-a.CSS' '/static/page.html' '/static/.css' \
         '/static/board-a.css%00' '/static/..%5capp.html' '/static/..\app.html' '/static/out.css' '/static/in.css' \
         '/static/notes.txt' '/static/missing.css' '/static/' '/static/%2fetc%2fpasswd.css' '/static//etc/hosts'; do
  code="$(static_get "$p" | cut -d' ' -f1)"
  [[ "$code" != 200 && "$code" != 000 && "$code" != 500 ]] || fail "sprint-check-api: $p gave $code, want a clean refusal"
  if grep -q 'secret\|__canonProject' "$SBODY"; then fail "sprint-check-api: $p leaked file bytes"; fi
done
code="$(static_get /static/board-a.css -H 'Host: evil.example' | cut -d' ' -f1)"
[[ "$code" == 403 ]] || fail "sprint-check-api: /static/ was served to a bad Host ($code)"
# Hostile loop: 300 seeded random names from a nasty alphabet. A 200 must be one of the two fixtures; a 000 (dropped
# connection) or 500 is a crash.
static_names="$(python3 -c '
import random
r = random.Random(0x9b2d)
A = "abz09-._/%\\~AZ:;@"
for _ in range(300):
    print("".join(r.choice(A) for _ in range(r.randint(0, 14))))
')"
static_count=0
while IFS= read -r name; do
  code="$(static_get "/static/$name" | cut -d' ' -f1)"
  case "$code" in
    000|500) fail "sprint-check-api: crashed on /static/$name ($code)" ;;
    200) [[ "$(cat "$SBODY")" == 'body{color:red}' || "$(cat "$SBODY")" == 'export const x = 1;' ]] \
           || fail "sprint-check-api: unexpected bytes for /static/$name" ;;
  esac
  static_count=$((static_count + 1))
done <<<"$static_names"
[[ "$static_count" -eq 300 ]] || fail "sprint-check-api: the hostile loop ran $static_count names, want 300"

echo "sprint-check-api: ok ($route_count routes pinned; /api/tickets models_used + ci + gate + type_outcome + doc names; ticket-image/-feature serve the fixture and refuse traversal/wrong type/missing; /visual refusals, >8MB cap, collision suffix; headless-run idle/running/done + gate:eval dispatch; create writes gate/eval_override/skills/demo/ISO created; demo toggle; ci-workflow template + refuse-on-exists; worktrees ticket_present; cockpit-docs worktree-only; cockpit stale + build stamp; version; registry + scoped reads/writes; register-skill allowlist + ASSUME_YES; model tiers in the data dir; /static/ refusals + 300 hostile names)"
