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

printf 'sprint-check-app: ok\n'
