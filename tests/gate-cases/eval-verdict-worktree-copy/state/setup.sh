#!/usr/bin/env bash
# a main checkout whose ticket holds the real passing eval-report, and a linked worktree holding its own .tickets/ copy with an older failing one
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q -b main repo && cd repo
git config user.email t@t && git config user.name t
mkdir -p .tickets/t-abcd
printf -- '---\nid: t-abcd\nstatus: in_progress\neval_fail_count: 0\n---\n# t\n' > .tickets/t-abcd/ticket.md
printf 'evaluator-run-id: 1-1\npass: the real one\n' > .tickets/t-abcd/eval-report.md
echo x > a.txt && git add a.txt && git commit -qm one
git worktree add -q ../wt
mkdir -p ../wt/.tickets/t-abcd
cp .tickets/t-abcd/ticket.md ../wt/.tickets/t-abcd/ticket.md
printf 'evaluator-run-id: 0-0\nfail: stale old failure\n' > ../wt/.tickets/t-abcd/eval-report.md
