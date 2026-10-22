#!/usr/bin/env bash
# pipefail-rewrites (t-ad89) — the early-exit readers rewritten for t-ad89 give the same answer when the writer's output is far
# larger than a pipe buffer (64 KB). The old forms (`… | grep -q`, `| head`) SIGPIPE the writer there and pipefail turns that into
# a wrong answer. Bash 3.2-safe: no mapfile, ${v,,}, ;;& or declare -A.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
big() { local i; for i in $(seq 1 6000); do printf 'filler line %05d of a long listing to outgrow a pipe buffer\n' "$i"; done; }   # ~360 KB

# tools/skills/agents.sh: an AGENTS.md that already has the platforms note (near the top of a big file) does not get a second one
. "$ROOT/tools/skills/agents.sh"
{ printf '<!-- AI-SKILLS:BEGIN -->\n%s\n%s\n' "$SKILLS_TABLE_NOTE" "$PLATFORMS_NOTE"; big; printf '| sprint | dev | skills/sprint/SKILL.md |\n<!-- AI-SKILLS:END -->\n'; } > "$W/AGENTS.md"
mkdir "$W/shim"; printf '#!/bin/bash\necho ran >> "%s/awk.log"\nexec "%s" "$@"\n' "$W" "$(command -v awk)" > "$W/shim/awk"; chmod +x "$W/shim/awk"
PATH="$W/shim:$PATH" skills_table_upsert "$W/AGENTS.md" sprint "| sprint | dev | skills/sprint/SKILL.md |" >/dev/null 2>&1 || true
[[ ! -s "$W/awk.log" ]] || fail "pipefail-rewrites: skills_table_upsert re-ran the platforms-note rewrite on an AGENTS.md that already had the note (a SIGPIPE read as 'note missing')"

# tools/cockpit-launch-lib.sh: _port_in_use finds the port in a long ss listing (a PATH holding only grep and a fake ss, so no lsof)
B="$W/bin"; mkdir "$B"; ln -s "$(command -v grep)" "$B/grep"
printf '#!/bin/bash\necho "LISTEN 0 4096 127.0.0.1:4711 0.0.0.0:*"\ncat "$BIGFILE"\n' > "$B/ss"; chmod +x "$B/ss"
ln -s "$(command -v cat)" "$B/cat"; big > "$W/big.txt"
( . "$ROOT/tools/cockpit-launch-lib.sh"; export BIGFILE="$W/big.txt"; PATH="$B"; _port_in_use 4711 ) || fail "pipefail-rewrites: _port_in_use missed a port listed first in a long ss output"
( . "$ROOT/tools/cockpit-launch-lib.sh"; export BIGFILE="$W/big.txt"; PATH="$B"; ! _port_in_use 4712 ) || fail "pipefail-rewrites: _port_in_use found a port that is not listed"

# the here-string / sed / awk forms the headless tools, release-daemon, tools/canon and tools/tkt now use
text="$(printf 'HEADLESS_VERDICT: PASS\n'; big)"
grep -q '^HEADLESS_VERDICT: PASS$' <<<"$text" || fail "pipefail-rewrites: a here-string grep -q missed a match in a big variable"
grep -qx "sprint.zip" <<<"$(printf 'sprint.zip\n'; big)" || fail "pipefail-rewrites: release-daemon's asset lookup missed the first of many assets"
[[ "$(big | sed -n '1,10s/^/  /p' | wc -l | tr -d ' ')" == 10 ]] || fail "pipefail-rewrites: sed -n '1,10' over a big stream should print 10 lines"
wt="$({ printf 'worktree /a\nbranch refs/heads/x\n'; big; } | awk -v r="branch refs/heads/x" '/^worktree /{ w = substr($0, 10) } $0 == r { print w }')"
[[ "$wt" == /a ]] || fail "pipefail-rewrites: the worktree lookup should find /a, got: $wt"
echo "pipefail-rewrites: ok"
