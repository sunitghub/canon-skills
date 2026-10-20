#!/usr/bin/env bash
# tests/windows-no-python.sh — t-55c1, t-b62a: canon on a machine with no Python (a Windows machine with only Git for Windows,
# or macOS/Linux without python3). The settings.json rules go through the board binary's `settings` helper on every OS, so
# they are written with no Python and no PowerShell. A python3 or powershell.exe that runs is a test failure: each fake
# leaves a marker. Protects `skills.sh add|refresh sprint` and the tkt/sprint flow on such a machine.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
use_fresh_board "$tmp/bin"

# Traps: a placeholder python3 (the Windows Store alias does nothing, or installs Python) and a powershell.exe.
traps="$tmp/traps"; mkdir -p "$traps"
for t in python3 python powershell.exe; do printf '#!/usr/bin/env bash\ntouch "%s/ran-%s"\nexit 0\n' "$traps" "$t" > "$traps/$t"; done
chmod +x "$traps"/*
no_trap_ran() { ! ls "$traps"/ran-* >/dev/null 2>&1 || fail "$1: ran $(ls "$traps" | grep ran-)"; }

proj="$tmp/proj"; mkdir -p "$proj/.claude"
settings="$proj/.claude/settings.json"
run() {  # <is_windows 0|1> <function> — no Python, the traps first on PATH
  SKILLS_SH_ASSUME_YES=1 PATH="$traps:$PATH" bash -c '
    source "$1/tools/skills/project.sh"; source "$1/tools/skills/prompts.sh"
    if [ "$2" = 1 ]; then _is_windows() { return 0; }; else _is_windows() { return 1; }; fi
    "$3" "$4"' _ "$ROOT" "$1" "$2" "$proj"
}

for win in 0 1; do
  rm -f "$settings"; printf '{"model": "opus", "permissions": {"ask": ["X"]}}' > "$settings"
  out="$(run "$win" offer_install_deny_rules)"
  assert_contains "$out" "added install deny rules"
  for r in "Bash(brew install:*)" "Bash(winget install:*)"; do grep -qF "\"$r\"" "$settings" || fail "windows=$win: $r not written"; done
  grep -q '"model": "opus"' "$settings" && grep -q '"ask"' "$settings" || fail "windows=$win: other keys lost: $(cat "$settings")"
  out="$(run "$win" offer_subagent_log_permission)"
  assert_contains "$out" "added Bash(subagent-log.sh:*)"
  # Already present: silent, and the file stays byte-for-byte the same.
  before="$(cat "$settings")"
  assert_eq "" "$(run "$win" offer_install_deny_rules)"
  assert_eq "" "$(run "$win" offer_subagent_log_permission)"
  assert_eq "$before" "$(cat "$settings")"
  no_trap_ran "windows=$win"
done

# Inside a stdin-fed loop, as skills refresh runs it: the helper must not eat the loop's input (both skills seen, nothing re-added).
before="$(cat "$settings")"
out="$(printf 'efficiency\nsprint\n' | { n=0; while read -r _skill; do run 0 offer_install_deny_rules; n=$((n + 1)); done; echo "loops=$n"; })"
assert_eq "loops=2" "$out"
assert_eq "$before" "$(cat "$settings")"

# `skills.sh remove sprint` asks on the terminal, then removes only the subagent-log rule. A real pseudo-terminal from `script`
# (macOS and util-linux spell it differently); stdin stays open a while so the answer, not an EOF, is what the prompt reads.
pty() { if script -q /dev/null true </dev/null >/dev/null 2>&1; then script -q /dev/null "$@"; else script -qec "$(printf '%q ' "$@")" /dev/null; fi; }
grep -qF '"Bash(subagent-log.sh:*)"' "$settings" || fail "setup: the subagent-log rule should be present"
{ printf 'y\n'; sleep 3; } | PATH="$traps:$PATH" pty bash -c 'source "$1/tools/skills/project.sh"; source "$1/tools/skills/prompts.sh"
  offer_remove_subagent_log_permission "$2"' _ "$ROOT" "$proj" >/dev/null 2>&1 || true
! grep -qF '"Bash(subagent-log.sh:*)"' "$settings" || fail "remove sprint kept the subagent-log rule: $(cat "$settings")"
grep -qF '"Bash(brew install:*)"' "$settings" || fail "remove sprint dropped the install deny rules: $(cat "$settings")"

# An invalid file or a symlinked one: refused, nothing written.
printf '{"permissions": ' > "$settings"
for fn in offer_install_deny_rules offer_subagent_log_permission; do
  out="$(run 0 "$fn")"; assert_contains "$out" "not valid JSON"
done
assert_eq '{"permissions": ' "$(cat "$settings")"
printf '{"a": 1}' > "$tmp/elsewhere.json"; rm -f "$settings"; ln -s "$tmp/elsewhere.json" "$settings"
out="$(run 0 offer_install_deny_rules)"; assert_contains "$out" "symlink"
assert_eq '{"a": 1}' "$(cat "$tmp/elsewhere.json")"; [[ -L "$settings" ]] || fail "the settings symlink was replaced"
rm -f "$settings"

# No board binary yet, or an older one (it would take `settings` for a port and serve forever): a visible skip, never a hang.
printf '#!/bin/sh\n[ "$1" = --help ] && { echo "sprint-check-win — local kanban dashboard"; exit 0; }\nsleep 600\n' > "$tmp/old-board"
chmod +x "$tmp/old-board"
for b in "$tmp/no-such-board" "$tmp/old-board"; do
  for fn in offer_install_deny_rules offer_subagent_log_permission; do
    out="$(SPRINT_CHECK_BIN="$b" run 0 "$fn")"
    assert_contains "$out" "run canon update"
    [[ "$out" != *"[fail]"* && "$out" != *"[ok]"* ]] || fail "$fn with board $b went on past the skip: $out"
  done
  [[ ! -e "$settings" ]] || fail "settings.json written without a usable board ($b)"
done
# With no SPRINT_CHECK_BIN, the board is the install's own: tools/sprint-check-bin/sprint-check, or tools/sprint-check-win.exe on Windows.
assert_eq "$ROOT/tools/sprint-check-bin/sprint-check" "$(env -u SPRINT_CHECK_BIN bash -c 'source "$1/tools/platform-lib.sh"; _is_windows() { return 1; }; board_bin' _ "$ROOT")"
assert_eq "$ROOT/tools/sprint-check-win.exe" "$(env -u SPRINT_CHECK_BIN bash -c 'source "$1/tools/platform-lib.sh"; _is_windows() { return 0; }; board_bin' _ "$ROOT")"
no_trap_ran "invalid/symlink/no board"

# --- end to end with the traps first on PATH: skills add + refresh write the rules; the tkt/sprint flow runs ---------------
flow="$tmp/flow"; mkdir -p "$flow"; git -C "$flow" init -q; printf '# Agents\n' > "$flow/AGENTS.md"
fp() { SKILLS_SH_ASSUME_YES=1 HOME="$tmp/fhome" PATH="$traps:$ROOT/tools:$PATH" "$@"; }
mkdir -p "$tmp/fhome"
out="$(fp "$SKILLS" add sprint "$flow" 2>&1)" || fail "skills add sprint failed with no Python: $out"
grep -qF '"Bash(brew install:*)"' "$flow/.claude/settings.json" || fail "skills add sprint did not write the install deny rules: $out"
grep -qF '"Bash(subagent-log.sh:*)"' "$flow/.claude/settings.json" || fail "skills add sprint did not write the subagent-log rule: $out"
out="$(fp "$SKILLS" refresh "$flow" 2>&1)" || fail "skills refresh failed with no Python: $out"
( cd "$flow" && id="$(fp tkt create "flow check" 2>/dev/null | tail -1)" && [ -n "$id" ] && fp tkt start "$id" >/dev/null 2>&1 ) \
  || fail "tkt create/start failed with no Python"
flow2="$tmp/flow2"; mkdir -p "$flow2"; git -C "$flow2" init -q     # sprint start refuses while another ticket is active
( cd "$flow2" && fp sprint start "flow sprint" >/dev/null 2>&1 ) || fail "sprint start failed with no Python"
[ "$(ls "$flow/.tickets" | grep -c '^t-')" -ge 1 ] && [ "$(ls "$flow2/.tickets" | grep -c '^t-')" -ge 1 ] \
  || fail "tickets not created in the flow"
no_trap_ran "end to end"

printf 'windows-no-python: ok\n'
