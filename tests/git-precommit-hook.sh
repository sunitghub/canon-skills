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

# ── Non-git project: skip cleanly ───────────────────────────────────────────
nogit_project="$(mktemp -d)"
trap 'rm -rf "$project" "$conflict_project" "$behavior_project" "$nogit_project"' EXIT
printf '# Claude\n' > "$nogit_project/CLAUDE.md"
printf '# Agents\n' > "$nogit_project/AGENTS.md"
nogit_output="$("$SKILLS" add sprint "$nogit_project" 2>&1)"
assert_contains "$nogit_output" "not a git repo"
[[ ! -d "$nogit_project/.git" ]] || fail "expected no .git to be created"

printf 'git-precommit-hook: ok\n'
