#!/usr/bin/env bash
# cockpit-nongit-wording — t-4962: the Add Project dialog must not tell a person their folder has to be a git repo
# (non-git folders are accepted since t-07c8; live on a Windows VM the label still said "absolute path to a git repo").

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

dialog="$(grep -n -i 'project folder' "$ROOT/tools/sprint-check-app/cockpit.html" | head -5)"
assert_contains "$dialog" "Project folder (absolute path)"
if grep -i 'project folder' "$ROOT/tools/sprint-check-app/cockpit.html" | grep -qi 'git repo'; then
  fail "Add Project dialog says the folder must be a git repo"
fi

printf 'cockpit-nongit-wording: ok\n'
