#!/usr/bin/env bash
# worktree-links-parity (t-74d8) — the links a worktree needs to canon are made in two languages: Go (the Cockpit's
# worktree route and the daemon's session start, common.LinkWorktree, reached here through `canon-go link-worktree`) and
# bash (`skills.sh link-worktree`, which `tkt land` runs). The board and daemon must work without bash on Windows, so both
# stay; this test is what keeps them one rule. Each case runs the same starting state through both and requires the same
# links (.claude/skills, .agents/skills, .claude/agents) with the same targets, the same ignore file content (git's
# info/exclude in a linked worktree, .gitignore in a main checkout), a clean `git status` in a worktree, and the same
# files in a project-owned agents folder. t-12f8 fixed only the bash side and the Go side drifted: this fails on that.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v git >/dev/null 2>&1; then
  echo "worktree-links-parity: git absent — skipped"
  exit 0
fi

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" CANON_HOME="$W/home/.canon" TMPDIR="$W/tmp"
mkdir -p "$HOME" "$TMPDIR"
GO_BIN="$(build_board "$W/bin")"

repo() {   # repo <dir>: a project with one commit and a .gitignore of its own
  mkdir -p "$1"; git -C "$1" init -q; git -C "$1" config user.email t@t; git -C "$1" config user.name t
  printf 'node_modules\n' > "$1/.gitignore"; echo x > "$1/f.txt"; git -C "$1" add -A; git -C "$1" commit -qm init
}
target() { [[ -L "$1" || -d "$1" ]] && (cd "$1" 2>/dev/null && pwd -P) || echo "-"; }
ignore_file() { local p; p="$(git -C "$1" rev-parse --git-path info/exclude)"; [[ -f "$1/.git" ]] && { case "$p" in /*) ;; *) p="$1/$p" ;; esac; echo "$p"; } || echo "$1/.gitignore"; }
state() {   # state <dir>: what a worktree link leaves behind, as text to compare
  local d="$1" rel
  for rel in .claude/skills .agents/skills .claude/agents; do printf '%s -> %s\n' "$rel" "$(target "$d/$rel")"; done
  printf -- '--- ignore\n'; cat "$(ignore_file "$d")" 2>/dev/null || true
  printf -- '--- .gitignore\n'; cat "$d/.gitignore" 2>/dev/null || true
  if [[ -d "$d/.claude/agents" && ! -L "$d/.claude/agents" ]]; then
    printf -- '--- agents folder\n'; (cd "$d/.claude/agents" && for f in *; do printf '%s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -c1-12)"; done)
  fi
  [[ -f "$d/.git" ]] && { printf -- '--- status\n'; git -C "$d" status --porcelain; }
  return 0
}
both() {   # both <name> <prep>: run prep on two fresh copies, link one with Go and one with bash, compare
  local name="$1" prep="$2" go bash
  for side in go bash; do
    repo "$W/$name-$side/main"
    "$prep" "$W/$name-$side"
  done
  SPRINT_CHECK_NO_BROWSER=1 "$GO_BIN" link-worktree "$ROOT" "$W/$name-go/dir" > /dev/null
  bash "$ROOT/tools/skills.sh" link-worktree "$W/$name-bash/dir" > /dev/null
  go="$(state "$W/$name-go/dir" | sed "s#$W/$name-go#X#g")"
  bash="$(state "$W/$name-bash/dir" | sed "s#$W/$name-bash#X#g")"
  [[ "$go" == "$bash" ]] || fail "worktree-links-parity: $name: Go and skills.sh differ
--- Go
$go
--- skills.sh
$bash"
  [[ "$go" == *".claude/agents -> $(cd "$ROOT/agents" && pwd -P)"* || "$name" == own-agents ]] || fail "worktree-links-parity: $name: no .claude/agents link to canon's agents:
$go"
}

fresh_worktree() { git -C "$1/main" worktree add -q -b w "$1/dir"; }
main_checkout() { ln -s main "$1/dir"; }
own_agents() {   # a worktree whose project owns its agents folder: canon adds only what is missing, keeps the user's file
  git -C "$1/main" worktree add -q -b w "$1/dir"
  mkdir -p "$1/dir/.claude/agents"; printf 'my own reviewer\n' > "$1/dir/.claude/agents/canon-reviewer.md"
}
stale_links() {  # a worktree whose links point at an old canon folder
  git -C "$1/main" worktree add -q -b w "$1/dir"
  mkdir -p "$1/old/agents" "$1/dir/.claude"; printf '<!-- canon:agent -->\n' > "$1/old/agents/canon-reviewer.md"
  ln -s "$1/old/agents" "$1/dir/.claude/agents"; ln -s "$1/old" "$1/dir/.claude/skills"
}

both fresh-worktree fresh_worktree
both main-checkout main_checkout
both own-agents own_agents
both stale-links stale_links

echo "worktree-links-parity: ok (Go and skills.sh link-worktree agree: fresh worktree, main checkout, a project-owned agents folder, stale links)"
