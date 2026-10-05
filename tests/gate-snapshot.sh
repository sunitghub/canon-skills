#!/usr/bin/env bash
# gate-snapshot (t-bb2d): a gate subagent is read-only by contract, so the orchestrator snapshots the repo before a dispatch and
# compares after. Live trigger: an evaluator's probe ran with the real checkout as its cwd and renamed the branch, committed junk,
# wrote files and overwrote the audit log, none of which `git status --porcelain` alone shows.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

TOOL="$ROOT/tools/gate-snapshot.sh"
[[ -x "$TOOL" ]] || fail "tools/gate-snapshot.sh is missing or not executable"

proj="$(make_project)"; scratch="$(mktemp -d)"
trap 'rm -rf "$proj" "$scratch" "${nogit:-}"' EXIT
cd "$proj"
git config user.email t@example.com; git config user.name test
mkdir -p src .claude .tickets/t-x; echo 'a' > src/app.js; echo 'k' > keep.txt; echo '{}' > .claude/subagent-runs.jsonl; echo 't' > .tickets/t-x/ticket.md
printf '.claude/\n' > .gitignore   # .tickets/ is tracked here, as in a consumer project
git add -A >/dev/null && git commit -qm base
snap="$scratch/snap"
orig="$(git branch --show-current)"   # the default branch name depends on the machine

take() { "$TOOL" pre "$snap" > "$scratch/pre.out" 2>&1; }
differs() { # <what the post must name>
  local out; out="$(run_fail "$TOOL" post "$snap")"
  assert_contains "$out" "$1"; assert_contains "$out" "STOP"
}

# nothing changed, and a read-only gate's own report under .tickets/ is not a difference
take; assert_contains "$(cat "$scratch/pre.out")" "recovery"
"$TOOL" post "$snap" >/dev/null || fail "an untouched repo must pass"
echo 'report' > .tickets/t-x/eval-report.md; echo 'edited' >> .tickets/t-x/ticket.md   # a new file and an edit of a tracked ticket file
"$TOOL" post "$snap" >/dev/null || fail "a new file and an edit under .tickets/ must be ignored"

# a read-only gate that only reads git still passes
git log --oneline -1 >/dev/null; git diff --name-only HEAD >/dev/null; git status --porcelain >/dev/null
"$TOOL" post "$snap" >/dev/null || fail "read-only git must pass"

# the incident: a probe rename the branch, committed junk, wrote files and overwrote the audit log
take
git branch -m "$orig" renamed; echo 'junk' > junk.txt; git add junk.txt; git commit -qm junk; echo '{"x":1}' > .claude/subagent-runs.jsonl
out="$(run_fail "$TOOL" post "$snap")"
assert_contains "$out" "BRANCH changed"; assert_contains "$out" "HEAD moved"; assert_contains "$out" "audit log"; assert_contains "$out" "STOP"
git branch -m renamed "$orig"; git reset -q --hard HEAD~1; echo '{}' > .claude/subagent-runs.jsonl
"$TOOL" post "$snap" >/dev/null || fail "after restoring, the repo must pass again"

# each detection on its own
take; git commit -q --allow-empty -m "empty commit"; differs "HEAD moved: "; git reset -q --hard HEAD~1
take; git branch extra; differs "refs changed"; git branch -q -D extra
take; git tag v-junk; differs "refs changed"; git tag -d v-junk >/dev/null
take; git branch -m "$orig" other; differs "BRANCH changed"; git branch -m other "$orig"
take; echo 'j' > src/new-file.js; differs "src/new-file.js"; rm src/new-file.js
take; mkdir -p deep/dir; echo 'j' > deep/dir/f.txt; differs "deep/dir/f.txt"; rm -rf deep
take; rm keep.txt; differs "keep.txt"; git checkout -q keep.txt
take; echo 'edit' >> src/app.js; differs "src/app.js"; git checkout -q src/app.js
take; echo '{"y":2}' > .claude/subagent-runs.jsonl; differs "audit log"; echo '{}' > .claude/subagent-runs.jsonl

# a file that was already modified before the dispatch: a further edit (same porcelain line) is still seen
echo 'pre-existing edit' >> src/app.js
take; echo 'second edit' >> src/app.js; differs "uncommitted content"
git checkout -q src/app.js

# a staged change shows up too, and a history rewrite is named as one
take; echo 's' > staged.txt; git add staged.txt; differs "staged.txt"; git reset -q staged.txt; rm staged.txt
take; git commit -q --amend -m "rewritten base"; differs "HEAD moved"

# the recovery hash is printed when the tree has uncommitted work, and says so when it is clean
echo 'dirty' >> src/app.js
take; assert_contains "$(cat "$scratch/pre.out")" "recovery"; git checkout -q src/app.js

# usage errors
run_fail "$TOOL" >/dev/null; run_fail "$TOOL" bogus "$snap" >/dev/null; run_fail "$TOOL" post "$scratch/missing-file" >/dev/null

# where git cannot be asked (no repository, or no commit yet) it warns and does not block
nogit="$(mktemp -d)"
( cd "$nogit"; out="$("$TOOL" pre "$scratch/ng" 2>&1)"; assert_contains "$out" "skipped"; out="$("$TOOL" post "$scratch/ng" 2>&1)"; assert_contains "$out" "skipped" )
nocommit="$(make_project)"
( cd "$nocommit"; out="$("$TOOL" pre "$scratch/nc" 2>&1)"; assert_contains "$out" "skipped" ); rm -rf "$nocommit"

echo "gate-snapshot: ok (clean pass, .tickets/ ignored, commit/branch/ref/tag/untracked/deleted/edited/staged/audit-log each named, incident reproduced, no-git warns)"
