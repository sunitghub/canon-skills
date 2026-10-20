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
# STUB_CLOUD=1 plays a Claude cloud session: its GitHub proxy refuses GraphQL (t-35d2), so only `gh api` (REST) answers.
if [[ "${STUB_CLOUD:-}" == 1 && "$1" != api ]]; then
  echo "HTTP 403: GraphQL is not allowed through this proxy (https://api.github.com/graphql)" >&2; exit 1
fi
case "$1 $2" in
  "repo view")    echo "${STUB_VIS:-PRIVATE}" ;;
  api\ repos/*/issues/*) [[ "${STUB_FAIL:-}" == api ]] && { echo "HTTP 404: Not Found" >&2; exit 1; }
                  if [[ "${STUB_CRLF:-}" == 1 ]]; then sed 's/$/\r/' "$STUB_BODY"; else cat "$STUB_BODY"; fi ;;
  api\ repos/*)   v="${STUB_VIS:-PRIVATE}"; echo "$v" | tr '[:upper:]' '[:lower:]' ;;
  "label create") exit 0 ;;
  "label list")   echo canon ;;
  "issue create") while [[ $# -gt 0 ]]; do [[ "$1" == --body-file ]] && cp "$2" "$STUB_BODY"; shift; done
                  echo "https://github.com/acme/app/issues/57" ;;
  "issue view")   cat "$STUB_BODY" ;;
  "pr view")      echo "${STUB_PR_HEAD:?}" ;;
  "pr diff")      printf '%s\n' ${STUB_PR_FILES:-docs/x.md} ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$W/bin/gh"
# No network in this test: export's anonymous fallback (curl https://github.com/<repo>) must never decide a result here.
printf '#!/usr/bin/env bash\necho "curl $*" >> "$STUB_LOG"; exit 7\n' > "$W/bin/curl"; chmod +x "$W/bin/curl"
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
printf '# Plan\n\n## Sign-off\nTier: normal\n\n- [x] Plan approved\n\n## Approach\n1. Profile it.\n# a note in the plan, not a part\n2. Fix it.\n\n## Files\n`server.py`\n' > "$d/plan.md"
printf '# Research: x\n\n- Polls every 8 s.\n' > "$d/research.md"
"$TKT" send-issue "$id" >/dev/null

B="$W/cloud"; mkdir "$B" && git -C "$B" init -q && git -C "$B" remote add origin https://github.com/acme/app.git
cd "$B"
export STUB_CLOUD=1   # everything the cloud session runs, up to "Back on the laptop", goes through REST only
# gh cannot read the issue: exit 1, gh's error and the --body-file hint, nothing written.
rc=0; out="$(STUB_FAIL=api "$TKT" import-issue 57 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a failing gh api should exit 1, got $rc"
assert_contains "$out" "HTTP 404: Not Found"; assert_contains "$out" "add --body-file <file>"
[[ ! -e .tickets/$id ]] || fail "a failed import wrote .tickets/$id"
"$SPRINT" import-issue 57 > "$W/import.out"
e="$B/.tickets/$id"
assert_grep "^github: acme/app#57$" "$e/ticket.md"
grep -q '^runs:' "$e/ticket.md" && fail "the cloud's ticket says runs: (t-718b: there the work is local)"
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
assert_grep '^2. Fix it.$' "$e/plan.md"                        # a top-level "# " line in a section is content, not a part
assert_grep '^- Polls every 8 s.$' "$e/research.md"

# An issue edited on github.com comes back with CRLF: it imports identical to the LF body, but for the creation time (t-35d2).
for v in lf crlf; do
  mkdir "$W/$v" && git -C "$W/$v" init -q && git -C "$W/$v" remote add origin https://github.com/acme/app.git
  (cd "$W/$v" && STUB_CRLF=$([[ $v == crlf ]] && echo 1 || echo 0) "$TKT" import-issue 57 >/dev/null 2>&1) || fail "import-issue ($v) failed"
done
grep -q $'\r' "$W/crlf/.tickets/$id/ticket.md" && fail "a CR reached ticket.md"
diff -r -I "^created: " "$W/lf/.tickets" "$W/crlf/.tickets" >/dev/null || fail "a CRLF issue body imported differently: $(diff -r "$W/lf/.tickets" "$W/crlf/.tickets" | head -5)"

# --body-file: no gh read at all.
C="$W/cloud2"; mkdir "$C" && git -C "$C" init -q && git -C "$C" remote add origin https://github.com/acme/app.git
cd "$C"; : > "$STUB_LOG"
assert_eq "$id" "$("$TKT" import-issue 57 --body-file "$STUB_BODY" 2>/dev/null)"
grep -qE '^(issue view|api )' "$STUB_LOG" && fail "--body-file still read the issue through gh"
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
assert_eq "my local plan" "$(cat ".tickets/$id/.before-import/plan.md")"   # --force kept what it replaced

# ---- 2. export → import-results ----
git init -q --bare "$W/origin.git"
X="$W/cloud-x"; git clone -q "$W/origin.git" "$X" 2>/dev/null; cd "$X"
# origin looks like GitHub (export checks its visibility); pushes still land in the bare repo.
git remote set-url origin https://github.com/acme/app.git && git config url."$W/origin.git".pushInsteadOf https://github.com/acme/app.git
printf '.tickets/\n' > .gitignore && git add .gitignore && git commit -qm init && git push -q origin HEAD:main
mkdir -p ".tickets/$id/evidence" && cp "$e/ticket.md" "$e/acceptance.md" ".tickets/$id/"
sed -i.bak 's/^status: in_progress$/status: closed/' ".tickets/$id/ticket.md" && rm ".tickets/$id/ticket.md.bak"
printf 'graded-head: %s\n## Verdict\npass: all criteria met\n' "$(git rev-parse HEAD)" > ".tickets/$id/eval-report.md"
printf 'cloud plan\n' > ".tickets/$id/plan.md"
printf '\x00\x01binary\xff' > ".tickets/$id/evidence/report.json"
# t-a83a: evidence stamped on another OS (twice), on this machine's, with a hostile line 3, and in a subfolder (not read)
for n in 1 2; do printf 'HEAD 0 T\n$ true\n# on Plan9 4.0 mips; bash 5.2.0\nexit 0\n' > ".tickets/$id/evidence/a$n.log"; done   # sorted first, so a dedupe that sees only the latest OS fails
printf 'HEAD 0 T\n$ true\nPlan8 output on line 3\nexit 0\n' > ".tickets/$id/evidence/oldfmt.log"   # an older log: line 3 is output, never an OS
printf 'HEAD 0 T\n$ true\n# on    ; bash 5\nexit 0\n' > ".tickets/$id/evidence/empty.log"   # blank OS: no note
printf 'HEAD 0 T\n$ %s\n# on Haiku R1 x86; bash 5\nexit 0\n' "$(head -c 3000 /dev/zero | tr '\0' y)" > ".tickets/$id/evidence/longcmd.log"   # line 3 read past a long line 2
printf 'HEAD 0 T\n$ true\n# on %s; bash 3.2.57\nexit 0\n' "$(uname -srm)" > ".tickets/$id/evidence/here.log"
printf 'HEAD 0 T\n$ true\n# on Evil\x1b[2J\x07 1.0 \xc2\x9b%s; bash 5\r\nexit 0\n' "$(head -c 3000 /dev/zero | tr '\0' x)" > ".tickets/$id/evidence/hostile.log"
mkdir -p ".tickets/$id/evidence/old" && printf 'HEAD 0 T\n$ true\n# on Hidden 1 x; bash 5\nexit 0\n' > ".tickets/$id/evidence/old/hidden.log"
printf '/tmp/x\n' > ".tickets/$id/.cockpit-cwd"
st_before="$(git status --porcelain)"; idx_before="$(git ls-files -s | cksum)"
# A public repo: refused, nothing pushed.
rc=0; out="$(STUB_VIS=PUBLIC "$TKT" export "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "export to a public repo should be refused"; assert_contains "$out" "acme/app is PUBLIC"
[[ -z "$(git --git-dir="$W/origin.git" branch --list "canon-results/*")" ]] || fail "a refused export pushed a branch"
out="$("$TKT" export "$id" 2>/dev/null)"
assert_contains "$out" "pushed .tickets/$id/ to canon-results/$id"
files="$(git --git-dir="$W/origin.git" ls-tree -r --name-only "canon-results/$id" | tr '\n' ' ')"
assert_eq ".tickets/$id/acceptance.md .tickets/$id/eval-report.md .tickets/$id/evidence/a1.log .tickets/$id/evidence/a2.log .tickets/$id/evidence/empty.log .tickets/$id/evidence/here.log .tickets/$id/evidence/hostile.log .tickets/$id/evidence/longcmd.log .tickets/$id/evidence/old/hidden.log .tickets/$id/evidence/oldfmt.log .tickets/$id/evidence/report.json .tickets/$id/plan.md .tickets/$id/ticket.md " "$files"
assert_eq "$st_before" "$(git status --porcelain)"
assert_eq "$idx_before" "$(git ls-files -s | cksum)"

# A ticket.md whose id points outside its folder (a cloned repo controls it): refused, nothing pushed.
mkdir -p .tickets/t-evil1 && printf -- '---\nid: ../../.git\nstatus: closed\n---\n# x\n' > .tickets/t-evil1/ticket.md
rc=0; out="$("$TKT" export ../../.git 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "export of a ticket whose id leaves its folder should be refused"
assert_contains "$out" "does not belong to a ticket folder named by its id"
[[ -z "$(git --git-dir="$W/origin.git" branch --list 'canon-results/../*' 'canon-results/.git*')" ]] || fail "a refused export pushed a branch"
rm -rf .tickets/t-evil1

# Tracked .tickets/: nothing pushed, told to commit it with the PR.
T="$W/tracked"; git clone -q "$W/origin.git" "$T" 2>/dev/null; cd "$T"
git remote set-url origin https://github.com/acme/app.git
rm -f .gitignore; mkdir -p ".tickets/$id" && cp "$e/ticket.md" ".tickets/$id/"
assert_contains "$("$TKT" export "$id")" "commit it on the PR branch"
assert_eq "1" "$(git --git-dir="$W/origin.git" branch --list "canon-results/*" | grep -c .)"

# Back on the laptop: files byte-for-byte, a local edit kept aside, github: kept, branch deleted, PR head checked.
unset STUB_CLOUD
L="$W/laptop2"; git clone -q "$W/origin.git" "$L" 2>/dev/null; cd "$L"
mkdir -p ".tickets/$id" && cp "$A/$d/ticket.md" "$A/$d/plan.md" ".tickets/$id/"
export STUB_PR_HEAD; # every board and Go path is a trigger on its own (the failed check keeps the branch, so the head still mismatches); a high-risk plan is one too
for f in tests/run-board-spec.sh tests/board-spec-baseline.json tools/sprint-check-app/x.js; do
  out="$(STUB_PR_HEAD=0000000000000000000000000000000000000000 STUB_PR_FILES="$f" "$TKT" import-results "$id" --pr 58 2>&1)" || true; assert_contains "$out" "re-grade needed on this Mac: board change (full board spec), PR head"
done
for f in tools/canon-go/internal/board/x.go tools/canon-go/go.mod tools/sprint-headless-json-go/x.go; do   # t-8020: the board+daemon module
  out="$(STUB_PR_HEAD=0000000000000000000000000000000000000000 STUB_PR_FILES="$f" "$TKT" import-results "$id" --pr 58 2>&1)" || true; assert_contains "$out" "re-grade needed on this Mac: Go change (needs a release), PR head"
done
# the high-risk trigger reads the imported plan, which import-results itself replaces: call the function on a plan file
eval "$(sed -n '/^_regrade_triggers() {/,/^}/p' "$TKT")"
mkdir -p "$W/hr"; printf '## Sign-off\nTier: normal | Risk: high\n' > "$W/hr/plan.md"
assert_eq "high-risk ticket" "$(printf 'docs/x.md\n' | _regrade_triggers "$W/hr" 0)"
printf '## Sign-off\nTier: normal | Risk: low\n' > "$W/hr/plan.md"
assert_eq "" "$(printf 'docs/x.md\n' | _regrade_triggers "$W/hr" 0)"
mkdir -p ".tickets/$id/evidence" "$W/outside" && printf 'HEAD 0 T\n$ true\n# on Linked 1 x; bash 5\nexit 0\n' > "$W/outside/l.log"
ln -sf "$W/outside/l.log" ".tickets/$id/evidence/zz-link.log"; mkdir -p ".tickets/$id/evidence/dir.log"   # never followed / not a file
STUB_PR_HEAD="$(git -C "$X" rev-parse HEAD)"
out="$("$TKT" import-results "$id" --pr 58)"
for f in acceptance.md eval-report.md evidence/report.json plan.md; do cmp -s "$X/.tickets/$id/$f" ".tickets/$id/$f" || fail "$f did not come back byte-for-byte"; done
cmp -s "$A/$d/plan.md" ".tickets/$id/.before-import/plan.md" || fail "the local plan.md was not kept in .before-import/"
assert_grep "^github: acme/app#57$" ".tickets/$id/ticket.md"
assert_grep "^runs: github$" ".tickets/$id/ticket.md"     # t-718b: the laptop's runs: survives the cloud's ticket.md
assert_contains "$out" "status: closed"
assert_contains "$out" "evaluator: pass"
assert_contains "$out" "matches graded-head"
# t-a83a: one line per foreign OS, sanitized and capped; this machine's OS and subfolders say nothing
assert_contains "$out" "  evidence ran on: Plan9 4.0 mips (this machine: $(uname -srm))"
assert_eq 1 "$(printf '%s\n' "$out" | grep -c 'evidence ran on: Plan9')"
assert_eq 3 "$(printf '%s\n' "$out" | grep -c 'evidence ran on: ')"; assert_contains "$out" "  evidence ran on: Haiku R1 x86 (this machine: "
hl="$(printf '%s\n' "$out" | grep 'evidence ran on: Evil')"
[[ "$hl" != *[^A-Za-z0-9._\ /=:+,?\(\)-]* ]] || fail "import-results echoed a raw byte: $(printf '%q' "$hl")"
[[ "$hl" == "  evidence ran on: Evil??2J? 1.0 ??xxx"* && ${#hl} -lt 160 ]] || fail "import-results did not sanitize or cap line 3: $(printf '%q' "$hl")"
[[ "$out" != *Hidden* && "$out" != *"evidence ran on: $(uname -s) "* ]] || fail "import-results named a subfolder log or this machine's OS"
[[ "$out" != *Linked* && "$out" != *Plan8* && "$out" != *"evidence ran on:  ("* ]] || fail "import-results read a symlink, an older log's output line or an empty # on line: $out"
# t-278d: the closing line names the re-grade triggers (advice only). Docs and non-Go tools: none; the board: its trigger.
assert_contains "$out" "no re-grade needed"
[[ -z "$(git --git-dir="$W/origin.git" branch --list "canon-results/$id")" ]] || fail "canon-results/$id was not deleted"
# A PR head the evaluator did not grade: exit 1.
cd "$X" && "$TKT" export "$id" >/dev/null 2>&1 && cd "$L"
STUB_PR_HEAD=0000000000000000000000000000000000000000
rc=0; out="$("$TKT" import-results "$id" --pr 58 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a PR head that differs from graded-head should exit 1"; assert_contains "$out" "does NOT match graded-head"
[[ -n "$(git --git-dir="$W/origin.git" branch --list "canon-results/$id")" ]] || fail "a failed --pr check deleted canon-results/$id"
# t-278d: triggers by what the PR touches. The branch is kept after a failed check, so import-results can run again on it.
rc=0; out="$(STUB_PR_FILES="tools/sprint-check-app/server.js docs/x.md" "$TKT" import-results "$id" --pr 58 2>&1)" || rc=$?
assert_contains "$out" "re-grade needed on this Mac: board change (full board spec), PR head not confirmed as the graded head"
rc=0; out="$(STUB_PR_FILES="tools/canon-go/internal/daemon/main.go" "$TKT" import-results "$id" --pr 58 2>&1)" || rc=$?
assert_contains "$out" "re-grade needed on this Mac: Go change (needs a release), PR head not confirmed as the graded head"
# tools/tkt is one script, not a release asset: a change to it alone is not a trigger; the board spec file and runner are.
rc=0; out="$(STUB_PR_FILES="tools/tkt tests/tkt-send-issue.sh" "$TKT" import-results "$id" --pr 58 2>&1)" || rc=$?
assert_contains "$out" "re-grade needed on this Mac: PR head not confirmed as the graded head"
rc=0; out="$(STUB_PR_FILES="tests/sprint-check-app.spec.js" "$TKT" import-results "$id" --pr 58 2>&1)" || rc=$?
assert_contains "$out" "board change (full board spec)"
rc=0; out="$(STUB_PR_FILES="tools/evidence.sh tests/evidence.sh" "$TKT" import-results "$id" --pr 58 2>&1)" || rc=$?
assert_contains "$out" "re-grade needed on this Mac: PR head not confirmed as the graded head"
STUB_PR_HEAD="$(git -C "$X" rev-parse HEAD)"
out="$(STUB_PR_FILES="tools/evidence.sh tests/evidence.sh" "$TKT" import-results "$id" --pr 58 2>&1)"
assert_contains "$out" "no re-grade needed"
# t-fdb1: a head past graded-head by the cloud's learnings sweep counts as the graded code; a code commit after grading does not.
cd "$X" && "$TKT" export "$id" >/dev/null 2>&1 && git checkout -q -b sweep && printf 'row\n' > LEARNINGS.md && git add LEARNINGS.md \
  && git commit -qm sweep && git push -qf origin "HEAD:refs/pull/58/head" && cd "$L"
STUB_PR_HEAD="$(git -C "$X" rev-parse HEAD)"
rc=0; out="$(STUB_PR_FILES="LEARNINGS.md" "$TKT" import-results "$id" --pr 58 2>&1)" || rc=$?
[[ "$rc" == 0 ]] || fail "a late-docs-only head after grading should import with rc 0: $out"
assert_contains "$out" "PR #58 head $STUB_PR_HEAD: graded-head plus late docs only: LEARNINGS.md"
assert_contains "$out" "no re-grade needed"
[[ -z "$(git --git-dir="$W/origin.git" branch --list "canon-results/$id")" ]] || fail "a late-docs-only import kept canon-results/$id"
cd "$X" && "$TKT" export "$id" >/dev/null 2>&1 && mkdir -p tools && printf 'x\n' > tools/x.sh && git add tools/x.sh \
  && git commit -qm code && git push -qf origin "HEAD:refs/pull/58/head" && git checkout -q main && cd "$L"
STUB_PR_HEAD="$(git -C "$X" rev-parse sweep)"
rc=0; out="$(STUB_PR_FILES="LEARNINGS.md tools/x.sh" "$TKT" import-results "$id" --pr 58 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a code commit after grading should exit 1: $out"
assert_contains "$out" "does NOT match graded-head"; assert_contains "$out" "(tools/x.sh)"
[[ -n "$(git --git-dir="$W/origin.git" branch --list "canon-results/$id")" ]] || fail "a code delta deleted canon-results/$id"
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

# A symlink where a ticket file goes (a cloned repo can commit one): nothing is written through it.
printf 'outside\n' > "$W/outside.txt"
rm -f ".tickets/$id/plan.md" && ln -s "$W/outside.txt" ".tickets/$id/plan.md"
cd "$X" && "$TKT" export "$id" >/dev/null 2>&1 && cd "$L"
rc=0; out="$("$TKT" import-results "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "import-results through a symlink should be refused"; assert_contains "$out" "refusing to write through a symlink: $id/plan.md"
assert_eq "outside" "$(cat "$W/outside.txt")"
[[ -n "$(git --git-dir="$W/origin.git" branch --list "canon-results/$id")" ]] || fail "a refused import deleted the branch"
cd "$C"; rm -f ".tickets/$id/research.md" && ln -s "$W/outside.txt" ".tickets/$id/research.md"
rc=0; out="$("$TKT" import-issue 57 --body-file "$STUB_BODY" --force 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "import-issue through a symlink should be refused"; assert_contains "$out" "refusing to write through a symlink"
assert_eq "outside" "$(cat "$W/outside.txt")"
cd "$L"; rm -f ".tickets/$id/plan.md"; git --git-dir="$W/origin.git" branch -D "canon-results/$id" >/dev/null
rc=0; out="$("$TKT" import-results ../etc 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a non-ticket id should be refused"; assert_contains "$out" "not a ticket id"

# t-1cf5: an unfinished cloud sprint comes back open (cloud_status keeps in_progress), so a local sprint in this
# checkout still closes: sprint complete resolves the local ticket, not "multiple in-progress tickets".
sed -i.bak 's/^status: closed$/status: in_progress/' "$X/.tickets/$id/ticket.md" && rm "$X/.tickets/$id/ticket.md.bak"
cd "$X" && "$TKT" export "$id" >/dev/null 2>&1 && cd "$L"
lid="$("$TKT" create "Local sprint" -t task)"; "$TKT" start "$lid" >/dev/null
out="$("$TKT" import-results "$id")"
assert_contains "$out" "status: open (cloud: in_progress)  (expected closed: the cloud sprint did not finish)"
assert_grep "^status: open$" ".tickets/$id/ticket.md"
assert_grep "^cloud_status: in_progress$" ".tickets/$id/ticket.md"
assert_eq "$lid" "$("$TKT" current | awk '{print $1}')"
rc=0; out="$("$SPRINT" complete 2>&1)" || rc=$?
[[ "$rc" == 1 && "$out" != *"multiple in-progress"* ]] || fail "sprint complete saw the imported ticket as in progress (rc $rc): $out"
assert_contains "$out" "$lid"
# The close-from-worktree flow: tkt start still makes it the one in progress (here, with the local one reopened).
"$TKT" reopen "$lid" >/dev/null; "$TKT" start "$id" >/dev/null
assert_eq "$id" "$("$TKT" current | awk '{print $1}')"
"$TKT" reopen "$id" >/dev/null

# No results branch: a clear refusal.
rc=0; out="$("$TKT" import-results "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "importing with no results branch should exit 1"; assert_contains "$out" "has no branch canon-results/$id"

echo "cloud-round-trip: ok"
