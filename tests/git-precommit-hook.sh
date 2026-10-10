#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ── Fresh install ────────────────────────────────────────────────────────────
project="$(make_project)"
trap 'rm -rf "$project"' EXIT

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
trap 'rm -rf "$project" "$conflict_project"' EXIT
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
trap 'rm -rf "$project" "$conflict_project" "$behavior_project"' EXIT
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
trap 'rm -rf "$project" "$conflict_project" "$behavior_project" "$nogit_project" "$remove_project" "$leak_root"' EXIT
leak_host="$leak_root/host"
leak_wt="$leak_root/wt"
leak_out="$leak_root/env-seen.txt"
mkdir -p "$leak_host/scripts"
git -C "$leak_host" init -q
cat > "$leak_host/scripts/test.sh" <<'EOF'
#!/usr/bin/env bash
env | grep -E '^GIT_(DIR|INDEX_FILE|WORK_TREE|PREFIX)=' > "$LEAK_OUT" || true
t="$(mktemp -d)" && cd "$t" || exit 1
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

printf 'two\n' > "$leak_wt/f.txt"
git -C "$leak_wt" add f.txt
set +e
leak_output="$(cd "$leak_wt" && LEAK_OUT="$leak_out" GIT_WORK_TREE="$leak_wt" git -c user.email=t@t.com -c user.name=t commit -m "real commit" 2>&1)"
leak_rc=$?
set -e
[[ "$leak_rc" -eq 0 ]] || fail "expected the commit through the hook to succeed: $leak_output"
assert_contains "$leak_output" "Tests passed"
[[ -f "$leak_out" ]] || fail "expected the fixture suite to run from the hook"
assert_eq "" "$(cat "$leak_out")"
assert_eq "false" "$(git -C "$leak_host" config --get core.bare)"
assert_eq "$(cat "$leak_root/branches-before.txt")" "$(git -C "$leak_host" branch --list)"
assert_eq "real commit" "$(git -C "$leak_wt" log -1 --format=%s)"
assert_eq "2" "$(git -C "$leak_host" worktree list | wc -l | tr -d ' ')"

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

# ── Non-git project: skip cleanly ───────────────────────────────────────────
nogit_project="$(mktemp -d)"
trap 'rm -rf "$project" "$conflict_project" "$behavior_project" "$nogit_project"' EXIT
printf '# Claude\n' > "$nogit_project/CLAUDE.md"
printf '# Agents\n' > "$nogit_project/AGENTS.md"
nogit_output="$("$SKILLS" add sprint "$nogit_project" 2>&1)"
assert_contains "$nogit_output" "not a git repo"
[[ ! -d "$nogit_project/.git" ]] || fail "expected no .git to be created"

# ── Remove uninstalls the hook (t-0bcd) ─────────────────────────────────────
remove_project="$(make_project)"
trap 'rm -rf "$project" "$conflict_project" "$behavior_project" "$nogit_project" "$remove_project"' EXIT
"$SKILLS" add sprint "$remove_project" >/dev/null
assert_file_exists "$remove_project/.git/hooks/pre-commit"
"$SKILLS" remove sprint "$remove_project" >/dev/null
[[ ! -f "$remove_project/.git/hooks/pre-commit" ]] || fail "expected .git/hooks/pre-commit to be removed by skills.sh remove"

printf 'git-precommit-hook: ok\n'
