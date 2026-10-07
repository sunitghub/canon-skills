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
