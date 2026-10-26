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
for d in /System /Applications /Library; do   # macOS folders: only where they exist (the bash check reads the real folder)
  [[ -d "$d" ]] && check "$d" "$HOME_DIR" "a system folder"
done
check /private/etc                   "$HOME_DIR" "a system folder"       # macOS's physical /etc, reached without the /etc alias
check /private/var                   "$HOME_DIR" "a system folder"
check /private/var/folders/x/T       "$HOME_DIR" ""
check /bin                           "$HOME_DIR" "a system folder"
check /sbin                          "$HOME_DIR" "a system folder"
check /opt                           "$HOME_DIR" "a system folder"
check 'C:\Program Files\Foo'         "$HOME_DIR" ""
check 'C:\Windowsfoo'                 "$HOME_DIR" ""
check 'C:\Users\sam\proj'            "$HOME_DIR" ""
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

# The subcommands that are not "start the Cockpit" are not blocked there: canon update (run from System32 by a Windows admin), stop, status.
out="$(cd "$HOME_DIR" && bash "$TOOLS_DIR/canon" update bogus 2>&1)" && fail "folder-guard: canon update bogus should refuse its own argument"
[[ "$out" == *"takes no arguments"* && "$out" != *"is not a project"* ]] || fail "folder-guard: canon update was blocked by the folder guard: $out"
out="$(cd "$HOME_DIR" && CANON_COCKPIT_PORT=58999 bash "$TOOLS_DIR/canon" stop 2>&1)" || fail "folder-guard: canon stop failed in the home folder: $out"
[[ "$out" != *"is not a project"* ]] || fail "folder-guard: canon stop was blocked by the folder guard: $out"

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

# t-5738: a stray .tickets in the home folder (an earlier canon run) must not become the project of every folder under home.
STRAY="$W/stray"; mkdir -p "$STRAY/Documents/app" "$STRAY/repo" "$STRAY/.tickets"; git -C "$STRAY/repo" init -q
export HOME="$STRAY"
resolves() { # <label> <folder>: the project folder tickets_dir picks from <folder> is <folder> itself, never the stray home
  local got; got="$(cd "$2" && bash -c 'source "$1/tools/ticket-root.sh"; tickets_dir' _ "$ROOT")"
  [[ "$(cd "$(dirname "$got")" && pwd -P)" == "$(cd "$2" && pwd -P)" ]] || fail "folder-guard: $1: tickets_dir from $2 gave $got"
}
resolves "a folder under home"            "$STRAY/Documents/app"
resolves "a repository under home"        "$STRAY/repo"
(cd "$STRAY/Documents/app" && "$TKT" create "from under home" >/dev/null 2>&1) || fail "folder-guard: tkt create failed under a home folder that has a stray .tickets"
[[ -n "$(ls "$STRAY/Documents/app/.tickets" 2>/dev/null)" && -z "$(ls "$STRAY/.tickets")" ]] || fail "folder-guard: the ticket went to the stray home .tickets instead of the project folder"
# from the home folder itself it is still refused; with no tickets in the stray folder the text gives only the folder hint, with a ticket it adds the move hint
out="$(cd "$STRAY" && "$TKT" ls 2>&1)" && fail "folder-guard: tkt ls ran in the home folder"
[[ "$out" == *"is not a project (your home folder"*"for example: mkdir -p \"$STRAY/projects/demo\""* && "$out" != *"left by an earlier run"* ]] || fail "folder-guard: the home refusal has no example folder, or names tickets that are not there: $out"
mkdir -p "$STRAY/.tickets/t-aaaa"; printf -- '---\nid: t-aaaa\nstatus: open\n---\n# old\n' > "$STRAY/.tickets/t-aaaa/ticket.md"
before="$(cd "$STRAY/.tickets" && find . -type f | LC_ALL=C sort | xargs shasum | shasum)"
out="$(cd "$STRAY" && "$TKT" ls 2>&1)" && fail "folder-guard: tkt ls ran in the home folder with tickets in it"
[[ "$out" == *"left by an earlier run"*"mv "* ]] || fail "folder-guard: no move hint for a home folder that holds tickets: $out"
[[ "$before" == "$(cd "$STRAY/.tickets" && find . -type f | LC_ALL=C sort | xargs shasum | shasum)" ]] || fail "folder-guard: refusing the home folder changed its .tickets"
# a HOME with a space is quoted in the example
SP="$W/with space"; mkdir -p "$SP"; out="$(cd "$SP" && HOME="$SP" "$TKT" ls 2>&1)" && fail "folder-guard: tkt ls ran in a home folder with a space"
[[ "$out" == *"mkdir -p \"$SP/projects/demo\""* ]] || fail "folder-guard: the example folder is not quoted for a HOME with a space: $out"
# t-dec4: on Windows (Git Bash under PowerShell) the same refusal shows the folder as C:\Users\x and an example command PowerShell accepts; the sentence
# is the one internal/common's TestNotAProjectMessage pins. cygpath is stubbed (it maps this fixture's home to C:\Users\agentops), uname by CANON_HOST_OS.
STRAY_P="$(cd "$STRAY" && pwd -P)"; mkdir -p "$W/winbin"
cat > "$W/winbin/cygpath" <<STUB
#!/usr/bin/env bash
[ "\$1" = -w ] && shift
p="\$1"; for pre in "$STRAY_P" "$STRAY"; do case "\$p" in "\$pre"*) p="C:/Users/agentops\${p#\$pre}" ;; esac; done
printf '%s\\n' "\$p" | sed 's#/#\\\\#g'
STUB
chmod +x "$W/winbin/cygpath"
out="$(cd "$STRAY" && PATH="$W/winbin:$PATH" CANON_HOST_OS=MINGW64_NT-10.0 "$TKT" ls 2>&1)" && fail "folder-guard: tkt ls ran in the home folder (windows form case)"
want1='tkt: C:\Users\agentops is not a project (your home folder with no git repository). Make a folder for your work, for example: mkdir "C:\Users\agentops\projects\demo", cd into it, run git init, then run tkt again.'
want2='tkt: C:\Users\agentops has a .tickets folder with tickets in it, left by an earlier run. If they belong to a project, move the folder into it (nothing here moves it for you), for a project that has no .tickets yet: move "C:\Users\agentops\.tickets" "C:\Users\agentops\projects\demo\.tickets"'
assert_eq "$want1"$'\n'"$want2" "$out"
[[ "$out" != *"mkdir -p"* && "$out" != *"/c/"* ]] || fail "folder-guard: the Windows refusal still has a Git Bash form: $out"

# the board starts there (this checks only its start guard; its project finder is covered by TestFindProjectRootSkipsAStrayHomeTickets, the daemon's by TestTicketsDirInSkipsAStrayHomeTickets)
out="$(cd "$STRAY/Documents/app" && SPRINT_CHECK_NO_BROWSER=1 timeout 8 "$BOARD" 8458 2>&1 || true)"
[[ "$out" != *"is not a project"* ]] || fail "folder-guard: the board refused a folder under a home that has a stray .tickets: $out"

# Both installers end by saying where to go next, with the home path (a first-time user has no project folder, and canon refuses home)
grep -q 'Next: open a terminal in your project folder (for example %s/projects/demo' "$ROOT/install.sh" || fail "folder-guard: install.sh does not print the next step"
# install.ps1 has two endings: the bootstrap one (irm ... | iex, canon update: the first-run path) and the file one; both must say it
[[ "$(grep -v '^[[:space:]]*#' "$ROOT/install.ps1" | grep -c 'Next: open a terminal in your project folder (for example \$HOME\\projects\\demo')" == 2 ]] || fail "folder-guard: install.ps1 must print the next step in both its bootstrap and its file ending"
awk '/^[[:space:]]*#/{next} /^if [(][$]Bootstrap[)] [{]/{b=1; f=0} b&&/Next: open a terminal/{f=1} b&&/canon installed successfully/{ok=f} b&&/^  return/{b=0} END{exit !ok}' "$ROOT/install.ps1" || fail "folder-guard: the bootstrap ending of install.ps1 does not print the next step before it returns"

echo "folder-guard: ok"
