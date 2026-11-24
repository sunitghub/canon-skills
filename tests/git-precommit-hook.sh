#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# t-acfa: skills.sh add registers each project in $HOME/.config/canon/projects; a scratch HOME keeps these scratch projects out of the
# user's real registry (which uninstall walks and edits). Every commit below passes its own identity, so no global git config is needed.
scratch_home="$(mktemp -d)"; HOME="$scratch_home"; export HOME

# ── Fresh install ────────────────────────────────────────────────────────────
project="$(make_project)"
trap 'rm -rf "$project" "$scratch_home"' EXIT

"$SKILLS" add sprint "$project" >/dev/null

hook="$project/.git/hooks/pre-commit"
assert_file_exists "$hook"
assert_grep "canon-managed-pre-commit-hook" "$hook"
[[ -x "$hook" ]] || fail "expected pre-commit hook to be executable"

# ── Idempotent re-install ────────────────────────────────────────────────────
before_sum="$(cksum "$hook")"
"$SKILLS" add sprint "$project" >/dev/null
after_sum="$(cksum "$hook")"
assert_eq "$before_sum" "$after_sum"

# ── Conflict with a pre-existing non-canon hook ─────────────────────────────
conflict_project="$(make_project)"
trap 'rm -rf "$project" "$conflict_project" "$scratch_home"' EXIT
mkdir -p "$conflict_project/.git/hooks"
cat > "$conflict_project/.git/hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
echo "user's own hook"
EOF
chmod +x "$conflict_project/.git/hooks/pre-commit"

set +e
output="$("$SKILLS" add sprint "$conflict_project" 2>&1)"
set -e
assert_contains "$output" "already exists and is not canon-managed"
assert_contains "$(cat "$conflict_project/.git/hooks/pre-commit")" "user's own hook"

# ── Behavior: blocks a direct ticket-close edit ─────────────────────────────
behavior_project="$(make_project)"
trap 'rm -rf "$project" "$conflict_project" "$behavior_project" "$scratch_home"' EXIT
"$SKILLS" add sprint "$behavior_project" >/dev/null

(
  cd "$behavior_project"
  mkdir -p .tickets/t-test1
  cat > .tickets/t-test1/ticket.md <<'EOF'
---
id: t-test1
status: open
---
# test
EOF
  git add .tickets/t-test1/ticket.md
  git -c user.email=t@t.com -c user.name=t commit -m "add ticket" -q

  sed -i.bak 's/status: open/status: closed/' .tickets/t-test1/ticket.md
  rm -f .tickets/t-test1/ticket.md.bak
  git add .tickets/t-test1/ticket.md
)

set +e
block_output="$(cd "$behavior_project" && git -c user.email=t@t.com -c user.name=t commit -m "sneaky close" 2>&1)"
block_rc=$?
set -e
[[ "$block_rc" -ne 0 ]] || fail "expected commit to be blocked"
assert_contains "$block_output" "BLOCKED — ticket closed by direct file edit"

# ── Behavior: does NOT block a never-before-committed ticket closed by sprint complete ──
(
  cd "$behavior_project"
  # Clean up t-test1's still-staged edit left behind by the blocked commit above —
  # a failed pre-commit hook does not unstage the index.
  git reset -q HEAD -- .tickets/t-test1/ticket.md
  git checkout -q -- .tickets/t-test1/ticket.md
  mkdir -p .tickets/t-test2
  cat > .tickets/t-test2/ticket.md <<'EOF'
---
id: t-test2
status: closed
---
# test2
EOF
  git add .tickets/t-test2/ticket.md
)

set +e
firstcommit_output="$(cd "$behavior_project" && git -c user.email=t@t.com -c user.name=t commit -m "close via sprint complete" 2>&1)"
firstcommit_rc=$?
set -e
[[ "$firstcommit_rc" -eq 0 ]] || fail "expected first-ever commit of an already-closed ticket to succeed: $firstcommit_output"
[[ "$firstcommit_output" != *"BLOCKED"* ]] || fail "expected no BLOCKED message for a never-before-committed ticket: $firstcommit_output"

# ── Behavior: does NOT block a legit CLI close of a PREVIOUSLY-COMMITTED ticket (t-dec8) ──
# The interim-commit workflow: a ticket is committed once as in_progress, then closed via the
# CLI. `tkt close` co-adds a `closed:` marker line, which the hook uses to allow the close —
# the case the old "never-committed only" exemption could not distinguish from a hand-edit.
(
  cd "$behavior_project"
  mkdir -p .tickets/t-test3
  cat > .tickets/t-test3/ticket.md <<'EOF'
---
id: t-test3
status: in_progress
---
# test3
EOF
  git add .tickets/t-test3/ticket.md
  git -c user.email=t@t.com -c user.name=t commit -m "interim commit (in_progress)" -q
  "$TKT" close t-test3 --no-sprint >/dev/null   # real CLI close → adds `closed:` marker
  grep -qE "^closed: " .tickets/t-test3/ticket.md || fail "expected tkt close to add a closed: marker"
  git add .tickets/t-test3/ticket.md
)

set +e
cliclose_output="$(cd "$behavior_project" && git -c user.email=t@t.com -c user.name=t commit -m "close via CLI" 2>&1)"
cliclose_rc=$?
set -e
[[ "$cliclose_rc" -eq 0 ]] || fail "expected CLI close of a previously-committed ticket to succeed: $cliclose_output"
[[ "$cliclose_output" != *"BLOCKED"* ]] || fail "expected no BLOCKED for a marker-bearing CLI close: $cliclose_output"

# ── Behavior: STILL blocks a hand-edit close of a previously-committed ticket (t-dec8 fail-open guard) ──
# Same interim-commit shape, but the close is a bare hand-edit (no `closed:` marker) — must block,
# proving previously-committed tickets are not blanket-exempted.
(
  cd "$behavior_project"
  mkdir -p .tickets/t-test4
  cat > .tickets/t-test4/ticket.md <<'EOF'
---
id: t-test4
status: in_progress
---
# test4
EOF
  git add .tickets/t-test4/ticket.md
  git -c user.email=t@t.com -c user.name=t commit -m "interim commit t-test4" -q
  sed -i.bak 's/status: in_progress/status: closed/' .tickets/t-test4/ticket.md
  rm -f .tickets/t-test4/ticket.md.bak
  git add .tickets/t-test4/ticket.md
)

set +e
handclose_output="$(cd "$behavior_project" && git -c user.email=t@t.com -c user.name=t commit -m "hand-edit close" 2>&1)"
handclose_rc=$?
set -e
[[ "$handclose_rc" -ne 0 ]] || fail "expected hand-edit close of a previously-committed ticket to be blocked"
assert_contains "$handclose_output" "BLOCKED — ticket closed by direct file edit"

# ── Behavior: the suite does not inherit git's hook environment (t-ce0b) ────
# git exports GIT_DIR / GIT_INDEX_FILE / GIT_PREFIX into a hook (absolute paths in a linked worktree). A suite that runs `git init`,
# `config` or `commit` in a temp dir then acts on the REAL repo: live, one commit flipped core.bare, made a branch and a worktree and
# committed the staged files as "init". The fixture suite below does exactly that and records the variables it sees; the commit is
# made from a linked worktree (where the leak is worst), with GIT_WORK_TREE exported by the caller so all four variables are checked.
leak_root="$(mktemp -d)"
trap 'rm -rf "$project" "$conflict_project" "$behavior_project" "$leak_root" "$scratch_home"' EXIT
leak_host="$leak_root/host"
leak_wt="$leak_root/wt"
leak_out="$leak_root/env-seen.txt"
mkdir -p "$leak_host/scripts"
git -C "$leak_host" init -q
cat > "$leak_host/scripts/test.sh" <<'EOF'
#!/usr/bin/env bash
env | grep -E '^GIT_(DIR|INDEX_FILE|WORK_TREE|PREFIX|AUTHOR_NAME|AUTHOR_EMAIL|AUTHOR_DATE)=' > "$LEAK_OUT" || true
t="$(mktemp -d)" && cd "$t" || exit 1
trap 'cd / && rm -rf "$t"' EXIT
git init -q
git config core.bare true
git -c user.email=x@x -c user.name=x commit -q --allow-empty -m leak-init
git branch leak-branch
exit 0
EOF
chmod +x "$leak_host/scripts/test.sh"
printf 'one\n' > "$leak_host/f.txt"
mkdir -p "$leak_host/.tickets/t-leak1"
printf -- '---\nid: t-leak1\nstatus: in_progress\n---\n# leak1\n' > "$leak_host/.tickets/t-leak1/ticket.md"
git -C "$leak_host" add scripts f.txt .tickets
git -C "$leak_host" -c user.email=t@t.com -c user.name=t commit -q -m base
"$SKILLS" add sprint "$leak_host" >/dev/null
git -C "$leak_host" worktree add -q -b leak-wt "$leak_wt"
git -C "$leak_host" branch --list > "$leak_root/branches-before.txt"

# leak_commit <message> <git commit args...>: change f.txt, commit it from the linked worktree through the hook, and prove the
# fixture suite ran, saw none of the four variables, and left the host repo as it was.
leak_n=0
leak_commit() {
  local msg="$1"; shift
  leak_n=$((leak_n + 1))
  rm -f "$leak_out"
  printf 'v%s\n' "$leak_n" > "$leak_wt/f.txt"
  [[ "${1:-}" == "-a" || "${1:-}" == "--amend" ]] || git -C "$leak_wt" add f.txt
  set +e
  leak_output="$(cd "$leak_wt" && LEAK_OUT="$leak_out" GIT_WORK_TREE="$leak_wt" git -c user.email=t@t.com -c user.name=t commit "$@" -m "$msg" 2>&1)"
  leak_rc=$?
  set -e
  [[ "$leak_rc" -eq 0 ]] || fail "expected the commit ($*) through the hook to succeed: $leak_output"
  assert_contains "$leak_output" "Tests passed"
  [[ -f "$leak_out" ]] || fail "expected the fixture suite to run from the hook ($*)"
  assert_eq "" "$(cat "$leak_out")"
  assert_eq "false" "$(git -C "$leak_host" config --get core.bare)"
  assert_eq "$(cat "$leak_root/branches-before.txt")" "$(git -C "$leak_host" branch --list)"
  assert_eq "$msg" "$(git -C "$leak_wt" log -1 --format=%s)"
  assert_eq "2" "$(git -C "$leak_host" worktree list | wc -l | tr -d ' ')"
}
leak_commit "real commit"
leak_commit "commit -a" -a
leak_commit "pathspec commit" f.txt
leak_commit "amended commit" --amend

# The hook's own checks keep the commit's index: `commit -a` stages into a temporary index, which only a hook still holding
# GIT_INDEX_FILE can see, so a hand-edit close made that way must still block.
sed -i.bak 's/status: in_progress/status: closed/' "$leak_wt/.tickets/t-leak1/ticket.md"
rm -f "$leak_wt/.tickets/t-leak1/ticket.md.bak"
set +e
leak_block="$(cd "$leak_wt" && git -c user.email=t@t.com -c user.name=t commit -a -m "sneaky close" 2>&1)"
leak_block_rc=$?
set -e
[[ "$leak_block_rc" -ne 0 ]] || fail "expected commit -a with a hand-edit close to be blocked"
assert_contains "$leak_block" "BLOCKED — ticket closed by direct file edit"

# ── Records-only commits skip the suite (t-7db9) ────────────────────────────
# Prod path: canon's installed pre-commit hook (scripts/pre-commit-hook-template.sh) in every project, and so tkt merge-pr's record commit.
# The fixture suite always fails: a commit that runs it is blocked, one that skips it says so and goes through.
rec_project="$(make_project)"
trap 'rm -rf "$project" "$conflict_project" "$behavior_project" "$leak_root" "$rec_project" "$scratch_home"' EXIT
mkdir -p "$rec_project/scripts" "$rec_project/.tickets/t-rec1"
printf '#!/usr/bin/env bash
echo "suite ran"
echo "test failed"
exit 1
' > "$rec_project/scripts/test.sh"; chmod +x "$rec_project/scripts/test.sh"
printf 'echo hi\n' > "$rec_project/tool.sh"; printf 'n\n' > "$rec_project/.tickets/t-rec1/notes.md"
git -C "$rec_project" add scripts tool.sh .tickets; git -C "$rec_project" -c user.email=t@t -c user.name=t commit -q -m base
"$SKILLS" add sprint "$rec_project" >/dev/null
rec_commit() {   # rec_commit <msg> <paths...>: stage the paths, commit through the hook; sets rec_rc and rec_out
  local msg="$1"; shift
  git -C "$rec_project" add -A -- "$@"
  set +e; rec_out="$(cd "$rec_project" && git -c user.email=t@t -c user.name=t commit -m "$msg" 2>&1)"; rec_rc=$?; set -e
}
printf 'more\n' >> "$rec_project/.tickets/t-rec1/notes.md"; rec_commit "ticket notes" .tickets
assert_eq 0 "$rec_rc"; assert_contains "$rec_out" "Records only (.tickets/, HANDOFF, LEARNINGS, DECISIONS): test suite skipped."
[[ "$rec_out" != *"suite ran"* ]] || fail "t-7db9: the suite ran for a .tickets-only commit"
for f in HANDOFF.md LEARNINGS.md LEARNINGS-archive.md DECISIONS.md DECISIONS-archive.md; do printf 'x\n' > "$rec_project/$f"; done
rec_commit "docs records" HANDOFF.md LEARNINGS.md LEARNINGS-archive.md DECISIONS.md DECISIONS-archive.md
assert_eq 0 "$rec_rc"; assert_contains "$rec_out" "test suite skipped"
mkdir -p "$rec_project/docs"; printf 'x\n' > "$rec_project/docs/HANDOFF.md"; rec_commit "a HANDOFF.md not at the root" docs/HANDOFF.md
[[ "$rec_rc" -ne 0 ]] || fail "t-7db9: a docs/HANDOFF.md commit skipped the suite (records are root-level only)"; assert_contains "$rec_out" "suite ran"
git -C "$rec_project" reset -q; rm -rf "$rec_project/docs"
mkdir -p "$rec_project/.ticketsx"; printf 'x\n' > "$rec_project/.ticketsx/y"; rec_commit "a sibling of .tickets/" .ticketsx   # t-ab7e: the evaluator's surviving `.tickets*` mutant
[[ "$rec_rc" -ne 0 ]] || fail "t-ab7e: a .ticketsx/ commit skipped the suite (only .tickets/ itself is records)"; assert_contains "$rec_out" "suite ran"
git -C "$rec_project" reset -q; rm -rf "$rec_project/.ticketsx"
set +e; rec_out="$(cd "$rec_project" && git -c user.email=t@t -c user.name=t commit --allow-empty -m "empty" 2>&1)"; rec_rc=$?; set -e
[[ "$rec_rc" -ne 0 ]] || fail "t-7db9: an empty commit skipped the suite"; assert_contains "$rec_out" "suite ran"   # nothing staged keeps the suite
printf 'echo bye\n' >> "$rec_project/tool.sh"; rec_commit "code" tool.sh
[[ "$rec_rc" -ne 0 ]] || fail "t-7db9: a code commit skipped a failing suite"; assert_contains "$rec_out" "BLOCKED — test suite failed"
printf 'y\n' >> "$rec_project/.tickets/t-rec1/notes.md"; rec_commit "code and records" tool.sh .tickets
[[ "$rec_rc" -ne 0 ]] || fail "t-7db9: code staged with records skipped the suite"; assert_contains "$rec_out" "suite ran"
git -C "$rec_project" reset -q; git -C "$rec_project" checkout -q -- tool.sh .tickets
git -C "$rec_project" mv tool.sh .tickets/t-rec1/tool.sh
set +e; rec_out="$(cd "$rec_project" && git -c user.email=t@t -c user.name=t commit -m "move code into a ticket" 2>&1)"; rec_rc=$?; set -e
[[ "$rec_rc" -ne 0 ]] || fail "t-7db9: a git mv of code into .tickets/ skipped the suite (rename detection)"; assert_contains "$rec_out" "suite ran"
git -C "$rec_project" reset -q --hard
rec_key="AKIA""ABCDEFGHIJKLMNOP"; printf 'key = %s\n' "$rec_key" > "$rec_project/.tickets/t-rec1/leak.md"; rec_commit "secret in a ticket" .tickets
[[ "$rec_rc" -ne 0 ]] || fail "t-7db9: a records-only commit skipped the secret scan"; assert_contains "$rec_out" "aws-access-key"
git -C "$rec_project" reset -q; rm -f "$rec_project/.tickets/t-rec1/leak.md"
printf '# Claude\nRun wrapup before commits.\n' > "$rec_project/CLAUDE.md"; git -C "$rec_project" add CLAUDE.md
git -C "$rec_project" -c user.email=t@t -c user.name=t commit -q --no-verify -m "wrapup registered"
printf 'z\n' >> "$rec_project/.tickets/t-rec1/notes.md"; rec_commit "after a skip" .tickets
assert_eq 0 "$rec_rc"; assert_contains "$rec_out" "test suite skipped"; assert_contains "$rec_out" "Run /wrapup"   # the reminder still runs after a skip

# ── Covering suites (t-2912) ─────────────────────────────────────────────────
# Prod path: every `git commit` in a project with tests/suite-map.txt runs only the suites tools/covering-suites.sh picks. The
# fixture runner lists three suites and records the arguments it was run with; a full run is a run with no arguments.
cov_project="$(make_project)"
trap 'rm -rf "$project" "$conflict_project" "$behavior_project" "$leak_root" "$rec_project" "$cov_project" "$scratch_home"' EXIT
mkdir -p "$cov_project/scripts" "$cov_project/tests" "$cov_project/docs" "$cov_project/src"
cat > "$cov_project/scripts/test.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--list" ]]; then printf '%s\n' tests/a.sh tests/b.sh tests/c.sh; exit 0; fi
printf 'args:[%s]\n' "$*" >> "$(dirname "$0")/../runs.log"
exit 0
EOF
chmod +x "$cov_project/scripts/test.sh"
printf 'docs/guide.md\n' > "$cov_project/tests/a.sh"; : > "$cov_project/tests/b.sh"; : > "$cov_project/tests/c.sh"
printf 'docs/*.md @named tests/c.sh\n' > "$cov_project/tests/suite-map.txt"
printf 'g\n' > "$cov_project/docs/guide.md"; printf 'x\n' > "$cov_project/src/app.sh"
printf 'runs.log\n' > "$cov_project/.gitignore"
git -C "$cov_project" add -A; git -C "$cov_project" -c user.email=t@t -c user.name=t commit -q --no-verify -m base
"$SKILLS" add sprint "$cov_project" >/dev/null
cov_commit() {   # cov_commit <msg> <paths...>: change and stage the paths, commit through the hook; sets cov_rc, cov_out, cov_runs
  local msg="$1" f; shift
  for f in "$@"; do printf 'more\n' >> "$cov_project/$f"; done
  git -C "$cov_project" add -- "$@"; rm -f "$cov_project/runs.log"
  set +e; cov_out="$(cd "$cov_project" && git -c user.email=t@t -c user.name=t commit -m "$msg" 2>&1)"; cov_rc=$?; set -e
  cov_runs="$(cat "$cov_project/runs.log" 2>/dev/null || true)"
}
# (a) a mapped path: exactly the selected suites (@named picks a.sh, the row adds c.sh, b.sh names nothing), each with its path.
cov_commit "mapped doc" docs/guide.md
assert_eq 0 "$cov_rc"; assert_eq "args:[--only tests/a.sh --only tests/c.sh]" "$cov_runs"
assert_contains "$cov_out" "[pre-commit] Covering suites (tests/suite-map.txt): 2 of 3"
assert_contains "$cov_out" "tests/a.sh  <- docs/guide.md"; assert_contains "$cov_out" "tests/c.sh  <- docs/guide.md"
[[ "$cov_out" =~ \[pre-commit\]\ Tests\ passed\ \([0-9]+s\)\. ]] || fail "t-2912: no seconds on the scoped pass line: $cov_out"
# (b) one unmapped path beside a mapped one: the full suite, and the path that forced it is named (never a silent skip).
cov_commit "mixed" docs/guide.md src/app.sh
assert_eq 0 "$cov_rc"; assert_eq "args:[]" "$cov_runs"
assert_contains "$cov_out" "[pre-commit] Full suite:"; assert_contains "$cov_out" "src/app.sh: no row in tests/suite-map.txt"
[[ "$cov_out" =~ \[pre-commit\]\ Tests\ passed\ \([0-9]+s\)\. ]] || fail "t-2912: no seconds on the full pass line: $cov_out"
# (c) a stale label in any row, even one this commit does not match: blocked, the row named, no suite run.
printf 'docs/*.md @named\nsrc/*.sh tests/gone.sh\n' > "$cov_project/tests/suite-map.txt"; git -C "$cov_project" add tests/suite-map.txt
git -C "$cov_project" -c user.email=t@t -c user.name=t commit -q --no-verify -m "stale row"
cov_commit "doc under a stale map" docs/guide.md
[[ "$cov_rc" -ne 0 ]] || fail "t-2912: a stale map label did not block the commit"
assert_contains "$cov_out" "BLOCKED — tests/suite-map.txt could not pick the suites"; assert_contains "$cov_out" "row 'src/*.sh': 'tests/gone.sh' is not a scripts/test.sh --list label"
assert_eq "" "$cov_runs"
git -C "$cov_project" reset -q --hard
# (d) no map: the full suite with no arguments, as before t-2912 (every project that ships no map).
git -C "$cov_project" rm -q tests/suite-map.txt; git -C "$cov_project" -c user.email=t@t -c user.name=t commit -q --no-verify -m "no map"
cov_commit "doc, no map" docs/guide.md
assert_eq 0 "$cov_rc"; assert_eq "args:[]" "$cov_runs"
[[ "$cov_out" != *"Covering suites"* && "$cov_out" != *"Full suite:"* ]] || fail "t-2912: a project with no map printed map output: $cov_out"
assert_contains "$cov_out" "[pre-commit] Running test suite..."

# ── Non-git project: skip cleanly ───────────────────────────────────────────
nogit_project="$(mktemp -d)"
trap 'rm -rf "$project" "$conflict_project" "$behavior_project" "$leak_root" "$rec_project" "$nogit_project" "$scratch_home"' EXIT
printf '# Claude\n' > "$nogit_project/CLAUDE.md"
printf '# Agents\n' > "$nogit_project/AGENTS.md"
nogit_output="$("$SKILLS" add sprint "$nogit_project" 2>&1)"
assert_contains "$nogit_output" "$nogit_project/.git/hooks/pre-commit not found (not a git repo?)"
assert_contains "$("$SKILLS" status "$nogit_project" 2>&1)" "[skipped — not a git repo]"
[[ ! -d "$nogit_project/.git" ]] || fail "expected no .git to be created"

# ── Remove uninstalls the hook (t-0bcd) ─────────────────────────────────────
remove_project="$(make_project)"
trap 'rm -rf "$project" "$conflict_project" "$behavior_project" "$leak_root" "$rec_project" "$nogit_project" "$remove_project" "$scratch_home"' EXIT
"$SKILLS" add sprint "$remove_project" >/dev/null
assert_file_exists "$remove_project/.git/hooks/pre-commit"
"$SKILLS" remove sprint "$remove_project" >/dev/null
[[ ! -f "$remove_project/.git/hooks/pre-commit" ]] || fail "expected .git/hooks/pre-commit to be removed by skills.sh remove"

# ── A linked worktree (.git is a FILE): add, status and remove use the common hooks dir (t-80fc) ──
wt_main="$(make_project)"; wt_tree="$(mktemp -d)"; rm -rf "$wt_tree"
trap 'rm -rf "$project" "$conflict_project" "$behavior_project" "$leak_root" "$rec_project" "$nogit_project" "$remove_project" "$wt_main" "$wt_tree" "$scratch_home"' EXIT
git -C "$wt_main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
git -C "$wt_main" worktree add -q "$wt_tree"
[[ -f "$wt_tree/.git" ]] || fail "expected the linked worktree to have a .git FILE"
wt_hook="$(git_common_dir "$wt_tree")/hooks/pre-commit"
# GIT_* leaked from a calling hook (t-ce0b) must not aim the lookup at another repository
wt_out="$(GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent GIT_COMMON_DIR=/nonexistent "$SKILLS" add sprint "$wt_tree" 2>&1)"
if [[ "$wt_out" == *"not a git repo"* ]]; then fail "skills.sh add skipped the hook in a linked worktree"; fi
assert_grep "canon-managed-pre-commit-hook" "$wt_hook"
assert_contains "$("$SKILLS" status "$wt_tree" 2>&1)" "pre-commit (git)          [ok]"
"$SKILLS" remove sprint "$wt_tree" >/dev/null
[[ ! -f "$wt_hook" ]] || fail "expected skills.sh remove from a worktree to remove the common pre-commit hook"
# a sprint project in git whose hook is gone reads "not wired"
"$SKILLS" add sprint "$wt_tree" >/dev/null 2>&1; rm -f "$wt_hook"
assert_contains "$("$SKILLS" status "$wt_tree" 2>&1)" "pre-commit (git)          [not wired]"
# a .git pointer whose git dir is gone skips cleanly, as "not a git repo"
broken="$(mktemp -d)"; printf 'gitdir: %s/missing\n' "$broken" > "$broken/.git"
trap 'rm -rf "$project" "$conflict_project" "$behavior_project" "$leak_root" "$rec_project" "$nogit_project" "$remove_project" "$wt_main" "$wt_tree" "$broken" "$scratch_home"' EXIT
broken_out="$("$SKILLS" add sprint "$broken" 2>&1)" || fail "skills.sh add failed on a broken .git pointer: $(printf '%s' "$broken_out" | tail -3)"
assert_contains "$broken_out" "$broken/.git/hooks/pre-commit not found (not a git repo?)"

printf 'git-precommit-hook: ok\n'
