#!/usr/bin/env bash
# build-zip.sh — packages generated dist artifacts
# Run directly or called by .git/hooks/post-commit via scripts/install-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
FIXTURE_ZIP="$DIST_DIR/context-check-fixture.zip"
SLIDES_ZIP="$DIST_DIR/slides.zip"
OCTAVE_DOCS_ZIP="$DIST_DIR/octave-docs-skill.zip"
FIXTURE_DIR="$REPO_ROOT/fixtures/context-check-fixture"
OCTAVE_DOCS_DIR="$REPO_ROOT/skills/octave-docs"
SLIDES_STAGE="$(mktemp -d)"
FIXTURE_STAGE="$(mktemp -d)"
OCTAVE_DOCS_STAGE="$(mktemp -d)"

cleanup() { rm -rf "$SLIDES_STAGE" "$FIXTURE_STAGE" "$OCTAVE_DOCS_STAGE"; }
trap cleanup EXIT

mkdir -p "$DIST_DIR"

# ── Zip: slides (all files from posts/slides) ───────────────────────────────
rm -f "$SLIDES_ZIP"
SLIDES_DIR="$SLIDES_STAGE/slides"
mkdir -p "$SLIDES_DIR"
cp -r "$REPO_ROOT/posts/slides/." "$SLIDES_DIR/"
(cd "$SLIDES_STAGE" && zip -r "$SLIDES_ZIP" "slides" --quiet)
echo "dist: slides.zip updated ($(du -sh "$SLIDES_ZIP" | cut -f1))"

# ── Zip: context-check fixture ───────────────────────────────────────────────
if [[ -d "$FIXTURE_DIR" ]]; then
  rm -f "$FIXTURE_ZIP"
  mkdir -p "$FIXTURE_STAGE"
  cp -r "$FIXTURE_DIR" "$FIXTURE_STAGE/context-check-fixture"
  find "$FIXTURE_STAGE" \( -name ".DS_Store" -o -name "*.pyc" \) -delete 2>/dev/null || true
  (cd "$FIXTURE_STAGE" && zip -r "$FIXTURE_ZIP" "context-check-fixture" --quiet)
  echo "dist: context-check-fixture.zip updated ($(du -sh "$FIXTURE_ZIP" | cut -f1))"
else
  echo "Error: fixture dir not found: $FIXTURE_DIR" >&2
  exit 1
fi

# ── Zip: octave-docs skill (distributable Claude Desktop/claude.ai package) ─
rm -f "$OCTAVE_DOCS_ZIP"
OCTAVE_DOCS_PKG="$OCTAVE_DOCS_STAGE/octave-docs"
mkdir -p "$OCTAVE_DOCS_PKG"
cp "$OCTAVE_DOCS_DIR/SKILL.md" "$OCTAVE_DOCS_PKG/"
cp -r "$OCTAVE_DOCS_DIR/scripts" "$OCTAVE_DOCS_DIR/assets" "$OCTAVE_DOCS_DIR/references" "$OCTAVE_DOCS_PKG/"
find "$OCTAVE_DOCS_PKG" -name ".DS_Store" -delete 2>/dev/null || true
find "$OCTAVE_DOCS_PKG" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
(cd "$OCTAVE_DOCS_STAGE" && zip -r "$OCTAVE_DOCS_ZIP" "octave-docs" --quiet)
echo "dist: octave-docs-skill.zip updated ($(du -sh "$OCTAVE_DOCS_ZIP" | cut -f1))"

# ── Binary: sprint-check-win.exe (Windows board server) ─────────────────────
if command -v go >/dev/null 2>&1; then
  GOOS=windows GOARCH=amd64 go build \
    -o "$REPO_ROOT/tools/sprint-check-win.exe" \
    "$REPO_ROOT/tools/sprint-check-go/main.go"
  echo "dist: sprint-check-win.exe rebuilt ($(du -sh "$REPO_ROOT/tools/sprint-check-win.exe" | cut -f1))"
else
  echo "dist: sprint-check-win.exe skipped (go absent)"
fi
