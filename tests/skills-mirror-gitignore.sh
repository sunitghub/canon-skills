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

grep -qxF "/.agents/skills" "$PROJ/.gitignore" || fail "gitignore missing /.agents/skills"
grep -qxF "/.claude/skills" "$PROJ/.gitignore" || fail "gitignore missing /.claude/skills"
[ -z "$(git -C "$PROJ" ls-files .agents/skills)" ] || fail "mirror still tracked after untrack"
# idempotent: second run adds no duplicate lines
_ensure_mirror_gitignored "$PROJ" >/dev/null
[ "$(grep -c '/.agents/skills' "$PROJ/.gitignore")" -eq 1 ] || fail "gitignore line duplicated (not idempotent)"

# ── 2. link_worktree: creates a link resolving to CURRENT canon + gitignores ──
git -C "$WT" init -q
link_worktree "$WT" >/dev/null
[ -e "$WT/.agents/skills/sprint/SKILL.md" ] || fail "worktree link does not resolve to canon skills"
[ "$(cat "$WT/.agents/skills/sprint/SKILL.md")" = "CURRENT-CANON-MARKER" ] || fail "worktree link resolves to STALE content, not current canon"
grep -qxF "/.agents/skills" "$WT/.gitignore" || fail "worktree .gitignore missing mirror entry"

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

# ── 6. t-c433: git must not list the mirror as untracked — as symlinks (macOS/Linux) or real dirs (Windows) ──
mirror_listed() { git -C "$1" status --porcelain --untracked-files=all | grep -E '^\?\? \.(claude|agents)/skills' || true; }
SYM="$(mktemp -d)"; git -C "$SYM" init -q
upsert_skills_symlinks "$SYM" >/dev/null; _ensure_mirror_gitignored "$SYM" >/dev/null
_is_dir_link "$SYM/.claude/skills" && _is_dir_link "$SYM/.agents/skills" || fail "symlink fixture: mirror links not created"
[ -z "$(mirror_listed "$SYM")" ] || fail "symlinked mirror listed by git status: $(mirror_listed "$SYM")"
git -C "$SYM" check-ignore -q .claude/skills && git -C "$SYM" check-ignore -q .agents/skills || fail "git check-ignore misses a symlinked mirror"
[ "$(cat "$SYM/.gitignore")" = "$(printf '/.claude/skills\n/.agents/skills')" ] || fail "fresh .gitignore content: $(cat "$SYM/.gitignore")"
RD="$(mktemp -d)"; git -C "$RD" init -q
mkdir -p "$RD/.claude/skills/x" "$RD/.agents/skills/x"; echo s > "$RD/.claude/skills/x/f"; echo s > "$RD/.agents/skills/x/f"
_ensure_mirror_gitignored "$RD" >/dev/null
[ -z "$(mirror_listed "$RD")" ] || fail "real-dir mirror listed by git status: $(mirror_listed "$RD")"

# ── 7. t-c433: repair an old directory-only line in place; idempotent; no leftover or duplicate ──
RP="$(mktemp -d)"; git -C "$RP" init -q
printf 'node_modules/\n/.claude/skills/\ndist/\n' > "$RP/.gitignore"
_ensure_mirror_gitignored "$RP" >/dev/null
[ "$(cat "$RP/.gitignore")" = "$(printf 'node_modules/\n/.claude/skills\ndist/\n/.agents/skills')" ] || fail "repaired .gitignore: $(cat "$RP/.gitignore")"
before="$(cksum < "$RP/.gitignore")"; _ensure_mirror_gitignored "$RP" >/dev/null
[ "$(cksum < "$RP/.gitignore")" = "$before" ] || fail "repair is not idempotent"
printf '/.claude/skills/\n/.claude/skills\n' > "$RP/.gitignore"        # both forms already present
_ensure_mirror_gitignored "$RP" >/dev/null
[ "$(grep -c '^/.claude/skills' "$RP/.gitignore")" -eq 1 ] || fail "both forms: expected one slash-less line, got: $(cat "$RP/.gitignore")"
grep -qxF "/.claude/skills/" "$RP/.gitignore" && fail "both forms: directory-only line left behind"

# ── 8. t-c433: a .gitignore with no trailing newline is not corrupted ──
NN="$(mktemp -d)"; git -C "$NN" init -q
printf 'dist/' > "$NN/.gitignore"
_ensure_mirror_gitignored "$NN" >/dev/null
[ "$(cat "$NN/.gitignore")" = "$(printf 'dist/\n/.claude/skills\n/.agents/skills')" ] || fail "no-trailing-newline .gitignore: $(cat "$NN/.gitignore")"

# ── 9. t-c433 end to end through the real client: skills.sh add, then refresh over the old lines ──
E2E="$(mktemp -d)"; E2E_HOME="$(mktemp -d)"
git -C "$E2E" init -q
(
  unset SKILLS_ROOT
  export HOME="$E2E_HOME" SHELL=/bin/zsh SKILLS_SH_NO_TTY=1
  touch "$E2E_HOME/.zshrc"
  "$ROOT/tools/skills.sh" add sprint "$E2E" >/dev/null 2>&1
  [ -z "$(mirror_listed "$E2E")" ] || fail "skills.sh add left the mirror listed: $(mirror_listed "$E2E")"
  printf '/.claude/skills/\n/.agents/skills/\n' > "$E2E/.gitignore"     # what an older canon wrote
  [ -n "$(mirror_listed "$E2E")" ] || fail "fixture: the old directory-only lines should leave the symlinks listed"
  "$ROOT/tools/skills.sh" refresh "$E2E" >/dev/null 2>&1
  [ -z "$(mirror_listed "$E2E")" ] || fail "skills.sh refresh did not repair the old lines: $(mirror_listed "$E2E")"
)
rm -rf "$SYM" "$RD" "$RP" "$NN" "$E2E" "$E2E_HOME"

echo "skills-mirror-gitignore: ok"
