#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLIDES_DIR="$ROOT/posts/slides"
THEME="$ROOT/skills/canon-slides/themes/octave.css"

render() {
  local topic="$1"
  local src="$SLIDES_DIR/${topic}.md"
  local out="$SLIDES_DIR/${topic}.html"
  if [[ ! -f "$src" ]]; then
    echo "Error: $src not found" >&2
    exit 1
  fi
  echo "==> Rendering $topic"
  npx @marp-team/marp-cli "$src" \
    --theme "$THEME" \
    -o "$out" \
    --allow-local-files \
    --html
  echo "    => $out"
}

TOPIC="${1:-}"

if [[ -n "$TOPIC" ]]; then
  render "$TOPIC"
else
  for src in "$SLIDES_DIR"/*.md; do
    [[ "$(basename "$src")" == README.md ]] && continue
    render "$(basename "$src" .md)"
  done
fi
