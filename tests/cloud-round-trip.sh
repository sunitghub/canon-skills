#!/usr/bin/env bash
# Cloud round trip (t-554c): tkt send-issue → sprint import-issue rebuilds the same ticket; tkt export → tkt import-results
# brings a cloud sprint's .tickets/<id>/ back. A bare repo plays origin for the pushes; a stub gh plays GitHub.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/cloud-round-trip.XXXXXX")"
trap 'rm -rf "$W"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$W/gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git config --global init.defaultBranch main

mkdir "$W/bin"
cat > "$W/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  "repo view")    echo PRIVATE ;;
  "label create") exit 0 ;;
  "label list")   echo canon ;;
  "issue create") while [[ $# -gt 0 ]]; do [[ "$1" == --body-file ]] && cp "$2" "$STUB_BODY"; shift; done
                  echo "https://github.com/acme/app/issues/57" ;;
  "issue view")   cat "$STUB_BODY" ;;
  "pr view")      echo "${STUB_PR_HEAD:?}" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$W/bin/gh"
export PATH="$W/bin:$PATH" STUB_LOG="$W/gh.log" STUB_BODY="$W/issue-body.md"
: > "$STUB_LOG"
sec() { awk -v h="## $2" '$0 == h { f = 1; next } f && /^#{1,2} / { exit } f && !/^<!--/ { print }' "$1" | awk 'NF { s = 1 } s'; }

# ---- 1. send-issue → import-issue rebuilds the same ticket ----
A="$W/laptop"; mkdir "$A" && git -C "$A" init -q && git -C "$A" remote add origin https://github.com/acme/app.git
cd "$A"
id="$("$TKT" create "Board burns a CPU core" -t bug -p 1 -d '## Problem
The board uses a core while idle.

```bash
# a shell comment, not a heading
top -l 1
```

## Outcome
- Idle under 5%')"
d=".tickets/$id"
printf '# Acceptance\n\n## Criteria\n- [ ] Idle CPU under 5%%\n\n## Test Plan\n- [ ] Measure for 60 s\n\n## QA\n- [ ] Tested locally\n\n## Wrapup Gates\n| Gate | Status | Reason |\n|------|--------|--------|\n| eval | ran | pass |\n' > "$d/acceptance.md"
printf '# Plan\n\n## Sign-off\nTier: normal\n\n- [x] Plan approved\n\n## Approach\n1. Profile it.\n\n## Files\n`server.py`\n' > "$d/plan.md"
printf '# Research: x\n\n- Polls every 8 s.\n' > "$d/research.md"
"$TKT" send-issue "$id" >/dev/null

B="$W/cloud"; mkdir "$B" && git -C "$B" init -q && git -C "$B" remote add origin https://github.com/acme/app.git
cd "$B"
"$SPRINT" import-issue 57 > "$W/import.out"
e="$B/.tickets/$id"
assert_grep "^github: acme/app#57$" "$e/ticket.md"
assert_grep "^# Board burns a CPU core$" "$e/ticket.md"
assert_grep "^type: bug$" "$e/ticket.md"
assert_grep "^priority: 1$" "$e/ticket.md"
assert_grep "^status: in_progress$" "$e/ticket.md"            # sprint import-issue started it
assert_contains "$(cat "$W/import.out")" "Sprint started: $id"
for h in Problem Outcome; do assert_eq "$(sec "$A/$d/ticket.md" "$h")" "$(sec "$e/ticket.md" "$h")"; done
assert_grep '^# a shell comment, not a heading$' "$e/ticket.md"   # a "# " line inside a code fence stays content
for h in Criteria "Test Plan" QA "Wrapup Gates"; do assert_eq "$(sec "$A/$d/acceptance.md" "$h")" "$(sec "$e/acceptance.md" "$h")"; done
for h in Sign-off Approach Files; do assert_eq "$(sec "$A/$d/plan.md" "$h")" "$(sec "$e/plan.md" "$h")"; done
assert_grep '^- \[x\] Plan approved$' "$e/plan.md"            # sprint start kept the approved plan
assert_grep '^- Polls every 8 s.$' "$e/research.md"

# --body-file: no gh read at all.
C="$W/cloud2"; mkdir "$C" && git -C "$C" init -q && git -C "$C" remote add origin https://github.com/acme/app.git
cd "$C"; : > "$STUB_LOG"
assert_eq "$id" "$("$TKT" import-issue 57 --body-file "$STUB_BODY" 2>/dev/null)"
grep -q '^issue view' "$STUB_LOG" && fail "--body-file still read the issue through gh"
# Refusals: no marker; a differing file without --force (and nothing written); --force replaces it.
grep -v 'canon:ticket' "$STUB_BODY" > "$W/no-marker.md"
rc=0; out="$("$TKT" import-issue 58 --body-file "$W/no-marker.md" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a body without the marker should be refused"; assert_contains "$out" "no canon:ticket marker"
printf 'my local plan\n' > ".tickets/$id/plan.md"
rc=0; out="$("$TKT" import-issue 57 --body-file "$STUB_BODY" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a differing plan.md should be refused"; assert_contains "$out" "already has different: plan.md"
assert_eq "my local plan" "$(cat ".tickets/$id/plan.md")"
"$TKT" import-issue 57 --body-file "$STUB_BODY" --force >/dev/null 2>&1
assert_grep '^1. Profile it.$' ".tickets/$id/plan.md"

# ---- 2. export → import-results ----
git init -q --bare "$W/origin.git"
X="$W/cloud-x"; git clone -q "$W/origin.git" "$X" 2>/dev/null; cd "$X"
printf '.tickets/\n' > .gitignore && git add .gitignore && git commit -qm init && git push -q origin HEAD:main
mkdir -p ".tickets/$id/evidence" && cp "$e/ticket.md" "$e/acceptance.md" ".tickets/$id/"
sed -i.bak 's/^status: in_progress$/status: closed/' ".tickets/$id/ticket.md" && rm ".tickets/$id/ticket.md.bak"
printf 'graded-head: %s\n## Verdict\npass: all criteria met\n' "$(git rev-parse HEAD)" > ".tickets/$id/eval-report.md"
printf 'cloud plan\n' > ".tickets/$id/plan.md"
printf '\x00\x01binary\xff' > ".tickets/$id/evidence/report.json"
printf '/tmp/x\n' > ".tickets/$id/.cockpit-cwd"
st_before="$(git status --porcelain)"; idx_before="$(git ls-files -s | cksum)"
out="$("$TKT" export "$id" 2>/dev/null)"
assert_contains "$out" "pushed .tickets/$id/ to canon-results/$id"
files="$(git --git-dir="$W/origin.git" ls-tree -r --name-only "canon-results/$id" | tr '\n' ' ')"
assert_eq ".tickets/$id/acceptance.md .tickets/$id/eval-report.md .tickets/$id/evidence/report.json .tickets/$id/plan.md .tickets/$id/ticket.md " "$files"
assert_eq "$st_before" "$(git status --porcelain)"
assert_eq "$idx_before" "$(git ls-files -s | cksum)"

# Tracked .tickets/: nothing pushed, told to commit it with the PR.
T="$W/tracked"; git clone -q "$W/origin.git" "$T" 2>/dev/null; cd "$T"
rm -f .gitignore; mkdir -p ".tickets/$id" && cp "$e/ticket.md" ".tickets/$id/"
assert_contains "$("$TKT" export "$id")" "commit it on the PR branch"
assert_eq "1" "$(git --git-dir="$W/origin.git" branch --list "canon-results/*" | grep -c .)"

# Back on the laptop: files byte-for-byte, a local edit kept aside, github: kept, branch deleted, PR head checked.
L="$W/laptop2"; git clone -q "$W/origin.git" "$L" 2>/dev/null; cd "$L"
mkdir -p ".tickets/$id" && cp "$A/$d/ticket.md" "$A/$d/plan.md" ".tickets/$id/"
export STUB_PR_HEAD; STUB_PR_HEAD="$(git -C "$X" rev-parse HEAD)"
out="$("$TKT" import-results "$id" --pr 58)"
for f in acceptance.md eval-report.md evidence/report.json plan.md; do cmp -s "$X/.tickets/$id/$f" ".tickets/$id/$f" || fail "$f did not come back byte-for-byte"; done
cmp -s "$A/$d/plan.md" ".tickets/$id/.before-import/plan.md" || fail "the local plan.md was not kept in .before-import/"
assert_grep "^github: acme/app#57$" ".tickets/$id/ticket.md"
assert_contains "$out" "status: closed"
assert_contains "$out" "evaluator: pass"
assert_contains "$out" "matches graded-head"
[[ -z "$(git --git-dir="$W/origin.git" branch --list "canon-results/$id")" ]] || fail "canon-results/$id was not deleted"
# A PR head the evaluator did not grade: exit 1.
cd "$X" && "$TKT" export "$id" >/dev/null 2>&1 && cd "$L"
STUB_PR_HEAD=0000000000000000000000000000000000000000
rc=0; out="$("$TKT" import-results "$id" --pr 58 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a PR head that differs from graded-head should exit 1"; assert_contains "$out" "does NOT match graded-head"
# An import that cannot write keeps the branch on origin, so nothing is lost.
if [[ "$(id -u)" != 0 ]]; then
  cd "$X" && "$TKT" export "$id" >/dev/null 2>&1 && cd "$L"
  chmod -R a-w ".tickets/$id"
  rc=0; "$TKT" import-results "$id" >/dev/null 2>&1 || rc=$?
  chmod -R u+w ".tickets/$id"
  [[ "$rc" != 0 ]] || fail "an import into an unwritable folder should fail"
  [[ -n "$(git --git-dir="$W/origin.git" branch --list "canon-results/$id")" ]] || fail "a failed import deleted canon-results/$id"
  "$TKT" import-results "$id" >/dev/null   # a retry once the folder is writable succeeds and then deletes it
  [[ -z "$(git --git-dir="$W/origin.git" branch --list "canon-results/$id")" ]] || fail "canon-results/$id survived a successful retry"
else
  echo "cloud-round-trip: SKIP unwritable-folder case: running as root ignores permissions" >&2
fi

# No results branch: a clear refusal.
rc=0; out="$("$TKT" import-results "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "importing with no results branch should exit 1"; assert_contains "$out" "has no branch canon-results/$id"

echo "cloud-round-trip: ok"
