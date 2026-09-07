#!/usr/bin/env bash
# skills-mirror-gitignore — t-f99b: the canon skill mirror (.claude/skills,
# .agents/skills) must never be committed (on Windows a junction is git-visible,
# so committing it makes worktrees/old checkouts serve STALE skills). Verify
# project.sh gitignores + untracks the mirror, and that link_worktree creates a
# link resolving to CURRENT canon.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Fake canon skills source with a marker file.
FAKE_CANON="$(mktemp -d)"
mkdir -p "$FAKE_CANON/skills/sprint"
echo "CURRENT-CANON-MARKER" > "$FAKE_CANON/skills/sprint/SKILL.md"
export SKILLS_ROOT="$FAKE_CANON"

# shellcheck source=tools/skills/lib.sh
source "$ROOT/tools/skills/lib.sh" 2>/dev/null || true
# shellcheck source=tools/skills/project.sh
source "$ROOT/tools/skills/project.sh"

PROJ="$(mktemp -d)"; WT="$(mktemp -d)"
cleanup() { rm -rf "$FAKE_CANON" "$PROJ" "$WT"; }
trap cleanup EXIT

# ── 1. _ensure_mirror_gitignored: gitignore + untrack a previously-committed mirror ──
git -C "$PROJ" init -q
git -C "$PROJ" config user.email t@t; git -C "$PROJ" config user.name t
mkdir -p "$PROJ/.agents/skills/sprint"
echo "STALE" > "$PROJ/.agents/skills/sprint/SKILL.md"       # simulate committed (Windows-junction) contents
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "committed mirror"

_ensure_mirror_gitignored "$PROJ"

grep -qxF "/.agents/skills/" "$PROJ/.gitignore" || fail "gitignore missing /.agents/skills/"
grep -qxF "/.claude/skills/" "$PROJ/.gitignore" || fail "gitignore missing /.claude/skills/"
[ -z "$(git -C "$PROJ" ls-files .agents/skills)" ] || fail "mirror still tracked after untrack"
# idempotent: second run adds no duplicate lines
_ensure_mirror_gitignored "$PROJ" >/dev/null
[ "$(grep -c '/.agents/skills/' "$PROJ/.gitignore")" -eq 1 ] || fail "gitignore line duplicated (not idempotent)"

# ── 2. link_worktree: creates a link resolving to CURRENT canon + gitignores ──
git -C "$WT" init -q
link_worktree "$WT" >/dev/null
[ -e "$WT/.agents/skills/sprint/SKILL.md" ] || fail "worktree link does not resolve to canon skills"
[ "$(cat "$WT/.agents/skills/sprint/SKILL.md")" = "CURRENT-CANON-MARKER" ] || fail "worktree link resolves to STALE content, not current canon"
grep -qxF "/.agents/skills/" "$WT/.gitignore" || fail "worktree .gitignore missing mirror entry"

echo "skills-mirror-gitignore: ok"
