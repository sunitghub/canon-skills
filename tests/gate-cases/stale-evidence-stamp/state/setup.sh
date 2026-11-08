#!/usr/bin/env bash
# a tiny repo, a ticket, a passing stamp taken at the first commit, then one more tracked commit: the stamp no longer names the graded head
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q -b main repo && cd repo
git config user.email t@t && git config user.name t
mkdir -p .tickets/t-abcd src
echo '# t' > .tickets/t-abcd/ticket.md; echo one > src/a.txt
git add src && git add -f .tickets/t-abcd/ticket.md && git commit -qm one
bash "$CANON_ROOT/tools/evidence.sh" stamp t-abcd suite -- true >/dev/null 2>&1
echo two > src/a.txt && git add src && git commit -qm two
