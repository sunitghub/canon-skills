#!/usr/bin/env bash
# sprint-check-app — static front-end regressions for board interactions

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

APP="$ROOT/tools/sprint-check-app/app.html"

assert_grep 'class="modal-resize-handle"' "$APP"
assert_grep 'function makePanelResizable\(panelId\)' "$APP"
assert_grep "makePanelResizable\\('modal'\\)" "$APP"
assert_grep "makePanelResizable\\('create-modal'\\)" "$APP"
assert_grep "makePanelDraggable\\('create-modal'\\)" "$APP"
assert_grep 'resetPanelResize\(document.getElementById\('\''modal'\''\)\)' "$APP"
assert_grep 'resetPanelResize\(document.getElementById\('\''create-modal'\''\)\)' "$APP"
assert_grep 'max-height: calc\(100vh - 24px\)' "$APP"
assert_grep 'padding: 12px;' "$APP"
assert_grep 'min-height: 0;' "$APP"
assert_grep '<div class="kbd-hint" id="m-kbd">Esc</div>' "$APP"

if grep -qE "act-prev|act-next|← → Esc" "$APP"; then
  fail "ticket modal should not expose Back/Done status column movement"
fi
if grep -qE "ArrowLeft|ArrowRight" "$APP"; then
  fail "modal keydown handler should not bind ArrowLeft/ArrowRight (use explicit nav buttons instead)"
fi

# t-f377: bugfix is a first-class board tier option with a correct label (not the
# old ternary that mislabeled anything non-high-risk as "Normal").
assert_grep "'normal', 'bugfix', 'high-risk'" "$APP"
assert_grep "bugfix: 'Bugfix'" "$APP"

# t-6e32: Gherkin scenarios in the acceptance form — toolbar button, renderer,
# validator, and theme-aware panel styling. The dead <details> "Code block"
# insert must be gone.
assert_grep 'data-insert="scenario"' "$APP"
assert_grep 'function renderGherkinFence' "$APP"
assert_grep 'function validateGherkinBlocks' "$APP"
assert_grep 'doc-scenario-kw' "$APP"
assert_grep 'scenario-bg:' "$APP"
if grep -q 'data-insert="toggle"' "$APP"; then
  fail "dead <details> 'Code block' toolbar insert should be replaced by data-insert=\"scenario\""
fi

printf 'sprint-check-app: ok\n'
