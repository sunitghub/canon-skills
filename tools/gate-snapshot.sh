#!/usr/bin/env bash
# gate-snapshot.sh — snapshot the repo before a gate subagent runs and compare after (t-bb2d).
#
# A gate (reviewer, evaluator) is read-only by contract, but a probe script that runs with the real checkout as its cwd can rename
# the branch, commit junk, write files and overwrite the audit log (live: t-1b74 round 1). `git status --porcelain` alone shows none
# of the first, and misses a second edit to an already-modified file. This records, and compares, what a read-only gate must not move:
#   the branch, HEAD, every ref, the porcelain lines (untracked files expanded), a digest of the uncommitted tracked content
#   (`git diff HEAD`), and a digest of .claude/subagent-runs.jsonl. `.tickets/` is ignored: the gate writes its report there.
# `pre` also prints a recovery hash (`git stash create`, non-destructive); on a difference `post` names each one and exits 1: stop and
# surface it, never auto-apply the hash. Where git cannot be asked (no repository, no commit yet) both modes warn and exit 0.
# Not seen: the content of untracked files, and anything outside the repository.
#
# Usage: gate-snapshot.sh pre <snapshot-file> | gate-snapshot.sh post <snapshot-file>
set -euo pipefail

mode="${1:-}"; file="${2:-}"
if [[ ( "$mode" != pre && "$mode" != post ) || -z "$file" ]]; then
  echo "Usage: gate-snapshot.sh pre|post <snapshot-file>" >&2
  exit 2
fi

root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
if [[ -z "$root" ]] || ! git -C "$root" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  echo "gate-snapshot: $mode skipped — no git repository or no commit yet, so there is nothing to compare."
  exit 0
fi

digest() {  # stdin -> sha256 hex (sha256sum, shasum, else cksum)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else cksum | cut -d' ' -f1
  fi
}

snapshot() {
  echo "branch=$(git -C "$root" symbolic-ref -q --short HEAD || echo DETACHED)"
  echo "head=$(git -C "$root" rev-parse HEAD)"
  echo "diff=$(git -C "$root" diff HEAD --binary -- . ':(exclude).tickets' | digest)"
  if [[ -f "$root/.claude/subagent-runs.jsonl" ]]; then echo "audit=$(digest < "$root/.claude/subagent-runs.jsonl")"; else echo "audit=absent"; fi
  git -C "$root" for-each-ref --format='ref %(refname) %(objectname)' | sort
  git -C "$root" status --porcelain --untracked-files=all -- . ':(exclude).tickets' | sed 's/^/status /' | sort
}

field() { sed -n "s/^$2=//p" "$1" | head -1; }   # <file> <key>

if [[ "$mode" == pre ]]; then
  stash="$(git -C "$root" stash create 2>/dev/null || true)"
  { snapshot; echo "stash=${stash:-none}"; } > "$file"
  echo "gate-snapshot: pre recorded in $file (branch $(field "$file" branch) at $(field "$file" head | cut -c1-7))."
  if [[ -n "$stash" ]]; then
    echo "gate-snapshot: recovery hash for uncommitted work: $stash (git stash apply $stash; never auto-apply)"
  else
    echo "gate-snapshot: recovery: nothing to recover, the tree has no uncommitted tracked changes."
  fi
  exit 0
fi

if [[ ! -f "$file" ]]; then
  echo "gate-snapshot: no pre snapshot at $file — run 'gate-snapshot.sh pre $file' before the dispatch." >&2
  exit 1
fi
now="$(mktemp)"; trap 'rm -f "$now"' EXIT
snapshot > "$now"
n=0
say() { echo "$*"; n=$((n + 1)); }

b0="$(field "$file" branch)"; b1="$(field "$now" branch)"
[[ "$b0" == "$b1" ]] || say "BRANCH changed: $b0 -> $b1"
h0="$(field "$file" head)"; h1="$(field "$now" head)"
if [[ "$h0" != "$h1" ]]; then
  if git -C "$root" merge-base --is-ancestor "$h0" "$h1" 2>/dev/null; then
    say "HEAD moved: ${h0:0:7}..${h1:0:7} ($(git -C "$root" rev-list --count "$h0..$h1") new commit(s))"
  else
    say "HEAD moved: ${h0:0:7} -> ${h1:0:7} (history rewritten, or another branch checked out)"
  fi
fi
ref_added="$(grep '^ref ' "$now" | sort | comm -13 <(grep '^ref ' "$file" | sort) - || true)"
ref_gone="$(grep '^ref ' "$file" | sort | comm -13 <(grep '^ref ' "$now" | sort) - || true)"
if [[ -n "$ref_added$ref_gone" ]]; then
  say "refs changed (a branch or tag was created, moved, renamed or deleted):"
  [[ -z "$ref_added" ]] || printf '%s\n' "$ref_added" | sed 's/^ref /  + /'
  [[ -z "$ref_gone" ]] || printf '%s\n' "$ref_gone" | sed 's/^ref /  - /'
fi
st_added="$(grep '^status ' "$now" | comm -13 <(grep '^status ' "$file") - || true)"
st_gone="$(grep '^status ' "$file" | comm -13 <(grep '^status ' "$now") - || true)"
if [[ -n "$st_added$st_gone" ]]; then
  say "working-tree paths changed:"
  [[ -z "$st_added" ]] || printf '%s\n' "$st_added" | sed 's/^status /  now: /'
  [[ -z "$st_gone" ]] || printf '%s\n' "$st_gone" | sed 's/^status /  was: /'
fi
[[ "$(field "$file" diff)" == "$(field "$now" diff)" ]] || say "uncommitted content of tracked files changed (a path already modified before the dispatch counts too)"
[[ "$(field "$file" audit)" == "$(field "$now" audit)" ]] || say ".claude/subagent-runs.jsonl (the audit log) changed"

if [[ "$n" -gt 0 ]]; then
  echo "gate-snapshot: STOP — $n difference(s) since the pre snapshot. A gate is read-only by contract: surface this to the user with the recovery hash ($(field "$file" stash)); never auto-apply it."
  exit 1
fi
echo "gate-snapshot: post ok — nothing changed."
