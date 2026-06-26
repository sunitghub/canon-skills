#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLIDES_DIR="$ROOT/posts/slides"
THEME="$ROOT/skills/canon-slides/themes/octave.css"

harden_html() {
  local out="$1"
  node - "$out" <<'NODE'
const fs = require('fs');

const file = process.argv[2];
const marker = 'canon-slide-render-hardening';
const style = `<style id="${marker}">
@media screen {
  body[data-bespoke-view=""] svg.bespoke-marp-slide:not(.bespoke-marp-active),
  body[data-bespoke-view="next"] svg.bespoke-marp-slide:not(.bespoke-marp-active) {
    display: none !important;
  }

  body[data-bespoke-view=""] svg.bespoke-marp-slide.bespoke-marp-active,
  body[data-bespoke-view="next"] svg.bespoke-marp-slide.bespoke-marp-active {
    display: block !important;
  }
}
</style>`;

let html = fs.readFileSync(file, 'utf8');
if (!html.includes(`id="${marker}"`)) {
  if (!html.includes('</head>')) {
    throw new Error(`Cannot harden ${file}: missing </head>`);
  }
  html = html.replace('</head>', `${style}</head>`);
  fs.writeFileSync(file, html);
}
NODE
}

render() {
  local topic="$1"
  local src="$SLIDES_DIR/${topic}.md"
  local html_out="$SLIDES_DIR/${topic}.html"
  local pptx_out="$SLIDES_DIR/${topic}.pptx"
  if [[ ! -f "$src" ]]; then
    echo "Error: $src not found" >&2
    exit 1
  fi
  echo "==> Rendering $topic"
  npx @marp-team/marp-cli "$src" \
    --theme "$THEME" \
    -o "$html_out" \
    --allow-local-files \
    --html \
    --bespoke.transition=false
  harden_html "$html_out"
  echo "    => $html_out"

  npx @marp-team/marp-cli "$src" \
    --theme "$THEME" \
    -o "$pptx_out" \
    --allow-local-files \
    --html \
    --pptx
  echo "    => $pptx_out"
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
