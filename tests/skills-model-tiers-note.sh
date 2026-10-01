#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
tmp_home="$(mktemp -d)"
trap 'rm -rf "$project" "$tmp_home"' EXIT

export HOME="$tmp_home"

printf '# Agents\n' > "$project/AGENTS.md"

# Non-interactive (test harness has no tty): prompt must be skipped, no write.
"$SKILLS" add efficiency "$project" >/dev/null
assert_count 0 "MODEL-TIERS:BEGIN" "$project/AGENTS.md"

# Re-add stays a no-op the same way.
"$SKILLS" add efficiency "$project" >/dev/null
assert_count 0 "MODEL-TIERS:BEGIN" "$project/AGENTS.md"

# If the note is already present (e.g. from a prior interactive Y), re-add
# must not duplicate it and must not prompt/hang.
cat "$ROOT/AGENTS.md" | awk '/<!-- MODEL-TIERS:BEGIN -->/{flag=1} flag; /<!-- MODEL-TIERS:END -->/{flag=0}' >> "$project/AGENTS.md"
assert_count 1 "MODEL-TIERS:BEGIN" "$project/AGENTS.md"

"$SKILLS" add efficiency "$project" >/dev/null
assert_count 1 "MODEL-TIERS:BEGIN" "$project/AGENTS.md"

# --- stale block sync (t-bd3e) ---

canon_block() { awk '/<!-- MODEL-TIERS:BEGIN -->/{f=1} f; /<!-- MODEL-TIERS:END -->/{if(f) exit}' "$1"; }
outside_block() { awk '/<!-- MODEL-TIERS:BEGIN -->/{f=1} !f; /<!-- MODEL-TIERS:END -->/{f=0}' "$1"; }

stale="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$stale"' EXIT
{ printf '# Agents\nUser content before.\n\n'; canon_block "$ROOT/AGENTS.md"; printf '\nUser content after.\n'; } > "$stale/AGENTS.md"
"$SKILLS" add efficiency "$stale" >/dev/null 2>&1   # registers table row + import; block already current
awk '/<!-- MODEL-TIERS:BEGIN -->/{n=1} n==3{print "STALE: structural low-risk check"; n++; next} n{n++} {print}' "$stale/AGENTS.md" > "$stale/a.tmp" && mv "$stale/a.tmp" "$stale/AGENTS.md"
assert_count 1 "STALE: structural low-risk check" "$stale/AGENTS.md"
before_outside="$(outside_block "$stale/AGENTS.md")"
out="$("$SKILLS" add efficiency "$stale" 2>&1)"
assert_contains "$out" "updated MODEL-TIERS block"
assert_count 0 "STALE: structural low-risk check" "$stale/AGENTS.md"
assert_eq "$(canon_block "$ROOT/AGENTS.md")" "$(canon_block "$stale/AGENTS.md")"
assert_eq "$before_outside" "$(outside_block "$stale/AGENTS.md")"
assert_count 1 "MODEL-TIERS:BEGIN" "$stale/AGENTS.md"
assert_count 1 "MODEL-TIERS:END" "$stale/AGENTS.md"

# Already current: byte-identical, nothing reported.
h1="$(md5sum "$stale/AGENTS.md" | cut -d' ' -f1)"
out="$("$SKILLS" add efficiency "$stale" 2>&1)"
[[ "$out" != *"MODEL-TIERS"* ]] || fail "current block reported as updated: $out"
assert_eq "$h1" "$(md5sum "$stale/AGENTS.md" | cut -d' ' -f1)"

# BEGIN without END: left byte-identical, with a warning (a replace would eat the rest of the file).
unclosed="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$stale" "$unclosed"' EXIT
printf '# Agents\n<!-- MODEL-TIERS:BEGIN -->\nold note\nUser content after.\n' > "$unclosed/AGENTS.md"
"$SKILLS" add efficiency "$unclosed" >/dev/null 2>&1   # first add writes the table row and import
h2="$(md5sum "$unclosed/AGENTS.md" | cut -d' ' -f1)"
out="$("$SKILLS" add efficiency "$unclosed" 2>&1)"
assert_contains "$out" "not a single BEGIN/END pair"
assert_eq "$h2" "$(md5sum "$unclosed/AGENTS.md" | cut -d' ' -f1)"
assert_count 1 "User content after." "$unclosed/AGENTS.md"

# A doc example quoting the markers inside a ``` fence is not the block: the real block is synced,
# the example is left byte-identical (reviewer finding, t-bd3e).
fenced="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$stale" "$unclosed" "$fenced"' EXIT
{ printf '# Agents\n\n```md\n<!-- MODEL-TIERS:BEGIN -->\nexample only\n<!-- MODEL-TIERS:END -->\n```\n\n'
  canon_block "$ROOT/AGENTS.md" | awk 'NR==3{print "STALE LINE"; next} {print}'; } > "$fenced/AGENTS.md"
out="$("$SKILLS" add efficiency "$fenced" 2>&1)"
assert_contains "$out" "updated MODEL-TIERS block"
assert_count 1 "example only" "$fenced/AGENTS.md"
assert_count 0 "STALE LINE" "$fenced/AGENTS.md"
assert_count 2 "<!-- MODEL-TIERS:BEGIN -->" "$fenced/AGENTS.md"   # the fenced example + the real block

# Two real BEGIN/END pairs: ambiguous, left byte-identical with a warning.
dup="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$stale" "$unclosed" "$fenced" "$dup"' EXIT
{ printf '# Agents\n'; canon_block "$ROOT/AGENTS.md"; printf 'between\n'; canon_block "$ROOT/AGENTS.md" | awk 'NR==3{print "STALE"; next} {print}'; } > "$dup/AGENTS.md"
"$SKILLS" add efficiency "$dup" >/dev/null 2>&1
h3="$(md5sum "$dup/AGENTS.md" | cut -d' ' -f1)"
out="$("$SKILLS" add efficiency "$dup" 2>&1)"
assert_contains "$out" "not a single BEGIN/END pair"
assert_eq "$h3" "$(md5sum "$dup/AGENTS.md" | cut -d' ' -f1)"

# CRLF target (Windows): the stale block is synced, the file stays CRLF-only, and a second add is a
# no-op — no duplicate efficiency @-import appended.
crlf="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$stale" "$unclosed" "$fenced" "$dup" "$crlf"' EXIT
{ printf '# Agents\n'; canon_block "$ROOT/AGENTS.md" | awk 'NR==3{print "STALE CRLF"; next} {print}'; printf 'User after.\n'; } \
  | sed 's/$/\r/' > "$crlf/AGENTS.md"
"$SKILLS" add efficiency "$crlf" >/dev/null 2>&1
assert_count 0 "STALE CRLF" "$crlf/AGENTS.md"
[ "$(grep -c $'\r$' "$crlf/AGENTS.md")" -ge "$(grep -c "MODEL-TIERS\|User after" "$crlf/AGENTS.md")" ] || fail "sync dropped CRLF"
[ "$(awk '/MODEL-TIERS:BEGIN/{f=1} f && !/\r$/{n++} /MODEL-TIERS:END/{f=0} END{print n+0}' "$crlf/AGENTS.md")" -eq 0 ] || fail "synced block written LF into a CRLF file"
h4="$(md5sum "$crlf/AGENTS.md" | cut -d' ' -f1)"
out="$("$SKILLS" add efficiency "$crlf" 2>&1)"
assert_eq "$h4" "$(md5sum "$crlf/AGENTS.md" | cut -d' ' -f1)"
[ "$(tr -d '\r' < "$crlf/AGENTS.md" | grep -cxF "@$ROOT/standards/efficiency.md")" -eq 1 ] || fail "CRLF: efficiency @-import duplicated"

# --- removal path ---

# Non-interactive remove (test harness has no tty): block stays untouched.
"$SKILLS" remove efficiency "$project" >/dev/null
assert_count 1 "MODEL-TIERS:BEGIN" "$project/AGENTS.md"

# Removing efficiency when the block is absent doesn't error.
project2="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$project2"' EXIT
printf '# Agents\n' > "$project2/AGENTS.md"
"$SKILLS" add efficiency "$project2" >/dev/null
assert_count 0 "MODEL-TIERS:BEGIN" "$project2/AGENTS.md"
"$SKILLS" remove efficiency "$project2" >/dev/null
assert_count 0 "MODEL-TIERS:BEGIN" "$project2/AGENTS.md"

# --- real interactive round-trip (simulated tty via python3's pty, answering y) ---

run_with_tty() {
  # $1: command string, $2: answer to feed on the simulated tty.
  # Uses forkpty (not openpty+Popen) so the child gets a real controlling
  # terminal — offer_model_tiers_note/offer_remove_model_tiers_note open
  # /dev/tty directly, which requires an actual controlling tty, not just
  # piped stdin/stdout fds.
  python3 - "$1" "$2" <<'PYEOF'
import os, pty, sys, time

cmd, answer = sys.argv[1], sys.argv[2]
pid, master = pty.fork()
if pid == 0:
    os.environ.pop("SKILLS_SH_NO_TTY", None)  # t-2d74: this child has a real (pseudo) terminal
    os.execvp("/bin/bash", ["/bin/bash", "-c", cmd])
else:
    time.sleep(0.5)
    os.write(master, (answer + "\n").encode())
    try:
        while True:
            if not os.read(master, 4096):
                break
    except OSError:
        pass
    os.waitpid(pid, 0)
PYEOF
}

project3="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$project2" "$project3"' EXIT
printf '# Agents\n' > "$project3/AGENTS.md"

# Real interactive add: answering y writes the block.
run_with_tty "'$SKILLS' add efficiency '$project3'" "y"
assert_count 1 "MODEL-TIERS:BEGIN" "$project3/AGENTS.md"

# Real interactive remove: answering y strips the block and leaves no orphaned blank line —
# the file must round-trip back to exactly its pre-add state.
run_with_tty "'$SKILLS' remove efficiency '$project3'" "y"
assert_count 0 "MODEL-TIERS:BEGIN" "$project3/AGENTS.md"
assert_eq "$(printf '# Agents\n')" "$(cat "$project3/AGENTS.md")"

# --- what a project receives stays short and project-facing (t-70ea) ---
# The block is copied into every project's AGENTS.md (always-loaded context), so canon's own internal
# prose (board dropdown, gate agents, Codex/Pi notes, ticket ids) must live OUTSIDE the markers.

block="$(canon_block "$ROOT/AGENTS.md")"
lines="$(printf '%s\n' "$block" | wc -l | tr -d ' ')"
[[ "$lines" -le 14 ]] || fail "the MODEL-TIERS block is $lines lines (max 14): canon-internal prose belongs after the END marker"
for needle in '## Model Tiers' '`explore` → Haiku' '`plan creation` → Fable or Opus' '`implement` → Haiku/Sonnet' '`review` / `grill` → Opus' 'skills/sprint/reference/complete.md'; do
  printf '%s\n' "$block" | grep -qF -- "$needle" || fail "the MODEL-TIERS block lost '$needle'"
done
for internal in 'tools/sprint-check-app' 'model-tiers.json' 'agents/canon-' 'spawn_agent' 'Cross-harness' 'Gate model' 't-7e36' 't-ef27' 't-c774' 'North-star' 'Close-gate effort' 'pi session'; do
  if printf '%s\n' "$block" | grep -qF -- "$internal"; then fail "the MODEL-TIERS block carries canon-internal text: $internal"; fi
done

# Nothing is lost for canon: every line the old block had and the new one dropped is still in canon's AGENTS.md,
# after the END marker (canon's own sessions load AGENTS.md natively and need it).
old_block="$ROOT/tests/fixtures/model-tiers-old-block.md"
after_end="$(awk '/<!-- MODEL-TIERS:END -->/{f=1; next} f' "$ROOT/AGENTS.md")"
while IFS= read -r l; do
  [[ -z "${l//[[:space:]]/}" ]] && continue
  printf '%s\n' "$block" | grep -qxF -- "$l" && continue
  printf '%s\n' "$after_end" | grep -qxF -- "$l" || fail "a line the old block had was dropped, not moved after END: $l"
done < "$old_block"

# A project still carrying the old long block gets the short one; the rest of its file is untouched.
legacy="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$stale" "$unclosed" "$legacy"' EXIT
printf '# Agents\nUser content before.\n' > "$legacy/AGENTS.md"
"$SKILLS" add efficiency "$legacy" >/dev/null 2>&1   # registers the table row + import (no block: no tty to ask)
{ printf '\n'; cat "$old_block"; printf '\nUser content after.\n'; } >> "$legacy/AGENTS.md"
assert_count 1 "MODEL-TIERS:BEGIN" "$legacy/AGENTS.md"
[[ "$(canon_block "$legacy/AGENTS.md" | wc -l | tr -d ' ')" -ge 40 ]] || fail "the legacy fixture is not the long block"
before_outside="$(outside_block "$legacy/AGENTS.md")"
out="$("$SKILLS" add efficiency "$legacy" 2>&1)"
assert_contains "$out" "updated MODEL-TIERS block"
assert_eq "$(canon_block "$ROOT/AGENTS.md")" "$(canon_block "$legacy/AGENTS.md")"
assert_eq "$before_outside" "$(outside_block "$legacy/AGENTS.md")"
[[ "$(canon_block "$legacy/AGENTS.md" | wc -l | tr -d ' ')" -le 14 ]] || fail "the legacy project's block did not shrink"

printf 'skills-model-tiers-note: ok\n'
