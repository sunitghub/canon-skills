#!/usr/bin/env bash
# install-hooks.sh — installs git hooks for canon repo (called by skills.sh init)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# A linked worktree's .git is a FILE; its hooks live in the common git dir (t-80fc, same lookup as tools/hooks-lib.sh).
HOOKS_DIR="$REPO_ROOT/.git/hooks"
if [ -e "$REPO_ROOT/.git" ]; then
  common="$(cd "$REPO_ROOT" && env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    git rev-parse --git-common-dir 2>/dev/null)" || common=""
  if [ -n "$common" ] && common="$(cd "$REPO_ROOT" && cd "$common" 2>/dev/null && pwd)"; then HOOKS_DIR="$common/hooks"; fi
fi

if [ ! -d "$HOOKS_DIR" ]; then
  echo "  [skip]  .git/hooks not found (not a git repo?)"
  exit 0
fi

# ── post-commit: rebuild the local native canon-go (t-9383: nothing is committed any more; t-bdb0: one program) ──
POST_COMMIT="$HOOKS_DIR/post-commit"
cat > "$POST_COMMIT" << 'HOOK'
#!/usr/bin/env bash
# The Windows exes used to be rebuilt and committed here ("chore: update dist zips"); they are release assets now.
# This only refreshes the gitignored local canon-go so a dev machine's Admin panel shows a real build id.
REPO_ROOT="$(git rev-parse --show-toplevel)"
bash "$REPO_ROOT/scripts/build-zip.sh" || true
HOOK
chmod +x "$POST_COMMIT"
echo "  [ok]    post-commit hook installed → $POST_COMMIT"

# ── pre-push: no credential reaches any remote (t-5988), and nothing reaches a canon.mirror remote (public) before its binaries are released (t-4ea4) ─────────
# The secret scan reads every commit being pushed (`tools/secret-scan.sh --range`; a new branch: the commits no remote has) for EVERY remote.
# `tkt push-main` already checks the release (t-b6b6); the second part covers every other route to a mirror (a plain `git push public`, an agent's push).
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
while read -r _lref lsha _rref rsha; do
  [[ -n "$lsha" && ! "$lsha" =~ ^0+$ ]] || continue
  # </dev/null: the ref lines are this loop's stdin; a child that read it would leave later refs unchecked
  # a new branch: the commits THIS remote has not got (a commit another remote already holds is still new to this one); a URL has no tracking refs
  if [[ "$rsha" =~ ^0+$ ]]; then
    # a push by URL: find the remote that has this URL, so a commit another remote holds is still new to it
    rname="$remote"
    if ! git remote 2>/dev/null | grep -qxF -- "$remote"; then
      rname=""; while IFS= read -r m; do [[ "$(git remote get-url "$m" 2>/dev/null || true)" == "$url" ]] && { rname="$m"; break; }; done < <(git remote 2>/dev/null || true)
    fi
    if [[ -n "$rname" ]]; then range=("$lsha" --not "--remotes=$rname"); else range=("$lsha" --not --remotes); fi
  else range=("$rsha..$lsha"); fi
  if [[ ! -f "$REPO_ROOT/tools/secret-scan.sh" ]]; then
    echo "pre-push: refused the push to $remote (t-5988): tools/secret-scan.sh is missing, and a scan that cannot run is not a clean one; or 'git push --no-verify' to override on purpose" >&2
    exit 1
  fi
  if ! bash "$REPO_ROOT/tools/secret-scan.sh" --range "${range[@]}" </dev/null; then
    echo "pre-push: refused the push to $remote (t-5988): remove the secret and rotate it (exit 2: the scan itself failed), or 'git push --no-verify' to override on purpose" >&2
    exit 1
  fi
  [[ -n "$mirror" ]] || continue
  if ! bash "$REPO_ROOT/tools/tkt" release-check "$lsha" </dev/null; then
    echo "pre-push: refused the push to $mirror (t-4ea4): publish with 'tkt push-main' once released, or 'git push --no-verify' to override on purpose" >&2
    exit 1
  fi
done
exit 0
HOOK
chmod +x "$PRE_PUSH"
echo "  [ok]    pre-push hook installed → $PRE_PUSH"
