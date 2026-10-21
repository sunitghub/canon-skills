#!/usr/bin/env bash
# install-hooks.sh — installs git hooks for canon repo (called by skills.sh init)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"

if [ ! -d "$HOOKS_DIR" ]; then
  echo "  [skip]  .git/hooks not found (not a git repo?)"
  exit 0
fi

# ── post-commit: rebuild the local native cockpit-daemon (t-9383: nothing is committed any more) ──────────────
POST_COMMIT="$HOOKS_DIR/post-commit"
cat > "$POST_COMMIT" << 'HOOK'
#!/usr/bin/env bash
# The Windows exes used to be rebuilt and committed here ("chore: update dist zips"); they are release assets now.
# This only refreshes the gitignored local daemon so a dev machine's Admin panel shows a real build id.
REPO_ROOT="$(git rev-parse --show-toplevel)"
bash "$REPO_ROOT/scripts/build-zip.sh" || true
HOOK
chmod +x "$POST_COMMIT"
echo "  [ok]    post-commit hook installed → $POST_COMMIT"

# ── pre-push: nothing reaches a canon.mirror remote (public) before its binaries are released (t-4ea4) ─────────
# `tkt push-main` already checks (t-b6b6); this covers every other route (a plain `git push public`, an agent's push).
# Each pushed commit goes through the same guard (`tkt release-check`); a deletion pushes nothing and is skipped.
# `git push --no-verify` is the deliberate override (docs/releasing.md).
PRE_PUSH="$HOOKS_DIR/pre-push"
cat > "$PRE_PUSH" << 'HOOK'
#!/usr/bin/env bash
remote="$1" url="$2"
REPO_ROOT="$(git rev-parse --show-toplevel)"
# A mirror by name, or by its URL (`git push <url-of-public> main` hands the URL as both arguments).
mirror=""
while IFS= read -r m; do
  [[ -n "$m" ]] || continue
  if [[ "$remote" == "$m" || "$url" == "$(git remote get-url "$m" 2>/dev/null || true)" ]]; then mirror="$m"; break; fi
done < <(git config --get-all canon.mirror 2>/dev/null || true)
[[ -n "$mirror" ]] || exit 0
while read -r _lref lsha _rref _rsha; do
  [[ -n "$lsha" && ! "$lsha" =~ ^0+$ ]] || continue
  # </dev/null: the ref lines are this loop's stdin; a child that read it would leave later refs unchecked
  if ! bash "$REPO_ROOT/tools/tkt" release-check "$lsha" </dev/null; then
    echo "pre-push: refused the push to $mirror (t-4ea4): publish with 'tkt push-main' once released, or 'git push --no-verify' to override on purpose" >&2
    exit 1
  fi
done
exit 0
HOOK
chmod +x "$PRE_PUSH"
echo "  [ok]    pre-push hook installed → $PRE_PUSH"
