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

# t-f89a: ticket-scoped .feature reference — toolbar button, async render, error state.
assert_grep 'data-insert="scenario-file"' "$APP"
assert_grep 'function renderFeatureRefPlaceholder' "$APP"
assert_grep 'function hydrateFeatureRefs' "$APP"
assert_grep 'gherkin-file' "$APP"
assert_grep 'api/ticket-feature' "$APP"
if grep -q 'data-insert="toggle"' "$APP"; then
  fail "dead <details> 'Code block' toolbar insert should be replaced by data-insert=\"scenario\""
fi

# t-ddc8: cockpit-in-board — mode switch, card Start/Resume, /api/cockpit embed,
# inline acceptance rail, focus collapse. The board never owns a PTY.
assert_grep 'id="cockpit-overlay"' "$APP"
assert_grep 'function openCockpit' "$APP"
assert_grep 'function closeCockpit' "$APP"
assert_grep "fetch\\('/api/cockpit'" "$APP"
assert_grep 'class="card-start' "$APP"
assert_grep 'renderCockpitAcceptance' "$APP"
assert_grep 'rail-collapsed' "$APP"
assert_grep 'embed=1' "$APP"

# t-cd06: WORKTREE accordion in the cockpit rail — single-select rows sourced
# from /api/worktrees, gating the terminal mount behind an explicit pick for a
# fresh OPEN start (Resume doesn't need to re-ask; the daemon persists cwd
# itself, falling back to re-resolving if that worktree was since deleted).
assert_grep 'id="ck-worktree-section"' "$APP"
assert_grep 'id="ck-worktree"' "$APP"
assert_grep 'function renderCockpitWorktree' "$APP"
assert_grep 'function selectCockpitWorktree' "$APP"
assert_grep 'function maybeMountCockpitTerminal' "$APP"
assert_grep "fetch\\('/api/worktrees'\\)" "$APP"
assert_grep "cockpitState.worktreeCwd" "$APP"
if grep -q "worktreeCwd = (t.status === 'open') ? '' : ''" "$APP"; then
  fail "a fresh OPEN start must gate on worktreeCwd === null, not default-select a row"
fi

# t-cd06 amendment: warn once before an in_progress ticket's first (unlocked)
# non-main worktree pick, since a worktree checkout only carries committed
# history and the pick locks in for every future Resume.
assert_grep "async function selectCockpitWorktree" "$APP"
assert_grep "api/worktree-lock/" "$APP"
assert_grep "lock.main_dirty" "$APP"

# t-cd06: reopening an already-locked in_progress ticket must show its real
# worktree as selected, not default the picker to Main checkout — the daemon
# uses the locked cwd regardless of what's displayed.
assert_grep "lock.locked && lock.cwd" "$APP"

# t-cd06: subtle "Working in: <label>" reminder, since the radio selection
# alone is easy to miss when scanning back to this rail.
assert_grep 'id="ck-worktree-note"' "$APP"
assert_grep "function updateWorktreeNote" "$APP"

# t-cd06: Status is read independently of the WORKTREE accordion — it must
# also surface the locked worktree, not just HANDOFF.md's saved-state prose.
assert_grep "Running in" "$APP"

# t-5c20: semantic version in the header + a Versions block at the top of the
# "?" tour panel; the repo-root VERSION file is the source of truth.
[[ -f "$ROOT/VERSION" ]] || fail "repo-root VERSION file is missing (t-5c20)"
assert_grep 'id="tour-versions"' "$APP"
assert_grep 'id="tv-canon"' "$APP"
assert_grep 'id="tv-board"' "$APP"
assert_grep 'id="tv-daemon"' "$APP"
assert_grep "'canon v'" "$APP"

# Branch footer: a ticket whose sibling-worktree copy has a different status is
# flagged on the card; a matching one is not (feed it the reject case too).
assert_grep 'function branchLine\(t\)' "$APP"
assert_grep 'card-branch-warn' "$APP"
fx="$(mktemp -d)"; trap 'rm -rf "$fx" "$fx-wt"' EXIT
git -C "$fx" init -q -b main
mkdir -p "$fx/.tickets/t-1" "$fx/.tickets/t-2"
printf -- '---\nid: t-1\nstatus: open\n---\n' > "$fx/.tickets/t-1/ticket.md"
printf -- '---\nid: t-2\nstatus: open\n---\n' > "$fx/.tickets/t-2/ticket.md"
git -C "$fx" add -A
git -C "$fx" -c user.email=t@t -c user.name=t commit -qm init
git -C "$fx" worktree add -q -b sprint/t-1 "$fx-wt"
sed -i 's/status: open/status: closed/' "$fx-wt/.tickets/t-1/ticket.md"
fxp="$(cd "$fx" && pwd -W 2>/dev/null || pwd)"
out="$(cd "$ROOT/tools/sprint-check-app" && SPRINT_CHECK_ROOT="$fxp" python3 -c "
import server
from pathlib import Path
r = Path('$fxp'); t = server.load_tickets(r); server.annotate_branch_state(t, r)
print(sorted((x['id'], x['branch'], (x.get('other_branch') or {}).get('branch', '-')) for x in t))
" 2>/dev/null || true)"
[[ "$out" == "[('t-1', 'main', 'sprint/t-1'), ('t-2', 'main', '-')]" ]] || fail "annotate_branch_state: unexpected output: $out"

printf 'sprint-check-app: ok\n'
