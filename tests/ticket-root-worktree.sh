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

# t-7301: on Windows Git writes a drive-letter pointer ("gitdir: C:/Users/.../.git/worktrees/x"). It is absolute, but the
# old `!= /*` test joined it onto the worktree dir, so a worktree's tickets landed in a nested bogus path. Synthetic
# .git files reproduce that on any OS; a stub cygpath first in PATH keeps the VM's real one out of the result.
STUBS="$(mktemp -d)"; trap 'rm -rf "$WORK" "$WORK-worktrees" "$STUBS"' EXIT
mkdir -p "$STUBS/none" "$STUBS/map"
printf '#!/bin/sh\nexit 1\n' > "$STUBS/none/cygpath"
# maps C:/x -> /c/x like `cygpath -u` does for a drive path
printf '#!/bin/sh\n[ "$1" = -u ] || exit 1\np="$2"; l="$(printf %%s "${p%%%%"${p#?}"}" | tr A-Z a-z)"\nprintf "/%%s%%s\\n" "$l" "${p#?:}"\n' > "$STUBS/map/cygpath"
chmod +x "$STUBS/none/cygpath" "$STUBS/map/cygpath"
[[ "$("$STUBS/map/cygpath" -u C:/x/repo)" == /c/x/repo ]] || fail "test stub cygpath is broken"

synth_tickets_dir() { # <stub: none|map> <gitdir pointer>; prints tickets_dir for a dir whose .git file holds the pointer
  local d; d="$(mktemp -d)"
  printf 'gitdir: %s\n' "$2" > "$d/.git"
  (cd "$d" && PATH="$STUBS/$1:$PATH" && source "$ROOT/tools/ticket-root.sh" && tickets_dir)
  rm -rf "$d"
}
synth_root() { local d; d="$(mktemp -d)"; printf 'gitdir: %s\n' "$2" > "$d/.git"; (cd "$d" && PATH="$STUBS/$1:$PATH" && source "$ROOT/tools/ticket-root.sh" && project_root); rm -rf "$d"; }

assert_eq "C:/x/repo/.tickets"  "$(synth_tickets_dir none 'C:/x/repo/.git/worktrees/w')"
assert_eq "/c/x/repo/.tickets"  "$(synth_tickets_dir map  'C:/x/repo/.git/worktrees/w')"
assert_eq "C:/x/repo"           "$(synth_root none 'C:/x/repo/.git/worktrees/w')"
assert_eq "C:/x/repo/.tickets"  "$(synth_tickets_dir none 'C:\x\repo\.git\worktrees\w')"
assert_eq "/c/x/repo/.tickets"  "$(synth_tickets_dir map  'C:\x\repo\.git\worktrees\w')"
assert_eq "D:/a b/r/.tickets"   "$(synth_tickets_dir none 'D:/a b/r/.git/worktrees/w')"
# unchanged: a POSIX absolute pointer, whatever cygpath is around
assert_eq "/x/repo/.tickets"    "$(synth_tickets_dir none '/x/repo/.git/worktrees/w')"
assert_eq "/x/repo/.tickets"    "$(synth_tickets_dir map  '/x/repo/.git/worktrees/w')"
# unchanged: a relative pointer is still joined onto the directory holding the .git file
rel_dir="$(mktemp -d)"; printf 'gitdir: ../main/.git/worktrees/w\n' > "$rel_dir/.git"
assert_eq "$rel_dir/../main/.tickets" "$(cd "$rel_dir" && PATH="$STUBS/map:$PATH" && source "$ROOT/tools/ticket-root.sh" && tickets_dir)"
rm -rf "$rel_dir"

printf 'ticket-root-worktree: ok\n'
