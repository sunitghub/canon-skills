#!/usr/bin/env bash
# Prevent recursive execution when the zip-update commit itself triggers this hook
LAST_MSG=$(git log -1 --pretty=%s)
if [ "$LAST_MSG" = "chore: update dist zips" ]; then
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"

# Build artifacts build-zip.sh may touch. Each is a hardcoded entry, not
# auto-discovered — adding a new build-zip.sh artifact output also needs a
# new entry here, or this hook silently leaves it uncommitted after rebuild.
ARTIFACT_PATHS=(tools/sprint-check-win.exe tools/sprint-headless-json-win.exe tools/cockpit-daemon-win.exe)

# Skip rebuild if the prior commit only touched build artifacts (e.g. this hook's
# own commit, or an artifact-only commit) -- nothing upstream could have changed.
EXCLUDES=()
for p in "${ARTIFACT_PATHS[@]}"; do
  EXCLUDES+=(":(exclude)$p")
done
if [ -z "$(git -C "$REPO_ROOT" diff --name-only HEAD~1 HEAD -- . "${EXCLUDES[@]}" 2>/dev/null)" ]; then
  exit 0
fi

bash "$REPO_ROOT/scripts/build-zip.sh"

CHANGED=()
while IFS= read -r f; do
  [ -n "$f" ] && CHANGED+=("$f")
done < <(
  { git -C "$REPO_ROOT" diff --name-only -- "${ARTIFACT_PATHS[@]}"
    git -C "$REPO_ROOT" ls-files --others --exclude-standard -- "${ARTIFACT_PATHS[@]}"
  } | sort -u
)

if [ ${#CHANGED[@]} -gt 0 ]; then
  git -C "$REPO_ROOT" add "${CHANGED[@]}"
  git -C "$REPO_ROOT" commit -m "chore: update dist zips"
  echo "[post-commit] dist zips updated and committed: ${CHANGED[*]}"
fi
