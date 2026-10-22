#!/usr/bin/env bash
# pipefail-early-exit (t-ad89, absorbs t-bcb8 and t-92e1) — no shell file under tools/, scripts/ or tests/ ends a pipe in a reader that
# stops early (`grep -q`, `head`, `awk … exit`, `sed … q`) unless tests/pipefail-early-exit-allow.txt says why the writer is bounded.
# Under `set -o pipefail` such a reader makes the writer die of SIGPIPE (141) once its output outgrows the pipe buffer (~64 KB), and
# pipefail turns that into a failure, or, under `!`, a false pass. Alone and small it nearly always works; under load or on a bigger
# input it fails at random (t-fef7, t-90bc, t-bcb8). Rewrite: let the reader open the file, capture first then `grep -q … <<<"$v"`,
# an inline `grep -c`, or `|| true` where the reader's own result is what you keep. Bash 3.2-safe: no mapfile, ${v,,}, ;;& or declare -A.
#
# Allow-list rows (tab separated): <file relative to repo root> <TAB> <text the line contains> <TAB> <why the writer is bounded>.
# A row matches on the line's text, never its number; a row that matches no line is stale and fails.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/helpers.sh"
ALLOW="$ROOT/tests/pipefail-early-exit-allow.txt"

# a single `|` (not `||`), then an early-exit reader; comment lines don't count
RX='(^|[^|])\|[[:space:]]*(command[[:space:]]+)?(grep[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([[:space:]]|$)|head([[:space:]]|$)|awk[[:space:]].*exit|sed[[:space:]][^|]*[;{[:space:]]q[};'"'"'"])'

is_shell() { case "$1" in *.sh) return 0 ;; esac; case "$(head -c 64 "$1" 2>/dev/null | head -n 1)" in '#!'*sh*) return 0 ;; esac; return 1; }

scan() {   # scan <dir>: print rel:line:text for every offending line in every shell file under <dir>
  local f
  while IFS= read -r f; do
    is_shell "$f" || continue
    grep -nE -- "$RX" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|${f#"$1"/}:|" || true
  done < <(find "$1" -type f \( -path '*/node_modules' -o -path '*/.git' -o -path '*/fixtures' \) -prune -o -type f -print | sort)
}

filter() {   # filter <allow-file>: read hits on stdin, print those no row allows; write used row numbers to $USED
  local hit rel text n row_f row_t keep
  while IFS= read -r hit; do
    rel="${hit%%:*}"; text="${hit#*:*:}"; keep=1; n=0
    while IFS=$'\t' read -r row_f row_t _; do
      n=$((n + 1))
      [[ -n "$row_f" && "$row_f" != \#* ]] || continue
      if [[ "$row_f" == "$rel" && "$text" == *"$row_t"* ]]; then keep=0; echo "$n" >> "$USED"; fi
    done < "$1"
    [[ "$keep" -eq 0 ]] || printf '%s\n' "$hit"
  done
}

T="${TMPDIR:-/tmp}"; WORK="$(mktemp -d "${T%/}/pipefail-early-exit.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
USED="$WORK/used"

# the scan must flag planted offenders and honour a planted allow row (or a passing run proves nothing)
Q=q; H=head; mkdir "$WORK/p"
printf '%s\n' "echo x | grep -${Q}F x || exit 1" "# a | grep -${Q} in a comment" "grep -${Q} x <<<\"\$v\"" 'echo x | grep x >/dev/null' \
  'a=$(big | head -n 1)' 'big | awk '"'"'{print; exit}'"'" 'big | sed -n '"'"'1{p;q}'"'" 'a || head x' 'ok | grep -c x' 'safe | grep '"-${Q}"' keep' > "$WORK/p/planted.sh"
printf '#!/bin/bash\nbig | head -1\n' > "$WORK/p/noext"; printf 'big | head -1\n' > "$WORK/p/notshell.txt"
printf '# a comment row\n\nplanted.sh\tsafe | grep\tsmall fixed list\nplanted.sh\tnever matches\tstale row\nother.sh\tbig | %s -n 1\tright text, wrong file\n' "$H" > "$WORK/allow-self"
: > "$USED"; got="$(scan "$WORK/p" | filter "$WORK/allow-self")"
want="$(printf '%s\n' 'noext:2:big | head -1' "planted.sh:1:echo x | grep -${Q}F x || exit 1" 'planted.sh:5:a=$(big | head -n 1)' "planted.sh:6:big | awk '{print; exit}'" "planted.sh:7:big | sed -n '1{p;q}'")"
[[ "$got" == "$want" ]] || fail "pipefail-early-exit: the scan should flag exactly the planted readers, got: $got"
[[ "$(sort -u "$USED")" == 3 ]] || fail "pipefail-early-exit: a planted allow row should match its line and only that one"

: > "$USED"
hits=""; for d in tools scripts tests; do hits="$hits$(scan "$ROOT/$d" | sed "s|^|$d/|")"$'\n'; done
left="$(printf '%s' "$hits" | grep -v '^$' | filter "$ALLOW" || true)"
[[ -z "$left" ]] || fail "pipefail-early-exit: a reader that stops early SIGPIPEs its writer under pipefail once the output outgrows a pipe buffer. Rewrite it (see the header) or add a row to tests/pipefail-early-exit-allow.txt saying why the writer is bounded:
$left"
total="$(grep -cvE '^[[:space:]]*(#|$)' "$ALLOW" || true)"
stale="$(awk 'NR==FNR{u[$1]=1; next} !/^[[:space:]]*(#|$)/ && !(FNR in u){print FNR": "$0}' "$USED" "$ALLOW")"
[[ -z "$stale" ]] || fail "pipefail-early-exit: allow-list rows that match no line (remove them):
$stale"
echo "pipefail-early-exit: ok (no unlisted early-exit reader; $total allow-listed)"
