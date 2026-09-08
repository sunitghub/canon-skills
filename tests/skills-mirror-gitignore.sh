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

# ── 3. link_worktree REPLACES a committed (tracked) stale mirror (t-9e55) ──
# `git worktree add` on a repo that committed the mirror materializes the stale
# copy before the link runs; link_worktree must replace it with a link to CURRENT
# canon, not skip it.
WTC="$(mktemp -d)"
git -C "$WTC" init -q; git -C "$WTC" config user.email t@t; git -C "$WTC" config user.name t
mkdir -p "$WTC/.agents/skills/sprint"
echo "STALE" > "$WTC/.agents/skills/sprint/SKILL.md"          # committed canon mirror (has the marker)
git -C "$WTC" add -A && git -C "$WTC" commit -qm "committed mirror"
link_worktree "$WTC" >/dev/null
_is_dir_link "$WTC/.agents/skills" || fail "committed mirror was not replaced with a link"
[ "$(cat "$WTC/.agents/skills/sprint/SKILL.md")" = "CURRENT-CANON-MARKER" ] || fail "replaced mirror does not resolve to CURRENT canon"
[ -z "$(git -C "$WTC" ls-files .agents/skills)" ] || fail "replaced mirror still tracked"
rm -rf "$WTC"

# ── 4. link_worktree PRESERVES a genuine project-local skills dir (no canon marker) ──
WTP="$(mktemp -d)"
git -C "$WTP" init -q; git -C "$WTP" config user.email t@t; git -C "$WTP" config user.name t
mkdir -p "$WTP/.agents/skills/myproj"
echo "PROJECT-LOCAL" > "$WTP/.agents/skills/myproj/thing.md"  # tracked, but NO sprint/SKILL.md marker
git -C "$WTP" add -A && git -C "$WTP" commit -qm "project-local skills"
link_worktree "$WTP" >/dev/null
_is_dir_link "$WTP/.agents/skills" && fail "project-local skills dir was wrongly replaced with a link"
[ "$(cat "$WTP/.agents/skills/myproj/thing.md")" = "PROJECT-LOCAL" ] || fail "project-local content lost"
rm -rf "$WTP"

# ── 5. Python board parity: server.py _link_skills_into_worktree replaces a
# committed mirror (resolves to the REAL canon skills via __file__) and preserves
# a no-marker dir. Mirrors project.sh + sprint-check-go. ──
if command -v python3 >/dev/null 2>&1; then
  WTPY="$(mktemp -d)"
  git -C "$WTPY" init -q; git -C "$WTPY" config user.email t@t; git -C "$WTPY" config user.name t
  mkdir -p "$WTPY/.agents/skills/sprint" "$WTPY/.claude/skills/myproj"
  echo "STALE" > "$WTPY/.agents/skills/sprint/SKILL.md"        # committed mirror (marker) -> replace
  echo "KEEP"  > "$WTPY/.claude/skills/myproj/x.md"            # committed, no marker      -> preserve
  git -C "$WTPY" add -A && git -C "$WTPY" commit -qm "mixed"
  SERVER_PY="$ROOT/tools/sprint-check-app/server.py"
  python3 - "$SERVER_PY" "$WTPY" <<'PY'
import sys, importlib.util, pathlib
spec = importlib.util.spec_from_file_location("scserver", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m._link_skills_into_worktree(pathlib.Path(sys.argv[2]))
PY
  [ -L "$WTPY/.agents/skills" ] || fail "py: committed mirror not replaced with a symlink"
  grep -q "name: sprint" "$WTPY/.agents/skills/sprint/SKILL.md" || fail "py: replaced mirror does not resolve to current canon (real skills)"
  [ "$(cat "$WTPY/.agents/skills/sprint/SKILL.md")" != "STALE" ] || fail "py: mirror still stale after replace"
  [ -L "$WTPY/.claude/skills" ] && fail "py: no-marker project-local dir wrongly replaced with a link"
  [ "$(cat "$WTPY/.claude/skills/myproj/x.md")" = "KEEP" ] || fail "py: project-local content lost"
  rm -rf "$WTPY"
else
  echo "skills-mirror-gitignore: python3 absent — skipped Python board parity (part 5)"
fi

echo "skills-mirror-gitignore: ok"
