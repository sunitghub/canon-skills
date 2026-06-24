#!/usr/bin/env bash
# build-zip.sh — packages canon into dist/canon-workshop.zip for offline/workshop distribution
# Run directly or called by .git/hooks/pre-push via scripts/install-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
ZIP_OUT="$DIST_DIR/canon-workshop.zip"
STAGE="$(mktemp -d)"
CANON_DIR="$STAGE/canon"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

mkdir -p "$DIST_DIR" "$CANON_DIR"

# ── Copy include list into staging dir ──────────────────────────────────────
mkdir -p "$CANON_DIR/tools" "$CANON_DIR/standards"
cp -r "$REPO_ROOT/skills"                       "$CANON_DIR/"
mkdir -p "$CANON_DIR/examples" "$CANON_DIR/scripts"
cp -r "$REPO_ROOT/examples/canon-todo-walkthrough" "$CANON_DIR/examples/canon-todo-walkthrough"
cp -r "$REPO_ROOT/examples/todo-app"            "$CANON_DIR/examples/todo-app"
cp -r "$REPO_ROOT/tools/sprint-check-app"      "$CANON_DIR/tools/sprint-check-app"
cp    "$REPO_ROOT/tools/tkt"                    "$CANON_DIR/tools/tkt"
cp    "$REPO_ROOT/tools/sprint"                 "$CANON_DIR/tools/sprint"
cp    "$REPO_ROOT/tools/sprint-check"           "$CANON_DIR/tools/sprint-check"
cp    "$REPO_ROOT/tools/skills.sh"              "$CANON_DIR/tools/skills.sh"
cp    "$REPO_ROOT/tools/ticket-root.sh"         "$CANON_DIR/tools/ticket-root.sh"
cp    "$REPO_ROOT/tools/skill-lib.sh"           "$CANON_DIR/tools/skill-lib.sh"
cp    "$REPO_ROOT/tools/hooks-lib.sh"           "$CANON_DIR/tools/hooks-lib.sh"
cp    "$REPO_ROOT/tools/tkt.cmd"                "$CANON_DIR/tools/tkt.cmd"
cp    "$REPO_ROOT/tools/sprint.cmd"             "$CANON_DIR/tools/sprint.cmd"
cp    "$REPO_ROOT/tools/sprint-check.cmd"       "$CANON_DIR/tools/sprint-check.cmd"
cp    "$REPO_ROOT/tools/skills.cmd"             "$CANON_DIR/tools/skills.cmd"
cp    "$REPO_ROOT/standards/efficiency.md"      "$CANON_DIR/standards/efficiency.md"
cp    "$REPO_ROOT/standards/agent-design.md"    "$CANON_DIR/standards/agent-design.md"
cp    "$REPO_ROOT/AGENTS.md"                    "$CANON_DIR/AGENTS.md"

if command -v go >/dev/null 2>&1; then
  (cd "$REPO_ROOT" && GO111MODULE=off GOOS=windows GOARCH=amd64 \
    go build -o "$CANON_DIR/tools/sprint-check.exe" ./tools/sprint-check-go)
elif [[ -f "$ZIP_OUT" ]] && unzip -p "$ZIP_OUT" canon/tools/sprint-check.exe > "$CANON_DIR/tools/sprint-check.exe" 2>/dev/null; then
  echo "warning: go not found; reused sprint-check.exe from existing $ZIP_OUT" >&2
else
  echo "Error: go is required to build tools/sprint-check.exe" >&2
  exit 1
fi

# Workshop-specific installers (not the public GitHub install.sh)
cp    "$REPO_ROOT/scripts/workshop-install.sh"  "$CANON_DIR/install.sh"
cp    "$REPO_ROOT/scripts/copy-todo-walkthrough.sh" "$CANON_DIR/scripts/copy-todo-walkthrough.sh"
cp    "$REPO_ROOT/install.ps1"                  "$CANON_DIR/install.ps1"

# Workshop README becomes the zip root README
cp    "$REPO_ROOT/dist/README.md"               "$CANON_DIR/README.md"

# ── Strip unwanted files from staging ───────────────────────────────────────
rm -rf "$CANON_DIR/tools/sprint-check-app/__pycache__"
rm -rf "$CANON_DIR/examples/todo-app/node_modules"
find "$STAGE" \( -name "*.pyc" -o -name ".DS_Store" \) -delete 2>/dev/null || true

# ── Zip: canon-workshop ─────────────────────────────────────────────────────
rm -f "$ZIP_OUT"
(cd "$STAGE" && zip -r "$ZIP_OUT" "canon" --quiet)
echo "dist: canon-workshop.zip updated ($(du -sh "$ZIP_OUT" | cut -f1))"

# ── Zip: slides (all files from posts/slides) ───────────────────────────────
SLIDES_ZIP="$DIST_DIR/slides.zip"
rm -f "$SLIDES_ZIP"
SLIDES_STAGE="$(mktemp -d)"
SLIDES_DIR="$SLIDES_STAGE/slides"
mkdir -p "$SLIDES_DIR"
cp -r "$REPO_ROOT/posts/slides/." "$SLIDES_DIR/"
(cd "$SLIDES_STAGE" && zip -r "$SLIDES_ZIP" "slides" --quiet)
rm -rf "$SLIDES_STAGE"
echo "dist: slides.zip updated ($(du -sh "$SLIDES_ZIP" | cut -f1))"

# ── Zip: skill distributions ─────────────────────────────────────────────────
for SKILL_NAME in context-check skill-export; do
  SKILL_ZIP="$DIST_DIR/${SKILL_NAME}.zip"
  rm -f "$SKILL_ZIP"
  (cd "$REPO_ROOT/skills" && zip -r "$SKILL_ZIP" "$SKILL_NAME" --quiet \
    --exclude "${SKILL_NAME}/.DS_Store" \
    --exclude "${SKILL_NAME}/**/.DS_Store" \
    --exclude "${SKILL_NAME}/**/*.pyc")
  echo "dist: ${SKILL_NAME}.zip updated ($(du -sh "$SKILL_ZIP" | cut -f1))"
done
