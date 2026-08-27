#!/usr/bin/env bash
# ticket-root-worktree (t-cd06) — tickets_dir()/project_root() must resolve
# back to the MAIN checkout's .tickets when run from inside a git worktree.
# A worktree's .git is a FILE ("gitdir: <repo>/.git/worktrees/<name>"), not a
# directory — live-reproduced bug: from inside a real worktree, `tkt ls`
# reported no tickets at all because the old walk only checked `-d .git`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v git >/dev/null 2>&1; then
  echo "ticket-root-worktree: git absent — skipped"
  exit 0
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK" "$WORK-worktrees"; }
trap cleanup EXIT

git -C "$WORK" init -q
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name test
# .tickets/ is gitignored in real canon projects (see .gitignore: `.tickets/`)
# — it must NOT be committed here, or `git worktree add` would check it out
# as tracked content into the new worktree, masking the exact bug this test
# guards against (a worktree never legitimately has its own .tickets/).
echo '.tickets/' > "$WORK/.gitignore"
mkdir -p "$WORK/.tickets/t-abcd"
echo '# test' > "$WORK/.tickets/t-abcd/ticket.md"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m init
git -C "$WORK" worktree add -q "$WORK-worktrees/feat-x" -b feat/x

resolved_tickets_dir="$(cd "$WORK-worktrees/feat-x" && source "$ROOT/tools/ticket-root.sh" && tickets_dir)"
resolved_project_root="$(cd "$WORK-worktrees/feat-x" && source "$ROOT/tools/ticket-root.sh" && project_root)"

# git itself resolves symlinks (e.g. macOS /var -> /private/var) when it
# writes the worktree's absolute gitdir path, so the expected value must be
# resolved the same way for a stable comparison.
want_project_root="$(cd "$WORK" && pwd -P)"
want_tickets_dir="$want_project_root/.tickets"

assert_eq "$want_tickets_dir" "$resolved_tickets_dir"
assert_eq "$want_project_root" "$resolved_project_root"
[[ -d "$resolved_tickets_dir/t-abcd" ]] || fail "resolved tickets_dir does not contain the real ticket: $resolved_tickets_dir"

# The main checkout itself (a real .git directory) is unaffected by the new
# gitdir-following branch — same behavior as before this fix.
main_tickets_dir="$(cd "$WORK" && source "$ROOT/tools/ticket-root.sh" && tickets_dir)"
assert_eq "$want_tickets_dir" "$(cd "$(dirname "$main_tickets_dir")" && pwd -P)/.tickets"

printf 'ticket-root-worktree: ok\n'
