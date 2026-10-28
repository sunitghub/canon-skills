#!/usr/bin/env bash
# Cloud round trip (t-554c): tkt send-issue → sprint import-issue rebuilds the same ticket; tkt export → tkt import-results
# brings a cloud sprint's .tickets/<id>/ back. A bare repo plays origin for the pushes; a stub gh plays GitHub.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"   # t-f182: tkt's events go through the board binary

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
  "pr view")      if [[ " $* " == *" isCrossRepository "* ]]; then
                    # the exact question _pr_in_repo asks: a PR number, the ticket's repository, nothing else
                    [[ "$*" =~ ^pr\ view\ [0-9]+\ --repo\ acme/app\ --json\ isCrossRepository\ --jq\ \.isCrossRepository$ ]] || { echo "bad PR question: $*" >&2; exit 9; }
                    [[ "${STUB_CROSS:-}" == fail ]] && { echo "HTTP 502: pr view" >&2; exit 1; }
                    echo "${STUB_CROSS:-false}"
                  else echo "${STUB_PR_HEAD:?}"; fi ;;
  "pr diff")      printf '%s\n' ${STUB_PR_FILES:-docs/x.md} ;;
  "pr list")      printf '%b' "${STUB_PRS:-}" ;;
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
# t-1dec: a real send starts the GitHub trail: the heading, then one dated block with the issue and repo.
gt="$A/$d/github.md"
assert_eq "# GitHub" "$(head -1 "$gt")"; assert_eq 1 "$(grep -c '^## ' "$gt")"
assert_grep '^## [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z — sent$' "$gt"
assert_grep '^issue: https://github.com/acme/app/issues/57$' "$gt"; assert_grep '^repo: acme/app$' "$gt"

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
assert_contains "$(event_line ticket.created "$id")" "\"project\":\"$(cd "$B" && pwd -P)\""   # t-f182: import-issue's own event (the newest for this id), not the sender's
assert_contains "$(event_line ticket.created "$id")" '"title":"Board burns a CPU core"'
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
mkdir -p ".tickets/$id/.before-import" && printf 'old plan\n' > ".tickets/$id/.before-import/plan.md"   # t-41ff: a backup is never exported
st_before="$(git status --porcelain)"; idx_before="$(git ls-files -s | cksum)"
# A public repo: refused, nothing pushed.
rc=0; out="$(STUB_VIS=PUBLIC "$TKT" export "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "export to a public repo should be refused"; assert_contains "$out" "acme/app is PUBLIC"
[[ -z "$(git --git-dir="$W/origin.git" branch --list "canon-results/*")" ]] || fail "a refused export pushed a branch"
out="$("$TKT" export "$id" 2>/dev/null)"
assert_contains "$out" "pushed .tickets/$id/ to canon-results/$id. On your machine: tkt import-results $id --pr <N>, then tkt merge-pr $id"
files="$(git --git-dir="$W/origin.git" ls-tree -r --name-only "canon-results/$id" | tr '\n' ' ')"
assert_eq ".tickets/$id/acceptance.md .tickets/$id/eval-report.md .tickets/$id/evidence/a1.log .tickets/$id/evidence/a2.log .tickets/$id/evidence/empty.log .tickets/$id/evidence/here.log .tickets/$id/evidence/hostile.log .tickets/$id/evidence/longcmd.log .tickets/$id/evidence/old/hidden.log .tickets/$id/evidence/oldfmt.log .tickets/$id/evidence/report.json .tickets/$id/plan.md .tickets/$id/ticket.md " "$files"
assert_eq "$st_before" "$(git status --porcelain)"
assert_eq "$idx_before" "$(git ls-files -s | cksum)"
rm -rf ".tickets/$id/.before-import"

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
out="$("$TKT" export "$id")"; assert_contains "$out" "commit it on the PR branch. On your machine: tkt import-results $id --pr <N>, then tkt merge-pr $id"
assert_eq "1" "$(git --git-dir="$W/origin.git" branch --list "canon-results/*" | grep -c .)"

# Back on the laptop: files byte-for-byte, a local edit kept aside, github: kept, branch deleted, PR head checked.
unset STUB_CLOUD
L="$W/laptop2"; git clone -q "$W/origin.git" "$L" 2>/dev/null; cd "$L"
mkdir -p ".tickets/$id" && cp "$A/$d/ticket.md" "$A/$d/plan.md" "$A/$d/github.md" ".tickets/$id/"
export STUB_PR_HEAD; # every board and Go path is a trigger on its own (the failed check keeps the branch, so the head still mismatches); a high-risk plan is one too
for f in tests/run-board-spec.sh tests/board-spec-baseline.json tools/sprint-check-app/x.js; do
  out="$(STUB_PR_HEAD=0000000000000000000000000000000000000000 STUB_PR_FILES="$f" "$TKT" import-results "$id" --pr 58 2>&1)" || true; assert_contains "$out" "re-grade needed on this Mac: board change (full board spec), PR head"
done
for f in tools/canon-go/internal/board/x.go tools/canon-go/go.mod tools/canon-go/internal/daemon/x.go; do   # t-8020: the board+daemon module
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
[[ "$out" != *"next: tkt land"* ]] || fail "a closed ticket should print no next: line (t-b650): $out"
for f in acceptance.md eval-report.md evidence/report.json plan.md; do cmp -s "$X/.tickets/$id/$f" ".tickets/$id/$f" || fail "$f did not come back byte-for-byte"; done
cmp -s "$A/$d/plan.md" ".tickets/$id/.before-import/plan.md" || fail "the local plan.md was not kept in .before-import/"
assert_grep "^github: acme/app#57$" ".tickets/$id/ticket.md"
assert_grep "^runs: github$" ".tickets/$id/ticket.md"     # t-718b: the laptop's runs: survives the cloud's ticket.md
assert_contains "$out" "status: closed"
assert_contains "$out" "evaluator: pass"
assert_contains "$out" "matches graded-head"
# t-4c09: only the clean import leaves an audit line; the six mismatched imports above were refused
ri="$(cat "$CANON_HOME"/events/*.jsonl | grep -F '"kind":"github.results_imported"' | grep -F "\"ticket\":\"$id\"" || true)"
assert_eq 1 "$(printf '%s\n' "$ri" | grep -c . || true)"
assert_contains "$ri" '"pr":"58"'; assert_contains "$ri" '"source":"tkt"'; [[ "$ri" != *'"actor"'* ]] || fail "a CLI import claimed an actor: $ri"
# t-1dec: the import appended its block after the send block, which stayed byte-identical; the trail holds what the output showed.
gt=".tickets/$id/github.md"; sent_block="$(cat "$A/$d/github.md")"
assert_eq "$sent_block" "$(head -n "$(wc -l < "$A/$d/github.md")" "$gt")"
# (the re-grade loop above imported on mismatched heads six times; each of those is an "import refused" block on the trail, t-41ff)
assert_eq 1 "$(grep -c '^## .* — imported$' "$gt")"
[[ "$(grep -c '^## .* — import refused$' "$gt")" -ge 6 ]] || fail "the mismatched imports were not logged as import refused: $(grep '^## ' "$gt")"
imp="$(awk '/^## .* — imported$/ { b = "" } { b = b $0 "\n" } END { printf "%s", b }' "$gt")"; nblocks="$(grep -c '^## ' "$gt")"
assert_contains "$imp" "files: 13"; assert_contains "$imp" "ticket status: closed"; assert_contains "$imp" "evaluator: pass"
assert_contains "$imp" "graded head: $STUB_PR_HEAD"; assert_contains "$imp" "PR: #58 head $STUB_PR_HEAD: matches graded-head"
assert_contains "$imp" "evidence: Plan9 4.0 mips (this machine:"
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
[[ "$rc" == 1 ]] || fail "a PR head that differs from graded-head should exit 1"; assert_contains "$out" "does NOT match graded-head"; assert_contains "$out" "kept canon-results/$id on origin, since a check failed: fix it and run import-results again"
# t-1dec: the refused import is on the trail too, as its own block.
assert_eq "$((nblocks + 1))" "$(grep -c '^## ' ".tickets/$id/github.md")"
assert_eq "import refused" "$(grep '^## ' ".tickets/$id/github.md" | tail -1 | sed 's/^## [^ ]* — //')"
assert_contains "$(awk '/^## .* — import refused$/ { b = "" } { b = b $0 "\n" } END { printf "%s", b }' ".tickets/$id/github.md")" "PR: #58 head 0000000000000000000000000000000000000000: does NOT match graded-head"
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
# t-75f5: the cloud's audit log after grading (a new file or appended lines) counts the same; the dialog and the card then reach Check & merge.
cd "$X" && "$TKT" export "$id" >/dev/null 2>&1 && git checkout -q sweep && mkdir -p .claude && printf '{"a":1}\n{"a":2}\n{"a":3}\n' > .claude/subagent-runs.jsonl \
  && git add -f .claude/subagent-runs.jsonl && git commit -qm "audit log" && git push -qf origin "HEAD:refs/pull/58/head" && cd "$L"
STUB_PR_HEAD="$(git -C "$X" rev-parse HEAD)"
rc=0; out="$(STUB_PR_FILES="LEARNINGS.md .claude/subagent-runs.jsonl" "$TKT" import-results "$id" --pr 58 2>&1)" || rc=$?
[[ "$rc" == 0 ]] || fail "a head that only added the audit log after grading should import with rc 0: $out"
assert_contains "$out" "PR #58 head $STUB_PR_HEAD: graded-head plus late docs only: .claude/subagent-runs.jsonl, LEARNINGS.md"
assert_contains "$out" "no re-grade needed"
cd "$X" && "$TKT" export "$id" >/dev/null 2>&1 && mkdir -p tools && printf 'x\n' > tools/x.sh && git add tools/x.sh \
  && git commit -qm code && git push -qf origin "HEAD:refs/pull/58/head" && git checkout -q main && cd "$L"
STUB_PR_HEAD="$(git -C "$X" rev-parse sweep)"
rc=0; out="$(STUB_PR_FILES="LEARNINGS.md tools/x.sh" "$TKT" import-results "$id" --pr 58 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a code commit after grading should exit 1: $out"
assert_contains "$out" "does NOT match graded-head"; assert_contains "$out" "(tools/x.sh)"
assert_contains "$out" "next: tkt land $id --pr 58 --fix"   # t-75f5: the cloud closed the ticket; `land` without --fix refuses a closed one, so the way out is named
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
assert_contains "$out" "  next: tkt land $id"; assert_contains "$out" "the cloud's evaluator run record cannot travel"   # t-b650
assert_grep "^status: open$" ".tickets/$id/ticket.md"
assert_grep "^cloud_status: in_progress$" ".tickets/$id/ticket.md"
assert_contains "$(event_line ticket.status_changed "$id")" '"from":"in_progress","ticket":"'"$id"'","to":"open"'   # t-f182
assert_eq "$lid" "$("$TKT" current | awk '{print $1}')"
# t-b650: the same unfinished ticket imported with --pr names it in the step; a pass report says the cloud's pass will not do.
cd "$X" && "$TKT" export "$id" >/dev/null 2>&1 && cd "$L"
out="$("$TKT" import-results "$id" --pr 58 2>&1)" || true
assert_contains "$out" "  next: tkt land $id --pr 58"
assert_contains "$out" "so its pass will not satisfy the local close"
[[ "$out" != *"--fix"* ]] || fail "an open (unfinished) cloud ticket must not be told to land --fix (plain land works for it): $out"   # t-75f5
rm -f "$X/.tickets/$id/eval-report.md" ".tickets/$id/eval-report.md"; cd "$X" && "$TKT" export "$id" >/dev/null 2>&1 && cd "$L"
out="$("$TKT" import-results "$id" 2>&1)" || true
assert_contains "$out" "  next: tkt land $id"; assert_contains "$out" "and no report is all that came back"
# t-75f5: a closed ticket with no report has no graded head to differ from: no --fix hint (there is nothing to re-grade against).
sed -i.bak 's/^status: in_progress$/status: closed/' "$X/.tickets/$id/ticket.md" && rm "$X/.tickets/$id/ticket.md.bak"
cd "$X" && "$TKT" export "$id" >/dev/null 2>&1 && cd "$L"
rc=0; out="$("$TKT" import-results "$id" --pr 58 2>&1)" || rc=$?
[[ "$out" != *"--fix"* ]] || fail "a closed ticket with no evaluator report must not name land --fix: $out"
rc=0; out="$("$SPRINT" complete 2>&1)" || rc=$?
[[ "$rc" == 1 && "$out" != *"multiple in-progress"* ]] || fail "sprint complete saw the imported ticket as in progress (rc $rc): $out"
assert_contains "$out" "$lid"
# The close-from-worktree flow: tkt start still makes it the one in progress (here, with the local one reopened).
"$TKT" reopen "$lid" >/dev/null; "$TKT" start "$id" >/dev/null
assert_eq "$id" "$("$TKT" current | awk '{print $1}')"
"$TKT" reopen "$id" >/dev/null

# t-07b5: a project that commits .tickets/ has no results branch: the closed ticket rides in the PR, so import-results reads it from
# the PR's head. Protects: `tkt import-results` and the Factory card's Import results button for such a project.
git --git-dir="$W/origin.git" update-ref -d "refs/heads/canon-results/$id" 2>/dev/null || true
cd "$X" && git checkout -q -b tracked main && sed -i.bak 's/^status: .*$/status: closed/' ".tickets/$id/ticket.md" && rm -f ".tickets/$id/ticket.md.bak" && printf 'graded-head: %s\n## Verdict\npass: all criteria met\n' "$(git rev-parse HEAD)" > ".tickets/$id/eval-report.md" \
  && git add -f ".tickets/$id" && git rm -q --cached -f ".tickets/$id/.cockpit-cwd" && git commit -qm "cloud close" && TRK="$(git rev-parse HEAD)" && git push -qf origin "HEAD:refs/pull/60/head" && git checkout -q main
printf 'no tickets here\n' > "$W/notes.txt"; git -C "$X" checkout -q -b bare main && git -C "$X" rm -q -r --cached .tickets 2>/dev/null || true
git -C "$X" commit -qm "no ticket" --allow-empty && git -C "$X" push -qf origin "HEAD:refs/pull/61/head" && git -C "$X" checkout -q main
git -C "$X" checkout -q -b noticket main && mkdir -p ".tickets/$id" 2>/dev/null; printf 'notes only\n' > "$X/.tickets/$id/plan.md" && git -C "$X" add -f ".tickets/$id/plan.md" \
  && git -C "$X" commit -qm "folder without ticket.md" && git -C "$X" push -qf origin "HEAD:refs/pull/63/head" && git -C "$X" checkout -q main
L3="$W/laptop3"; git clone -q "$W/origin.git" "$L3" 2>/dev/null; cd "$L3"
mkdir -p ".tickets/$id" && cp "$A/$d/ticket.md" "$A/$d/plan.md" ".tickets/$id/"
printf '60\tOPEN\t%s\n' "$TRK" > "$W/prs3"
out="$(STUB_PRS="$(cat "$W/prs3")\n" STUB_PR_HEAD="$TRK" "$TKT" import-results "$id" 2>&1)" || fail "import from a PR head (PR found through the github: line) failed: $out"
for f in acceptance.md eval-report.md evidence/report.json; do git -C "$X" show "$TRK:.tickets/$id/$f" | cmp -s - ".tickets/$id/$f" || fail "$f did not come back byte-for-byte from the PR head"; done
cmp -s "$A/$d/plan.md" ".tickets/$id/.before-import/plan.md" || fail "the local plan.md was not kept in .before-import/"
assert_contains "$out" "read from PR #60's head"; assert_contains "$out" "status: closed"; assert_contains "$out" "evaluator: pass"
[[ "$out" != *"could not delete"* ]] || fail "it tried to delete a results branch that never existed: $out"
assert_contains "$(cat "$CANON_HOME"/events/*.jsonl | grep -F '"kind":"github.results_imported"' | tail -1)" '"pr":"60"'
# A PR from a fork is anyone's content: refused, nothing written.
rm -rf ".tickets/$id/.before-import"; cp ".tickets/$id/plan.md" "$W/plan.keep"; printf 'local edit\n' > ".tickets/$id/plan.md"
rc=0; out="$(STUB_CROSS=true STUB_PR_HEAD="$TRK" "$TKT" import-results "$id" --pr 60 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a fork's PR should be refused: $out"; assert_contains "$out" "comes from a fork of acme/app"
assert_eq "local edit" "$(cat ".tickets/$id/plan.md")"; [[ ! -e ".tickets/$id/.before-import" ]] || fail "a refused import wrote a backup"
cp "$W/plan.keep" ".tickets/$id/plan.md"
# gh cannot say whether the PR is from a fork: refused with gh's reason, not a guess and not "from a fork".
rc=0; out="$(STUB_CROSS=fail STUB_PR_HEAD="$TRK" "$TKT" import-results "$id" --pr 60 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "an unreadable PR should be refused: $out"; assert_contains "$out" "gh could not read PR #60 on acme/app: HTTP 502"; [[ "$out" != *"from a fork"* ]] || fail "a gh failure was reported as a fork: $out"
# No ticket here and no github: line: the repository comes from origin, which must be a GitHub repo.
L4="$W/laptop4"; git clone -q "$W/origin.git" "$L4" 2>/dev/null
rc=0; out="$(cd "$L4" && STUB_PR_HEAD="$TRK" "$TKT" import-results "$id" --pr 60 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "no github: line and a non-GitHub origin should be refused: $out"; assert_contains "$out" "origin is not a GitHub repo"
# --pr names the PR directly (no gh lookup); a head with no ticket in it fails naming both places it looked; no PR at all says so.
rc=0; out="$(STUB_PR_HEAD="$TRK" "$TKT" import-results "$id" --pr 61 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a PR head with no ticket should exit 1: $out"
assert_contains "$out" "PR #61's head has no .tickets/$id/ticket.md"; assert_contains "$out" "origin has no branch canon-results/$id either"
assert_contains "$out" $'\n  next: tkt land '"$id"' --pr 61   (close it here, in a worktree at the PR head)'   # t-d0a5
rc=0; out="$(STUB_PR_HEAD=0000000000000000000000000000000000000000 "$TKT" import-results "$id" --pr 60 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a PR head that is not the graded head should exit 1"; assert_contains "$out" "does NOT match graded-head"
assert_contains "$out" "a check failed: run import-results again"; [[ "$out" != *"on origin, since"* ]] || fail "it claimed to keep a branch that never existed: $out"
rc=0; out="$(STUB_PR_HEAD="$TRK" "$TKT" import-results "$id" --pr 63 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a PR head whose ticket folder has no ticket.md should exit 1: $out"; assert_contains "$out" "PR #63's head has no .tickets/$id/ticket.md"
rc=0; out="$(STUB_PR_HEAD="$TRK" "$TKT" import-results "$id" --pr 62 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "a PR with no head on origin should exit 1: $out"; assert_contains "$out" "PR #62's head could not be fetched"
rc=0; out="$("$TKT" import-results "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "no branch and no PR should exit 1"; assert_contains "$out" "origin has no branch canon-results/$id, and there is no PR"
cd "$W"

# No results branch: a clear refusal.
rc=0; out="$("$TKT" import-results "$id" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "importing with no results branch should exit 1"; assert_contains "$out" "has no branch canon-results/$id"

echo "cloud-round-trip: ok"
