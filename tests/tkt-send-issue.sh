#!/usr/bin/env bash
# tkt send-issue (t-a059): what it sends to GitHub, and every case it must refuse without touching ticket.md.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
stub="$(mktemp -d "${TMPDIR:-/tmp}/tkt-send-issue.XXXXXX")"
trap 'rm -rf "$project" "$stub"' EXIT
cd "$project"

# A stub gh that logs every call and plays a repo: STUB_VIS (PRIVATE or PUBLIC), STUB_FAIL=create fails issue create,
# STUB_FAIL=view fails repo view (signed out). It saves the body it was given.
cat > "$stub/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  "repo view")    [[ "${STUB_FAIL:-}" == view ]] && { echo "To get started with GitHub CLI, please run: gh auth login" >&2; exit 4; }; echo "${STUB_VIS:-PRIVATE}" ;;
  "label create") exit 0 ;;
  "label list")   echo canon ;;
  "issue create") [[ "${STUB_FAIL:-}" == create ]] && { echo "HTTP 502: server error" >&2; exit 1; }
                  while [[ $# -gt 0 ]]; do [[ "$1" == --body-file ]] && cp "$2" "$STUB_BODY"; shift; done
                  echo "https://github.com/acme/app/issues/57" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$stub/gh"
export PATH="$stub:$PATH" STUB_LOG="$stub/log" STUB_BODY="$stub/body"
writes() { grep -cE '^(issue create|label create)' "$STUB_LOG" || true; }

git remote add origin https://github.com/acme/app.git
id="$("$TKT" create "Board burns a CPU core" -t task -p 1 -d "## Problem
The board uses a core while idle.")"
d=".tickets/$id"
printf '# Acceptance\n\n## Criteria\nThe checklist of behavior that must be true before the sprint can close.\n<!-- Add items -->\n\n- [ ] Idle CPU under 5%%\n  over 60 s\n\n## Test Plan\n- [ ] Measure before and after\n\n## QA\nEdge cases and sign-off.\n- [ ] Tested locally\n\n## Wrapup Gates\n| Gate | Status | Reason |\n|------|--------|--------|\n| eval | ran | pass |\n\n## Results\nAll criteria met on the first run.\n' > "$d/acceptance.md"
printf '# Plan\n\n## Sign-off\n- [x] Plan approved\n\n## Approach\n1. Profile the idle board.\n2. Fix the hot loop.\n\n## Files\n`server.py`\n\n## Decisions\n- none\n' > "$d/plan.md"
printf '# Research: x\n\n- The board polls every 8 s.\n' > "$d/research.md"
sig() { cksum < "$d/ticket.md"; }

# --dry-run: repo, visibility, title and body; no writing call.
: > "$STUB_LOG"
dry="$("$TKT" send-issue "$id" --dry-run)"
assert_contains "$dry" "repo: acme/app (PRIVATE)"
assert_contains "$dry" "title: $id: Board burns a CPU core"
assert_contains "$dry" "dry run: nothing was created"
[[ "$(writes)" == 0 ]] || fail "--dry-run made a writing gh call: $(cat "$STUB_LOG")"

# Send: exact calls, body in the ticket's sections and order, github: recorded only after success.
: > "$STUB_LOG"
out="$("$TKT" send-issue "$id")"
assert_contains "$out" "Sent $id as https://github.com/acme/app/issues/57"
assert_contains "$out" "type: Work on Issue#57"
grep -qx "label create canon --repo acme/app --color 6C5CF7 --description A canon ticket --force" "$STUB_LOG" || fail "label not created: $(cat "$STUB_LOG")"
grep -qx "issue create --repo acme/app --title $id: Board burns a CPU core --label canon --body-file .*" "$STUB_LOG" || fail "wrong issue create call: $(cat "$STUB_LOG")"
assert_grep "^github: acme/app#57$" "$d/ticket.md"
# The issue has the ticket's tree as the board lists it: every section of ticket.md, acceptance.md and plan.md, then Research.
order="$(grep -E '^#{1,2} ' "$STUB_BODY" | tr '\n' '|')"
assert_eq "# Description|## Problem|# Acceptance|## Criteria|## Test Plan|## QA|## Wrapup Gates|## Results|# Plan|## Sign-off|## Approach|## Files|## Decisions|# Research|# Working on this|" "$order"
assert_grep '^| eval | ran | pass |$' "$STUB_BODY"                     # a table section keeps its rows
assert_grep '^All criteria met on the first run.$' "$STUB_BODY"     # and a prose section its text
assert_grep '^- \[ \] Tested locally$' "$STUB_BODY"
assert_grep '^- \[x\] Plan approved$' "$STUB_BODY"
assert_grep '^- \[ \] Idle CPU under 5%$' "$STUB_BODY"
assert_grep '^  over 60 s$' "$STUB_BODY"
assert_grep '^1. Profile the idle board.$' "$STUB_BODY"
assert_grep '^- The board polls every 8 s.$' "$STUB_BODY"
assert_grep "^<!-- canon:ticket $id -->\$" "$STUB_BODY"
grep -q 'The checklist of behavior\|Edge cases and sign-off\|Add items' "$STUB_BODY" && fail "template prompts or comments leaked into the issue"
[[ "$(grep -c '^## Problem$' "$STUB_BODY")" == 1 ]] || fail "the ticket's own Problem heading was doubled"

# Already sent: refused, ticket unchanged, no gh call.
: > "$STUB_LOG"; before="$(sig)"
rc=0; again="$("$TKT" send-issue "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a second send should exit 1, got $rc"
assert_contains "$again" "already sent: acme/app#57"
[[ "$(writes)" == 0 && "$(sig)" == "$before" ]] || fail "a second send called gh or changed the ticket"

# Public repo: refused without --public (ticket unchanged), sent with it.
id2="$("$TKT" create "Public one" -t bug -p 2)"
export STUB_VIS=PUBLIC; : > "$STUB_LOG"; before="$(cksum < ".tickets/$id2/ticket.md")"
rc=0; pub="$("$TKT" send-issue "$id2" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a public repo should be refused, got $rc"
assert_contains "$pub" "acme/app is PUBLIC"
[[ "$(writes)" == 0 && "$(cksum < ".tickets/$id2/ticket.md")" == "$before" ]] || fail "a refused public send called gh or changed the ticket"
"$TKT" send-issue "$id2" --public >/dev/null
assert_grep "^github: acme/app#57$" ".tickets/$id2/ticket.md"
unset STUB_VIS

# Missing acceptance, plan and research: "(none yet)", and a warning.
id3="$("$TKT" create "Bare" -t task -p 3)"
"$TKT" send-issue "$id3" --dry-run > "$stub/bare" 2> "$stub/bare.err"
[[ "$(grep -c '^(none yet)$' "$stub/bare")" == 3 ]] || fail "expected Acceptance, Plan and Research to read (none yet): $(cat "$stub/bare")"
assert_grep "no acceptance criteria" "$stub/bare.err"

# gh fails on create, or is signed out: exit 1, the error shown, ticket byte-identical.
for mode in create view; do
  export STUB_FAIL=$mode; before="$(cksum < ".tickets/$id3/ticket.md")"
  rc=0; err="$("$TKT" send-issue "$id3" 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "gh failing on $mode should exit 1, got $rc"
  [[ "$mode" == create ]] && assert_contains "$err" "HTTP 502" || assert_contains "$err" "gh auth login"
  [[ "$(cksum < ".tickets/$id3/ticket.md")" == "$before" ]] || fail "ticket changed although gh failed on $mode"
done
unset STUB_FAIL

# Origins: ssh forms parse; anything not on GitHub is refused before any gh call.
for u in git@github.com:acme/app.git ssh://git@github.com/acme/app; do
  git remote set-url origin "$u"
  assert_contains "$("$TKT" send-issue "$id3" --dry-run 2>/dev/null)" "repo: acme/app (PRIVATE)"
done
git remote set-url origin https://gitlab.com/acme/app.git; : > "$STUB_LOG"
rc=0; gl="$("$TKT" send-issue "$id3" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a GitLab origin should be refused, got $rc"
assert_contains "$gl" "origin is not a GitHub repo"
[[ ! -s "$STUB_LOG" ]] || fail "gh was called for a non-GitHub origin"

echo "tkt-send-issue: ok"
