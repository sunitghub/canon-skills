#!/usr/bin/env bash
# pipefail-grep-q (t-bcb8) — no test pipes into `grep -q`. Under `set -o pipefail` (every suite that sources tests/helpers.sh has it),
# `grep -q` exits at its first match, the writer's next write gets SIGPIPE (exit 141), and the pipeline reports failure although the
# text was found. Whether the writer finishes first is timing: alone it nearly always does, under scripts/test.sh's parallel load it
# often doesn't (windows-install, doc-update-behavior and skills-model-tiers-note failed only in the full run). A `!` in front turns
# the same race into a false pass. Write `| grep … >/dev/null` (grep reads to the end) or `grep -q … <<<"$var"` instead.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/helpers.sh"
DIR="${PIPEFAIL_GREP_Q_DIR:-$ROOT/tests}"

# a pipe, then grep with a short-flag cluster holding q, or --quiet/--silent; comment lines don't count
RX='\|[[:space:]]*(command[[:space:]]+)?grep[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([[:space:]]|$)'
scan() {   # scan <dir>: print file:line:text for every offending line under <dir>
  local f
  while IFS= read -r f; do
    grep -nE -- "$RX" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|${f#$1/}:|" || true
  done < <(find "$1" -type f -name '*.sh' | sort)
}

# the scan must find a planted offender (or a passing run proves nothing)
T="${TMPDIR:-/tmp}"; WORK="$(mktemp -d "${T%/}/pipefail-grep-q.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
Q=q; bad="echo x | grep -${Q}F x || exit 1"   # assembled, so this file's own source never matches
printf '%s\n' "$bad" "# a | grep -${Q} in a comment" "grep -${Q} x <<<\"\$v\"" 'echo x | grep x >/dev/null' > "$WORK/planted.sh"
got="$(scan "$WORK")"
[[ "$got" == "planted.sh:1:$bad" ]] || fail "pipefail-grep-q: the scan should flag exactly the one planted pipe into grep -q, got: $got"

hits="$(scan "$DIR")"
[[ -z "$hits" ]] || fail "pipefail-grep-q: a pipe into grep -q fails at random under pipefail (SIGPIPE to the writer); use '| grep … >/dev/null' or a here-string:
$hits"
echo "pipefail-grep-q: ok (no test pipes into grep -q)"
