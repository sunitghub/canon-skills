#!/usr/bin/env bash
# tests/no-python-windows-paths.sh — t-55c1: on Windows canon may assume only Git for Windows, so end-user
# scripts must not reach for Python except at known, gated sites. Counts non-comment lines that invoke
# python/python3/py per end-user script and compares them with this allowlist. A new use fails until it's
# gated (have_python / _settings_backend / a Windows-only exe branch) and listed here with its reason.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# file|allowed-count|why it's safe on a Git-only Windows machine
allowlist='
tools/skills/prompts.sh|9|settings merges: python branch only when _settings_backend=python; else powershell.exe or a visible skip
tools/platform-lib.sh|1|have_python itself: never executes a WindowsApps alias, requires print(1) to output 1
tools/cockpit-launch-lib.sh|1|server.py start only when have_python; on Windows without it, sprint-check-win.exe
tools/sprint-headless|3|non-Windows branch; Windows uses the committed Go JSON helper exe
tools/sprint-headless-eval|5|non-Windows JSON branch + the Linux-CI-only --allowed-tools-file option (fails loudly)
'

# Everything an end user runs or that canon installs into a project.
files=(tools/sprint tools/tkt tools/skills.sh tools/skills/*.sh tools/platform-lib.sh tools/cockpit-launch-lib.sh
       tools/canon-cockpit tools/sprint-check tools/hooks-lib.sh tools/subagent-log.sh tools/frontmatter-lib.sh
       tools/ticket-root.sh tools/gate-model.sh tools/gate-cache.sh tools/skill-lib.sh tools/upkeep-run
       tools/sprint-headless tools/sprint-headless-eval scripts/pre-commit-hook-template.sh)

count_python() {  # non-comment lines that invoke python3 / python / py -
  grep -vE '^[[:space:]]*#' "$ROOT/$1" | grep -cE '(^|[^A-Za-z0-9_./-])(python3?|py -)([^A-Za-z0-9_]|$)' || true
}

bad=0
for f in "${files[@]}"; do
  [ -f "$ROOT/$f" ] || { echo "no-python-windows-paths: listed file missing: $f" >&2; bad=1; continue; }
  n="$(count_python "$f")"
  allowed="$(printf '%s\n' "$allowlist" | awk -F'|' -v f="$f" '$1 == f { print $2 }')"
  if [ "$n" != "${allowed:-0}" ]; then
    echo "no-python-windows-paths: $f has $n python line(s), allowlist says ${allowed:-0}. Gate it (have_python/_settings_backend) and update the allowlist with a reason, or remove it." >&2
    bad=1
  fi
done
[ "$bad" -eq 0 ] || fail "python use in end-user scripts changed (see above)"

printf 'no-python-windows-paths: ok\n'
