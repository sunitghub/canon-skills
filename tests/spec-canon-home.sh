#!/usr/bin/env bash
# spec-canon-home (t-acfa) — every board or daemon process the board spec spawns sets CANON_HOME, so its events go to a scratch
# folder, never the user's ~/.canon/events (the spec's own daemons once wrote ~280 test sessions there). run-board-spec.sh pins it
# for Playwright too; this keeps a hand run (npm run test:ui) and any new spawn safe. Protects the user's activity log.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
SPEC="${SPEC_CANON_HOME_FILE:-$ROOT/tests/sprint-check-app.spec.js}"   # overridable so the check can be reverted on a scratch copy

# A spawn of the board (goBoardBin()) or the daemon binary (daemonBin) and the next 8 lines (its options object): CANON_HOME must be there.
bad="$(awk '
  /spawn\((goBoardBin\(\)|daemonBin),/ { start = NR; seen = 0; next_end = NR + 8 }
  start && NR <= next_end && /CANON_HOME:/ { seen = 1 }   # the key, not the word (a comment names it too)
  start && NR == next_end { if (!seen) print start; start = 0 }
  END { if (start && !seen) print start }
' "$SPEC")"
n="$(grep -cE 'spawn\((goBoardBin\(\)|daemonBin),' "$SPEC" || true)"
[[ "$n" -ge 3 ]] || fail "spec-canon-home: found $n board/daemon spawns, expected at least 3 (did the spawn calls change shape?)"
[[ -z "$bad" ]] || fail "spec-canon-home: a spawn without CANON_HOME in tests/sprint-check-app.spec.js at line(s): $(echo $bad)"
echo "spec-canon-home: ok ($n spawns, each sets CANON_HOME)"
