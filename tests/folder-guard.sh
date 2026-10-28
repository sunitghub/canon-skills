#!/usr/bin/env bash
# t-b2ff: canon, tkt and sprint refuse to run in a folder that is not a project (a system folder or a drive root, each
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
# t-d0a5: the guard resolves a folder with cd, so a path this machine lacks can never be refused (/private/etc on Linux):
# such a system folder is checked only where it exists, and the ones left out are named at the end.
absent=()
check_dir() { if [[ -d "$1" ]]; then check "$@"; else absent+=("$1"); fi; }
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
check_dir /usr                          "$HOME_DIR" "a system folder"
check_dir /etc                          "$HOME_DIR" "a system folder"
check_dir /var                          "$HOME_DIR" "a system folder"
for d in /System /Applications /Library; do   # macOS folders: only where they exist (the bash check reads the real folder)
  [[ -d "$d" ]] && check "$d" "$HOME_DIR" "a system folder"
done
check_dir /private/etc                  "$HOME_DIR" "a system folder"       # macOS's physical /etc, reached without the /etc alias
check_dir /private/var                  "$HOME_DIR" "a system folder"
check /private/var/folders/x/T       "$HOME_DIR" ""
check_dir /bin                          "$HOME_DIR" "a system folder"
check_dir /sbin                         "$HOME_DIR" "a system folder"
check_dir /opt                          "$HOME_DIR" "a system folder"
check 'C:\Program Files\Foo'         "$HOME_DIR" ""
check 'C:\Windowsfoo'                 "$HOME_DIR" ""
check 'C:\Users\sam\proj'            "$HOME_DIR" ""
check /usr/local/src/p               "$HOME_DIR" ""                       # a subfolder of a unix system folder is fine
check "$HOME_DIR"                    "$HOME_DIR" ""                       # t-dec4: the home folder is a project like any other
check "$HOME_DIR/work"               "$HOME_DIR" ""
check "$W/plain"                     "$HOME_DIR" ""                       # a plain folder with no git is a supported project
check "$W/proj"                      "$HOME_DIR" ""
check "$W/gith"                      "$W/gith"   ""                       # a dotfiles repository in the home folder is a project
check "$W/tonly"                     "$W/tonly"  ""
check "$W/tonly"                     "$HOME_DIR" ""
check "$W/plain"                     ""          ""

# End to end, in a refused folder (a system folder: /etc, read-only here): each command says why, exits 1 and creates nothing. The home folder is
# NOT refused (t-dec4). Commands that could write run only when not root, under a timeout, so a regression cannot fill or hang a real folder.
REFUSED=/etc; export HOME="$HOME_DIR"
if [[ -d "$REFUSED" && ! -e "$REFUSED/.tickets" ]]; then
  refused() { # <label> <command...>: run in $REFUSED
    local label="$1"; shift
    local out rc=0
    out="$(cd "$REFUSED" && timeout 20 "$@" 2>&1)" || rc=$?
    [[ "$rc" == 1 ]] || fail "folder-guard: $label exited $rc in $REFUSED, want 1: $out"
    [[ "$out" == *"is not a project (a system folder with no git repository)"* ]] || fail "folder-guard: $label gave no reason: $out"
    [[ ! -e "$REFUSED/.tickets" ]] || { rm -f "$REFUSED/.tickets" 2>/dev/null; fail "folder-guard: $label created $REFUSED/.tickets"; }
  }
  refused "tkt ls"        "$TKT" ls
  if [[ "$(id -u)" != 0 ]]; then
    refused "tkt create"    "$TKT" create "x"
    refused "tkt start"     "$TKT" start t-aaaa
    refused "sprint start"  "$SPRINT" start t-aaaa
    refused "canon"         bash "$TOOLS_DIR/canon"
  fi
  # ... but the help and version of each still answer there.
  for c in "$TKT --help" "$SPRINT help" "bash $TOOLS_DIR/canon --help" "bash $TOOLS_DIR/canon version"; do
    (cd "$REFUSED" && $c >/dev/null 2>&1) || fail "folder-guard: '$c' failed in $REFUSED"
  done
  # The subcommands that are not "start the Cockpit" are not blocked there: canon update (run from System32 by a Windows admin), stop, status.
  out="$(cd "$REFUSED" && bash "$TOOLS_DIR/canon" update bogus 2>&1)" && fail "folder-guard: canon update bogus should refuse its own argument"
  [[ "$out" == *"takes no arguments"* && "$out" != *"is not a project"* ]] || fail "folder-guard: canon update was blocked by the folder guard: $out"
  out="$(cd "$REFUSED" && CANON_COCKPIT_PORT=58999 bash "$TOOLS_DIR/canon" stop 2>&1)" || fail "folder-guard: canon stop failed in $REFUSED: $out"
  [[ "$out" != *"is not a project"* ]] || fail "folder-guard: canon stop was blocked by the folder guard: $out"
fi

# The board binary refuses too, before it listens (the launchers all end here).
BOARD="$(build_board "$W/bin")"
out="$(cd "$W/plain" && SPRINT_CHECK_NO_BROWSER=1 SPRINT_CHECK_ROOT=/etc timeout 20 "$BOARD" 8457 2>&1)" && fail "folder-guard: SPRINT_CHECK_ROOT=/etc started the board"
[[ "$out" == *"is not a project (a system folder with no git repository)"*"mkdir -p"* ]] || fail "folder-guard: SPRINT_CHECK_ROOT=/etc gave no reason: $out"

# Allowed folders work as before: a plain folder, a git repository and a folder with only .tickets.
for d in "$W/plain" "$W/proj" "$W/tonly"; do
  (cd "$d" && "$TKT" ls >/dev/null 2>&1) || fail "folder-guard: tkt ls failed in $d"
done
(cd "$W/plain" && "$TKT" create "still works" >/dev/null) || fail "folder-guard: tkt create failed in a plain folder"

# t-5738/t-dec4: the home folder is a project like any other when canon starts IN it, and a folder under home never adopts home's .tickets.
STRAY="$W/stray"; mkdir -p "$STRAY/Documents/app" "$STRAY/repo" "$STRAY/.tickets/t-aaaa"; git -C "$STRAY/repo" init -q
printf -- '---\nid: t-aaaa\nstatus: open\n---\n# old\n' > "$STRAY/.tickets/t-aaaa/ticket.md"
export HOME="$STRAY"
resolves() { # <label> <folder> <want project folder>: the project folder tickets_dir picks from <folder>
  local got; got="$(cd "$2" && bash -c 'source "$1/tools/ticket-root.sh"; tickets_dir' _ "$ROOT")"
  [[ "$(cd "$(dirname "$got")" && pwd -P)" == "$(cd "$3" && pwd -P)" ]] || fail "folder-guard: $1: tickets_dir from $2 gave $got, want a project at $3"
}
resolves "a folder under home"            "$STRAY/Documents/app" "$STRAY/Documents/app"
resolves "a repository under home"        "$STRAY/repo"          "$STRAY/repo"
resolves "the home folder itself"         "$STRAY"               "$STRAY"
(cd "$STRAY/Documents/app" && "$TKT" create "from under home" >/dev/null 2>&1) || fail "folder-guard: tkt create failed under a home folder that has a .tickets"
[[ -n "$(ls "$STRAY/Documents/app/.tickets" 2>/dev/null)" && "$(ls "$STRAY/.tickets")" == "t-aaaa" ]] || fail "folder-guard: the ticket went to home's .tickets instead of the project folder"
# started in home: it works, on home's own .tickets, and sees the ticket that is there
out="$(cd "$STRAY" && "$TKT" ls 2>&1)" || fail "folder-guard: tkt ls failed in the home folder: $out"
[[ "$out" == *"t-aaaa"* && "$out" != *"is not a project"* ]] || fail "folder-guard: the home folder did not use its own .tickets: $out"
(cd "$STRAY" && "$TKT" create "made in home" >/dev/null 2>&1) || fail "folder-guard: tkt create failed in the home folder"
[[ "$(ls "$STRAY/.tickets" | wc -l | tr -d ' ')" == 2 ]] || fail "folder-guard: a ticket made in the home folder did not land in its .tickets"
# started in home, home wins even when a folder ABOVE home has a .tickets of its own (the exception that keeps home a project)
HP="$W/hp"; mkdir -p "$HP/.tickets" "$HP/home/.tickets" "$HP/home/sub"
(export HOME="$HP/home"; resolves "home with a .tickets above it" "$HP/home" "$HP/home"; resolves "a folder under home, a .tickets above home" "$HP/home/sub" "$HP/home/sub")
# started in home with NO .tickets of its own, a .tickets above home is not adopted (home is the project); and a dotfiles .git in home does not take over the folders under it
HQ="$W/hq"; mkdir -p "$HQ/.tickets" "$HQ/home/sub" "$HQ/home/.git"
(export HOME="$HQ/home"; resolves "started in home, a .tickets above and none in home" "$HQ/home" "$HQ/home"; resolves "a folder under a home that is a dotfiles repository" "$HQ/home/sub" "$HQ/home/sub")
# started in home with NO .git and NO .tickets of its own and a .tickets above home: home is the project (nothing above it is adopted). The earlier
# fixtures all gave home a .git or a .tickets, which masked this (t-dec4 evaluator).
HN="$W/hn"; mkdir -p "$HN/.tickets" "$HN/home/sub"
(export HOME="$HN/home"; resolves "started in a bare home, a .tickets above it" "$HN/home" "$HN/home"; resolves "under a bare home, a .tickets above it" "$HN/home/sub" "$HN/home/sub")
# HOME reached through a symlink: a folder under it resolves to itself from either spelling, and the symlinked home is its own project
HL="$W/hl"; mkdir -p "$HL/real/app" "$HL/real/.tickets"; ln -s "$HL/real" "$HL/link"
(export HOME="$HL/link"; resolves "a folder under a symlinked HOME, via the real path" "$HL/real/app" "$HL/real/app"; resolves "a folder under a symlinked HOME, via the link" "$HL/link/app" "$HL/real/app"; resolves "a symlinked HOME itself" "$HL/link" "$HL/real")
# a refused folder's text quotes a HOME with a space in the example
if [[ -d "$REFUSED" ]]; then
  SP="$W/with space"; mkdir -p "$SP"; out="$(cd "$REFUSED" && HOME="$SP" "$TKT" ls 2>&1)" && fail "folder-guard: tkt ls ran in $REFUSED"
  [[ "$out" == *"mkdir -p \"$SP/projects/demo\""* ]] || fail "folder-guard: the example folder is not quoted for a HOME with a space: $out"
  # t-dec4: on Windows (Git Bash under PowerShell) the same refusal shows C:\Windows\System32 and an example command PowerShell accepts; the sentence is the
  # one internal/common's TestNotAProjectMessage pins. cygpath is stubbed (this fixture's home becomes C:\Users\agentops, /etc becomes C:\Windows\System32),
  # uname by CANON_HOST_OS.
  STRAY_P="$(cd "$STRAY" && pwd -P)"; mkdir -p "$W/winbin"
  cat > "$W/winbin/cygpath" <<STUB
#!/usr/bin/env bash
[ "\$1" = -w ] && shift
p="\$1"
case "\$p" in
  /etc|/private/etc) p="C:/Windows/System32" ;;
  "$STRAY_P"*|"$STRAY"*) p="\${p#$STRAY_P}"; p="C:/Users/agentops\${p#$STRAY}" ;;
esac
printf '%s\\n' "\$p" | sed 's#/#\\\\#g'
STUB
  chmod +x "$W/winbin/cygpath"
  out="$(cd "$REFUSED" && PATH="$W/winbin:$PATH" CANON_HOST_OS=MINGW64_NT-10.0 "$TKT" ls 2>&1)" && fail "folder-guard: tkt ls ran in $REFUSED (windows form case)"
  want='tkt: C:\Windows\System32 is not a project (a system folder with no git repository). Make a folder for your work, for example: mkdir "C:\Users\agentops\projects\demo", cd into it, run git init, then run tkt again.'
  assert_eq "$want" "$out"
fi

# the board starts there (this checks only its start guard; its project finder is covered by TestFindProjectRootSkipsAStrayHomeTickets, the daemon's by TestTicketsDirInSkipsAStrayHomeTickets)
out="$(cd "$STRAY/Documents/app" && SPRINT_CHECK_NO_BROWSER=1 timeout 8 "$BOARD" 8458 2>&1 || true)"
[[ "$out" != *"is not a project"* ]] || fail "folder-guard: the board refused a folder under a home that has a stray .tickets: $out"

# Both installers end by saying where to go next, with the home path (a first-time user has no project folder yet)
grep -q 'Next: open a terminal in your project folder (for example %s/projects/demo' "$ROOT/install.sh" || fail "folder-guard: install.sh does not print the next step"
# install.ps1 has two endings: the bootstrap one (irm ... | iex, canon update: the first-run path) and the file one; both must say it
[[ "$(grep -v '^[[:space:]]*#' "$ROOT/install.ps1" | grep -c 'Next: open a terminal in your project folder (for example \$HOME\\projects\\demo')" == 2 ]] || fail "folder-guard: install.ps1 must print the next step in both its bootstrap and its file ending"
awk '/^[[:space:]]*#/{next} /^if [(][$]Bootstrap[)] [{]/{b=1; f=0} b&&/Next: open a terminal/{f=1} b&&/canon installed successfully/{ok=f} b&&/^  return/{b=0} END{exit !ok}' "$ROOT/install.ps1" || fail "folder-guard: the bootstrap ending of install.ps1 does not print the next step before it returns"

[[ ${#absent[@]} -eq 0 ]] || echo "folder-guard: not on this machine, so not checked: ${absent[*]}"
echo "folder-guard: ok"
