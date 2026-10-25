#!/usr/bin/env bash
# t-b2ff: canon, tkt and sprint refuse to run in a folder that is not a project (a system folder, a drive root, the home folder, each
# with no .git), print why and exit 1, and create nothing. The same corpus runs through the bash table (tools/ticket-root.sh) here and
# through the Go table (internal/common TestNotAProject). Protects the commands every user runs and the board's start (an
# Administrator PowerShell opens in C:\Windows\System32).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$W/xdg" LC_ALL=C
unset CANON_TICKETS_DIR
HOME_DIR="$W/home"; mkdir -p "$HOME_DIR" "$W/plain" "$W/proj" "$W/tonly/.tickets" "$W/gith" "$HOME_DIR/work"
git -C "$W/proj" init -q; git -C "$W/gith" init -q
source "$ROOT/tools/ticket-root.sh"

why() { ( HOME="$2"; folder_guard_reason "$1" ); }   # <dir> <home>

# The corpus (one line per case): <dir> <home> -> reason or empty. Same kinds as the Go test.
check() { assert_eq "$3" "$(why "$1" "$2")"; }
check /                              "$HOME_DIR" "the root of a drive"
check 'C:\'                          "$HOME_DIR" "the root of a drive"
check 'c:'                           "$HOME_DIR" "the root of a drive"
check 'C:\Windows\System32'          "$HOME_DIR" "a system folder"
check 'c:/WINDOWS/system32'          "$HOME_DIR" "a system folder"
check 'C:\Windows'                   "$HOME_DIR" "a system folder"
check 'C:\Windows\System32\drivers'  "$HOME_DIR" "a system folder"
check 'C:\Program Files'             "$HOME_DIR" "a system folder"
check 'C:\Program Files (x86)'       "$HOME_DIR" "a system folder"
check 'D:\ProgramData'               "$HOME_DIR" "a system folder"
check /usr                           "$HOME_DIR" "a system folder"
check /etc                           "$HOME_DIR" "a system folder"
check /var                           "$HOME_DIR" "a system folder"
check /usr/local/src/p               "$HOME_DIR" ""                       # a subfolder of a unix system folder is fine
check "$HOME_DIR"                    "$HOME_DIR" "your home folder"
check "$HOME_DIR/work"               "$HOME_DIR" ""
check "$W/plain"                     "$HOME_DIR" ""                       # a plain folder with no git is a supported project
check "$W/proj"                      "$HOME_DIR" ""
check "$W/gith"                      "$W/gith"   ""                       # a dotfiles repository in the home folder is a project
check "$W/tonly"                     "$W/tonly"  "your home folder"       # .tickets alone never rescues it
check "$W/tonly"                     "$HOME_DIR" ""
check "$W/plain"                     ""          ""

# End to end, in a refused folder (the home folder, HOME pinned to it): each command says why, exits 1 and creates nothing.
export HOME="$HOME_DIR"
refused() { # <label> <command...>: run in $HOME_DIR
  local label="$1"; shift
  local out rc=0
  out="$(cd "$HOME_DIR" && "$@" 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "folder-guard: $label exited $rc in the home folder, want 1: $out"
  [[ "$out" == *"is not a project (your home folder with no git repository)"* ]] || fail "folder-guard: $label gave no reason: $out"
  [[ -z "$(find "$HOME_DIR" -mindepth 1 -maxdepth 1 ! -name work)" ]] || fail "folder-guard: $label created something in the home folder: $(ls -A "$HOME_DIR")"
}
refused "tkt ls"        "$TKT" ls
refused "tkt create"    "$TKT" create "x"
refused "tkt start"     "$TKT" start t-aaaa
refused "sprint start"  "$SPRINT" start t-aaaa
refused "canon"         bash "$TOOLS_DIR/canon"
# ... but the help and version of each still answer there.
for c in "$TKT --help" "$SPRINT help" "bash $TOOLS_DIR/canon --help" "bash $TOOLS_DIR/canon version"; do
  (cd "$HOME_DIR" && $c >/dev/null 2>&1) || fail "folder-guard: '$c' failed in the home folder"
done

# The board binary refuses too, before it listens (the launchers all end here).
BOARD="$(build_board "$W/bin")"
out="$(cd "$HOME_DIR" && SPRINT_CHECK_NO_BROWSER=1 timeout 20 "$BOARD" 8456 2>&1)" && fail "folder-guard: the board started in the home folder"
[[ "$out" == *"is not a project (your home folder with no git repository)"* ]] || fail "folder-guard: the board gave no reason: $out"
out="$(cd "$W/plain" && SPRINT_CHECK_NO_BROWSER=1 SPRINT_CHECK_ROOT="$HOME_DIR" timeout 20 "$BOARD" 8457 2>&1)" && fail "folder-guard: SPRINT_CHECK_ROOT=<home> started the board"
[[ "$out" == *"your home folder"* ]] || fail "folder-guard: SPRINT_CHECK_ROOT=<home> gave no reason: $out"

# Allowed folders work as before: a plain folder, a git repository and a folder with only .tickets.
for d in "$W/plain" "$W/proj" "$W/tonly"; do
  (cd "$d" && "$TKT" ls >/dev/null 2>&1) || fail "folder-guard: tkt ls failed in $d"
done
(cd "$W/plain" && "$TKT" create "still works" >/dev/null) || fail "folder-guard: tkt create failed in a plain folder"

echo "folder-guard: ok"
