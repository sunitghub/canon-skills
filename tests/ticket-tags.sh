#!/usr/bin/env bash
# t-37e8: ticket tags through the shipped command (tkt create --tags, tkt tags): the stored line, every refusal, and parity with
# the board's rule (tests/tags-corpus.tsv is the one corpus; tools/canon-go/internal/board/tags_test.go runs it through the board).
# Prod path: a user (or a cloud session) tagging a ticket from the terminal.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
TKT="$ROOT/tools/tkt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ticket-tags.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.tickets"
cd "$WORK" && git init -q .
export CANON_HOME="$WORK/.canon-home" XDG_CONFIG_HOME="$WORK/.xdg" HOME="$WORK/home"; mkdir -p "$HOME"
run() { CANON_TICKETS_DIR="$WORK/.tickets" "$TKT" "$@"; }

echo "ticket-tags"
# the corpus: tkt stores what the board stores, and refuses what the board refuses
n=0
while IFS=$'\t' read -r input want; do
  case "$input" in "#"*) continue ;; esac
  [[ -z "$input$want" ]] && continue
  n=$((n + 1))
  if out="$(run create --tags "$input" "corpus $n" 2>&1)"; then
    id="$out"
    got="$(grep -m1 '^tags: ' "$WORK/.tickets/$id/ticket.md" | sed 's/^tags: //' || true)"
    if [[ "$want" == "ERR" ]]; then echo "  FAIL create --tags '$input' succeeded, want a refusal"; exit 1; fi
    if [[ "$got" != "$want" ]]; then echo "  FAIL create --tags '$input' stored '$got', want '$want'"; exit 1; fi
  else
    if [[ "$want" != "ERR" ]]; then echo "  FAIL create --tags '$input' was refused ($out), want '$want'"; exit 1; fi
  fi
done < "$ROOT/tests/tags-corpus.tsv"
[[ $n -ge 15 ]] || { echo "  FAIL only $n corpus rows ran"; exit 1; }
echo "  ok   the corpus ($n rows) gives the board's answers"

# a refused create writes no ticket; newline and frontmatter injection are refused, not truncated
before="$(ls "$WORK/.tickets" | wc -l | tr -d ' ')"
for bad in $'a\nstatus: closed' $'a\rb' 'a,b,c,d,e,f,g,h,i' 'x: y'; do
  if run create --tags "$bad" "evil" >/dev/null 2>&1; then echo "  FAIL create --tags accepted a hostile list"; exit 1; fi
done
[[ "$(ls "$WORK/.tickets" | wc -l | tr -d ' ')" == "$before" ]] || { echo "  FAIL a refused create left a ticket behind"; exit 1; }
echo "  ok   hostile tag lists are refused and nothing is written"

# tkt tags: print, replace, clear, refuse; the rest of the frontmatter is untouched
id="$(run create "plain")"
[[ "$(run tags "$id")" == "$id: tags=" ]] || { echo "  FAIL a fresh ticket does not print empty tags"; exit 1; }
run tags "$id" "Go, GitHub" >/dev/null
grep -qx 'tags: go,github' "$WORK/.tickets/$id/ticket.md" || { echo "  FAIL tkt tags did not store the line"; exit 1; }
[[ "$(grep -c '^tags:' "$WORK/.tickets/$id/ticket.md")" == 1 ]] || { echo "  FAIL a second tags line"; exit 1; }
run tags "$id" "security" >/dev/null
[[ "$(grep -c '^tags:' "$WORK/.tickets/$id/ticket.md")" == 1 && "$(run tags "$id")" == "$id: tags=security" ]] || { echo "  FAIL replace"; exit 1; }
grep -qx 'status: open' "$WORK/.tickets/$id/ticket.md" || { echo "  FAIL tkt tags touched another line"; exit 1; }
if run tags "$id" "bad tag" >/dev/null 2>&1; then echo "  FAIL tkt tags accepted an invalid tag"; exit 1; fi
grep -qx 'tags: security' "$WORK/.tickets/$id/ticket.md" || { echo "  FAIL a refused tkt tags changed the file"; exit 1; }
run tags "$id" "" >/dev/null
! grep -q '^tags:' "$WORK/.tickets/$id/ticket.md" || { echo "  FAIL an empty list did not clear the tags"; exit 1; }
echo "  ok   tkt tags prints, replaces, clears and refuses"
echo "ticket-tags: ok"
