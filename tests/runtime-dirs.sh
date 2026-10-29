#!/usr/bin/env bash
# runtime-dirs — a default install's CANON_HOME is its git clone, so whatever the board, the event log and themes write there must be
# ignored, or `canon update` refuses on it (t-c724; events/ and themes/ did on a second Mac). Runs the board in a scratch clone used as
# CANON_HOME, drives a page load, a theme read, a settings write and a ticket event, and requires `git status` in the clone to be empty.
# A new runtime folder that pkg_is_data (tools/pkg-lib.sh) does not name and .gitignore does not ignore fails here.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
command -v curl >/dev/null 2>&1 || fail "runtime-dirs: curl is required"

WORK="$(mktemp -d)"; GO_PID=""; PROJ=""
trap '[[ -n "$GO_PID" ]] && kill "$GO_PID" 2>/dev/null; rm -rf "$WORK" "$PROJ"' EXIT
export HOME="$WORK/home"; export XDG_CONFIG_HOME="$WORK/xdg"; export TMPDIR="$WORK/tmp"; mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$TMPDIR"
unset COCKPIT_STATE_DIR CANON_COCKPIT_PORT
export SPRINT_CHECK_NO_BROWSER=1
CLONE="$WORK/clone"; PROJ="$(make_project)"
git init -q -b main "$CLONE"; cp "$ROOT/.gitignore" "$CLONE/.gitignore"; cp "$ROOT/VERSION" "$CLONE/VERSION"
git -C "$CLONE" -c user.email=t@example.com -c user.name=test add -A; git -C "$CLONE" -c user.email=t@example.com -c user.name=test commit -qm init

BIN="$(build_board "$WORK/boardbin")"; mkdir -p "$WORK/boardbin/tools"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
(cd "$ROOT" && SPRINT_CHECK_ROOT="$PROJ" CANON_HOME="$CLONE" SPRINT_CHECK_NO_BROWSER=1 exec "$BIN" "$PORT") >/dev/null 2>&1 &
GO_PID=$!
for i in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/tickets" && break; sleep 0.1; done
B="http://127.0.0.1:$PORT"
curl -s -o /dev/null "$B/api/tickets" || fail "runtime-dirs: the board did not start"
for p in / /api/themes /api/settings /api/cockpit-status /api/projects /api/version; do curl -s -o /dev/null "$B$p" || true; done
curl -s -o /dev/null -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d "{\"path\":\"$PROJ\",\"description\":\"runtime dirs\"}" "$B/api/projects" || true   # the registry: cockpit/projects.json
curl -s -o /dev/null -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d '{"key":"model_tier_review","value":"opus"}' "$B/api/settings" || true   # a setting: settings.json and an event
(cd "$PROJ" && CANON_HOME="$CLONE" SPRINT_CHECK_BIN="$BIN" "$ROOT/tools/tkt" create "runtime dirs probe" >/dev/null 2>&1) || fail "runtime-dirs: tkt create failed"   # the event log: events/
mkdir -p "$CLONE/themes"; : > "$CLONE/themes/probe.json"   # a custom theme, as a user adds one

left="$(git -C "$CLONE" status --porcelain --untracked-files=all)"
[[ -z "$left" ]] || fail "runtime-dirs: the board and event log left changes in a default install's clone (add the folder to pkg_is_data and .gitignore):
$left"
for d in cockpit events themes; do [[ -d "$CLONE/$d" ]] || fail "runtime-dirs: nothing was written to $d/ under CANON_HOME, so this test no longer proves it"; done
echo "runtime-dirs: ok (board, event log and themes leave a default install's clone clean)"
