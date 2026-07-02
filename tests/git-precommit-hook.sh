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

# ── Non-git project: skip cleanly ───────────────────────────────────────────
nogit_project="$(mktemp -d)"
trap 'rm -rf "$project" "$conflict_project" "$behavior_project" "$nogit_project"' EXIT
printf '# Claude\n' > "$nogit_project/CLAUDE.md"
printf '# Agents\n' > "$nogit_project/AGENTS.md"
nogit_output="$("$SKILLS" add sprint "$nogit_project" 2>&1)"
assert_contains "$nogit_output" "not a git repo"
[[ ! -d "$nogit_project/.git" ]] || fail "expected no .git to be created"

printf 'git-precommit-hook: ok\n'
