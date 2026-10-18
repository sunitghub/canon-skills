#!/usr/bin/env bash
# evidence (t-e3cd) — tools/evidence.sh writes builder evidence that names the commit that was tested (`stamp`) and tells a gate whether a
# log is still good for a given head (`check`). `check` reads files an agent wrote, so the hostile shapes and a random loop are here.
# Everything runs in a throwaway git repo; nothing touches the real tree or the real .tickets.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
EV="$ROOT/tools/evidence.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg" LC_ALL=C
unset CANON_TICKETS_DIR   # a stamp taken for the whole suite sets it (plain-clone workflow); every call here must use the throwaway repo's own .tickets/
REPO="$WORK/repo"; ID=t-abcd
mkdir -p "$REPO" && cd "$REPO"
git init -q -b main . && git config user.name t && git config user.email t@t
mkdir -p ".tickets/$ID" src; echo a > src/a.txt; echo m > src/b.txt; echo '# t' > ".tickets/$ID/ticket.md"
git add src && git add -f ".tickets/$ID/ticket.md" && git commit -qm base
C1="$(git rev-parse HEAD)"
ED="$REPO/.tickets/$ID/evidence"

ev() { set +e; out="$(cd "$REPO" && bash "$EV" "$@" 2>&1)"; code=$?; set -e; }
reset_repo() { git reset -q --hard "$C1"; git clean -fdq -e .tickets; rm -rf "$ED"; }
stamp_re='^HEAD [0-9a-f]{40} [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$'

# --- stamp: the file it writes ---------------------------------------------------------------------------------------------------
reset_repo
ev stamp "$ID" suite -- bash -c 'echo one; echo two'; assert_eq 0 "$code"
f="$ED/suite.log"; assert_file_exists "$f"
[[ "$(sed -n 1p "$f")" =~ $stamp_re ]] || fail "evidence: line 1 is not the documented stamp: $(sed -n 1p "$f")"
assert_eq "HEAD $C1" "$(sed -n 1p "$f" | cut -d' ' -f1-2)"
assert_eq '$ bash -c echo\ one\;\ echo\ two' "$(sed -n 2p "$f")"                     # %q keeps the quoting
ev stamp "$ID" q1 -- bash -c 'echo a b'; ev stamp "$ID" q2 -- bash -c echo a b
[[ "$(sed -n 2p "$ED/q1.log")" != "$(sed -n 2p "$ED/q2.log")" ]] || fail "evidence: two commands that differ only in quoting gave the same command line"
os_line="# on $(uname -srm); bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}"   # t-a83a: the stamp's bash is this one (`bash "$EV"`)
assert_eq "$os_line" "$(sed -n 3p "$f")"; assert_count 0 "$(hostname)" "$f"
assert_eq "one two exit 0" "$(sed -n '4,$p' "$f" | tr '\n' ' ' | sed 's/ $//')"
ev stamp "$ID" suite -- bash -c 'echo failing; exit 7'; assert_eq 7 "$code"                      # the command's own code comes back and is written
assert_eq "exit 7" "$(tail -n1 "$f")"; assert_count 0 "exit 0" "$f"                                 # a re-stamp replaces the log
ev stamp "$ID" noeol -- bash -c 'printf "no newline"'; assert_eq 0 "$code"
assert_eq "no newline|exit 0" "$(tail -n2 "$ED/noeol.log" | tr '\n' '|' | sed 's/|$//')"           # our exit line starts on its own line
# output that imitates our lines cannot forge the last line, and line 1 is ours
ev stamp "$ID" forge -- bash -c 'echo "HEAD 0000000000000000000000000000000000000000 2020-01-01T00:00:00Z"; echo "exit 0"; exit 5'; assert_eq 5 "$code"
assert_eq "exit 5" "$(tail -n1 "$ED/forge.log")"; assert_eq "HEAD $C1" "$(sed -n 1p "$ED/forge.log" | cut -d' ' -f1-2)"
ev check "$ID" "$C1"; assert_contains "$out" "exit=5"
# t-a83a: check shows the stamp's OS before cmd:, on fresh and stale lines alike
os_txt=" on: $(uname -srm), bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}"; os_shown="$os_txt cmd: bash -c"
ev check "$ID" "$C1"; assert_contains "$out" "fresh forge.log exit=5 (HEAD ${C1:0:7} = graded, "; assert_contains "$out" ")$os_shown"
git commit -q --allow-empty -m later; echo b >> src/a.txt; git commit -qam moved
ev check "$ID"; assert_contains "$out" "stale forge.log exit=5 (HEAD ${C1:0:7}; 1 tracked file(s) changed since: src/a.txt)$os_shown"
git reset -q --hard "$C1"
# untracked files and .tickets changes do not make the tree dirty
reset_repo; echo scratch > untracked.txt; echo more >> ".tickets/$ID/ticket.md"
ev stamp "$ID" ok -- true; assert_eq 0 "$code"; git checkout -q -- ".tickets/$ID/ticket.md"

# --- stamp: every refusal runs nothing and writes nothing ------------------------------------------------------------------------
snap() { { find "$REPO" -path "$REPO/.git" -prune -o -type f -print | LC_ALL=C sort | xargs cksum; ls -A "$ED" 2>/dev/null || true; } | cksum; }
refused() {   # refused <label> <expected exit> <message part> <stamp args...>
  local label="$1" want="$2" msg="$3" before; shift 3
  rm -f "$WORK/ran"; before="$(snap)"
  ev stamp "$@" -- bash -c 'touch "$0"' "$WORK/ran"
  assert_eq "$want" "$code"; assert_contains "$out" "$msg"
  [[ ! -e "$WORK/ran" ]] || fail "evidence: the command ran although $label was refused"
  assert_eq "$before" "$(snap)"
}
reset_repo; echo dirty >> src/a.txt
refused "a modified tracked file" 125 "commit first" "$ID" x
git checkout -q -- src/a.txt; echo staged >> src/a.txt; git add src/a.txt
refused "a staged change" 125 "commit first" "$ID" x
git reset -q --hard "$C1"
refused "a ticket id with capitals" 2 "usage" "T-ABCD" x
refused "a short ticket id" 2 "usage" "t-abc" x
refused "a path as ticket id" 2 "usage" "../t-abcd" x
refused "a ticket with no folder" 2 "no ticket folder" "t-ffff" x
for bad in A .hid "a b" "../x" "x/y" "-x" ""; do refused "name '$bad'" 2 "usage" "$ID" "$bad"; done
ev stamp "$ID" x --; assert_eq 2 "$code"; ev stamp "$ID" x; assert_eq 2 "$code"; ev stamp "$ID" -- true; assert_eq 2 "$code"
ev bogus "$ID"; assert_eq 2 "$code"; ev; assert_eq 2 "$code"
set +e; out="$(cd "$WORK" && bash "$EV" stamp "$ID" x -- true 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "git repository"
# the tree changes, or HEAD moves, while the command runs: the stamp would name a tree that was not tested
before="$(snap)"; rm -f "$WORK/ran"
ev stamp "$ID" racy -- bash -c 'echo x >> src/a.txt'; assert_eq 125 "$code"; assert_contains "$out" "changed while the command ran"
[[ ! -e "$ED/racy.log" ]] || fail "evidence: wrote a stamp for a command that modified a tracked file"
git checkout -q -- src/a.txt
ev stamp "$ID" moved -- git commit -q --allow-empty -m moved; assert_eq 125 "$code"
[[ ! -e "$ED/moved.log" ]] || fail "evidence: wrote a stamp for a command that moved HEAD"
git reset -q --hard "$C1"
ls -A "$ED" 2>/dev/null | grep -q '^\.stamp\.' && fail "evidence: left a temp file behind" || true
# symlinks: never write through one
mkdir -p "$WORK/outside"; echo keep > "$WORK/outside/x.log"; rm -rf "$ED"
if ln -s "$WORK/outside" "$ED" 2>/dev/null && [[ -L "$ED" ]]; then
  refused "a symlinked evidence dir" 125 "symlink" "$ID" x
  rm -f "$ED"; mkdir -p "$ED"; ln -s "$WORK/outside/x.log" "$ED/x.log"
  refused "a symlinked log" 125 "symlink" "$ID" x
  assert_eq keep "$(cat "$WORK/outside/x.log")"
  rm -f "$ED/x.log"
else
  echo "evidence: SKIPPED the symlink cases (this system cannot create symlinks)"
fi
reset_repo

# a stamp taken in a plain clone lands in the project's ticket folder (CANON_TICKETS_DIR) and names the clone's own HEAD
reset_repo
CLONE="$WORK/clone"; git clone -q "$REPO" "$CLONE" && ( cd "$CLONE" && git checkout -q "$C1" )
set +e; out="$(cd "$CLONE" && CANON_TICKETS_DIR="$REPO/.tickets" bash "$EV" stamp "$ID" fromclone -- true 2>&1)"; code=$?; set -e
assert_eq 0 "$code"; assert_file_exists "$ED/fromclone.log"; assert_eq "HEAD $C1" "$(sed -n 1p "$ED/fromclone.log" | cut -d' ' -f1-2)"
[[ ! -e "$CLONE/.tickets/$ID/evidence" ]] || fail "evidence: the clone's own .tickets/ was used although CANON_TICKETS_DIR was set"
ev check "$ID"; assert_contains "$out" "fresh fromclone.log exit=0"
set +e; out="$(cd "$CLONE" && CANON_TICKETS_DIR="$WORK/nope" bash "$EV" stamp "$ID" x -- true 2>&1)"; code=$?; set -e
assert_eq 2 "$code"; assert_contains "$out" "no ticket folder"
set +e; out="$(cd "$CLONE" && bash "$EV" stamp "$ID" own -- true 2>&1)"; code=$?; set -e
assert_eq 0 "$code"; assert_file_exists "$CLONE/.tickets/$ID/evidence/own.log"                   # without the variable the clone's own .tickets/ is used
rm -rf "$ED"

# --- check -----------------------------------------------------------------------------------------------------------------------
put() { mkdir -p "$ED"; printf '%b' "$2" > "$ED/$1"; }
checks() {   # checks <expected output> [args]: runs `check` and compares the whole output
  local want="$1"; shift; ev check "$ID" "$@"; assert_eq 0 "$code"; assert_eq "$want" "$out"
}
first_word() { printf '%s' "$out" | awk '{print $1}'; }
T="2026-10-09T10:00:00Z"
reset_repo
put same.log "HEAD $C1 $T\n\$ bash tests/x.sh\nok\nexit 0\n"
ev check "$ID"; assert_eq 0 "$code"; assert_eq fresh "$(first_word)"
assert_contains "$out" "exit=0"; assert_contains "$out" "cmd: bash tests/x.sh"; assert_contains "$out" "HEAD ${C1:0:7} = graded"
[[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" == 1 ]] || fail "evidence: one file must give one line: $out"
assert_eq "fresh same.log exit=0 (HEAD ${C1:0:7} = graded, $T) cmd: bash tests/x.sh" "$out"   # t-a83a: a log without `# on` reads as before
rm -rf "$ED"
# t-a83a: a hostile line 3 gives one clean line: control bytes, an ANSI escape, CRLF, 10 KB, binary
long="$(head -c 10000 /dev/zero | tr '\0' A)"
for l3 in '# on Linux\x1b[31m 6.8\x07; bash 5' '# on Linux 6.8 x86_64; bash 5.2.0\r' "# on $long" '# on \x00\x01\xff\xc2\x9b; bash' '# on ' '# onion'; do
  put h.log "HEAD $C1 $T\n\$ true\n$l3\nexit 0\n"; ev check "$ID"; assert_eq 0 "$code"
  [[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" == 1 && "$out" =~ ^fresh\ h\.log\ exit=0\ \( ]] || fail "evidence: hostile line 3 broke the line: $out"
  [[ "$out" != *[^A-Za-z0-9._\ /=:+,\\?\(\)-]* ]] || fail "evidence: hostile line 3 leaked a byte: $(printf '%q' "$out")"
  [[ ${#out} -lt 260 ]] || fail "evidence: line 3 was not capped: ${#out} chars"
done
for l3 in '# on ' '# on    '; do   # review: an empty OS shows nothing, as in import-results
  put h.log "HEAD $C1 $T\n\$ true\n$l3\nexit 0\n"; ev check "$ID"; [[ "$out" != *" on: "* ]] || fail "evidence: an empty # on line was shown: $out"
done
longcmd="$(head -c 3000 /dev/zero | tr '\0' y)"   # review: line 3 is read past a long line 2 (same bound as line2_of)
put h.log "HEAD $C1 $T\n\$ $longcmd\n# on Linux 6.8 x86_64; bash 5.2.37\nexit 0\n"; ev check "$ID"; assert_contains "$out" " on: Linux 6.8 x86_64, bash 5.2.37 cmd: yyy"
put h.log "HEAD $C1 $T\n\$ true\n# onion\nexit 0\n"; ev check "$ID"; [[ "$out" != *" on: "* ]] || fail "evidence: a line 3 not starting \`# on \` was shown: $out"
put h.log "HEAD $C1 $T\n\$ true\n# on Linux 6.8 x86_64; bash 5.2.0\r\nexit 0\n"; ev check "$ID"
assert_contains "$out" ") on: Linux 6.8 x86_64, bash 5.2.0 cmd: true"
rm -rf "$ED"
# abbreviated sha and CRLF are fine; text after the time is not (the tool never writes any)
put abbr.log "HEAD ${C1:0:7} $T\n"; ev check "$ID"; assert_eq fresh "$(first_word)"
put tail.log "HEAD $C1 2026-10-09 07:22:47  release-manifest -> ok\n"; ev check "$ID"; assert_contains "$out" "unstamped tail.log"
put tail2.log "HEAD $C1 $T +wt dirty tree\nexit 0\n"; ev check "$ID"; assert_contains "$out" "unstamped tail2.log"
put tail3.log "HEAD $C1 $T uncommitted\nexit 0\n"; ev check "$ID"; assert_contains "$out" "unstamped tail3.log"
rm -f "$ED/tail.log" "$ED/tail2.log" "$ED/tail3.log"
put crlf.log "HEAD $C1 $T\r\nbody\r\nexit 0\r\n"; ev check "$ID"; assert_contains "$out" "fresh crlf.log exit=0"
# a later commit that only touches .tickets/ keeps it fresh; one that touches tracked code makes it stale and names the file
reset_repo; put old.log "HEAD $C1 $T\nexit 0\n"
echo more >> ".tickets/$ID/ticket.md"; git commit -qam "tickets only"
ev check "$ID"; assert_contains "$out" "fresh old.log exit=0 (HEAD ${C1:0:7}, only .tickets/ changed since"
echo more >> src/a.txt; git commit -qam "code"
ev check "$ID"; assert_contains "$out" "stale old.log exit=0 (HEAD ${C1:0:7}; 1 tracked file(s) changed since: src/a.txt)"
for i in 1 2 3 4 5 6 7; do echo "$i" > "src/n$i.txt"; done; git add src; git commit -qm many
ev check "$ID"; assert_contains "$out" "8 tracked file(s) changed since:"; assert_contains "$out" "(+3 more)"
C3="$(git rev-parse HEAD)"
# explicit graded head: a log stamped at a later commit is not an ancestor of an earlier head
put new.log "HEAD $C3 $T\nexit 0\n"; ev check "$ID" "$C1"; assert_contains "$out" "stale new.log exit=0 (HEAD ${C3:0:7} is not an ancestor of ${C1:0:7})"
# a commit on another branch is not an ancestor
git checkout -q -b side "$C1"; echo side > src/side.txt; git add src; git commit -qm side; CS="$(git rev-parse HEAD)"; git checkout -q main
put side.log "HEAD $CS $T\nexit 0\n"; ev check "$ID"; assert_contains "$out" "stale side.log exit=0 (HEAD ${CS:0:7} is not an ancestor"
put ghost.log "HEAD $(printf 'f%.0s' $(seq 1 40)) $T\nexit 0\n"; ev check "$ID"; assert_contains "$out" "stale ghost.log exit=0 (unknown commit"
reset_repo
# an uncommitted edit to a tracked file after the stamp: it cannot vouch for that tree (reviewer finding 4); untracked files and .tickets/ do not count
reset_repo; put dirty.log "HEAD $C1 $T\nexit 0\n"
ev check "$ID"; assert_contains "$out" "fresh dirty.log"
echo more >> src/a.txt; ev check "$ID"; assert_contains "$out" "stale dirty.log exit=0 (HEAD ${C1:0:7}; tracked files are modified in the working tree since)"
git checkout -q -- src/a.txt; echo scratch > untracked.txt; echo more >> ".tickets/$ID/ticket.md"; ev check "$ID"; assert_contains "$out" "fresh dirty.log"
git checkout -q -- ".tickets/$ID/ticket.md"; rm -f untracked.txt
# ...but not when grading another commit: the working tree is not what is being graded
git commit -q --allow-empty -m next; echo more >> src/a.txt; ev check "$ID" "$C1"; assert_contains "$out" "fresh dirty.log"
git checkout -q -- src/a.txt; git reset -q --hard "$C1"
# git failing inside `check` (reviewer finding 3) is stale, never a silently empty list: a git shim that only fails the name-only diff
mkdir -p "$WORK/shim"; REAL_GIT="$(command -v git)"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "--name-only" ] && exit 128; done\nexec "%s" "$@"\n' "$REAL_GIT" > "$WORK/shim/git"; chmod +x "$WORK/shim/git"
echo more >> src/a.txt; git commit -qam "code"
set +e; out="$(cd "$REPO" && PATH="$WORK/shim:$PATH" bash "$EV" check "$ID" 2>&1)"; code=$?; set -e
assert_eq 0 "$code"; assert_contains "$out" "stale dirty.log exit=0 (HEAD ${C1:0:7}; git could not compare it with"
reset_repo
# exit= comes from the LAST line only
put e1.log "HEAD $C1 $T\nexit 0\nmore output\nexit 5\n"; put e2.log "HEAD $C1 $T\nexit 5\nmore output\n"; put e3.log "HEAD $C1 $T\nexit 99999\n"
put e4.log "HEAD $C1 $T\nexit 0 and then some\n"; put e5.log "HEAD $C1 $T\nexit -1\n"; put e6.log "HEAD $C1 $T\n"
checks "fresh e1.log exit=5 (HEAD ${C1:0:7} = graded, $T)
fresh e2.log exit=? (HEAD ${C1:0:7} = graded, $T)
fresh e3.log exit=? (HEAD ${C1:0:7} = graded, $T)
fresh e4.log exit=? (HEAD ${C1:0:7} = graded, $T)
fresh e5.log exit=? (HEAD ${C1:0:7} = graded, $T)
fresh e6.log exit=? (HEAD ${C1:0:7} = graded, $T)"
rm -rf "$ED"
# the shapes real evidence files have today (154 .log files, only a few in the documented one): everything else is unstamped
put u01.log "# HEAD $C1 — $T\n";                  put u02.log "HEAD $C1 (changes uncommitted) $T\n"
put u03.log "HEAD ${C1:0:8}+ (uncommitted) $T\n";  put u04.log "HEAD ${C1:0:8}+wt $T\n"
put u05.log "HEAD main $C1 $T\n";                  put u06.log "==> tests/tkt.sh\nok\n"
put u07.log "<title>Ticket Tree Mockups</title>\n"; put u08.log ""
put u09.log "\n\nHEAD $C1 $T\n";                    put u10.log "HEAD ${C1:0:6} $T\n"
put u11.log "HEAD $(printf '%s' "$C1" | tr a-f A-F) $T\n"; put u12.log "HEAD $C1  $T\n"
put u13.log "HEAD $C1 $T (uncommitted)\n";         put u14.log "HEAD $C1\n"
put u15.log "HEAD $C1 yesterday\n";                put u16.log "head $C1 $T\n"
put u17.log "HEAD after review fixes $T\n";        put u18.log "HEAD $C1 $T\0HEAD\n"
put u20.log "HEAD $C1 $T +wt dirty tree\n";       put u21.log "HEAD $C1 $T uncommitted\n"; put u22.log "HEAD $C1 $T release-manifest -> ok\n"
printf 'HEAD %s \000\001\002 binary\n' "$C1" > "$ED/u19.log"
ev check "$ID"; assert_eq 0 "$code"
while IFS= read -r l; do [[ "$l" == unstamped* ]] || fail "evidence: not classified unstamped: $l"; done <<< "$out"
assert_eq 22 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
rm -rf "$ED"
# file names: one line per file, nothing from the name can add a line or an escape
put "a b;c.log" "HEAD $C1 $T\n"; put $'new\nline.log' "HEAD $C1 $T\n"; put $'esc\033[31m.log' "HEAD $C1 $T\n"; put "x..log" "HEAD $C1 $T\n"; put "notes.txt" "HEAD $C1 $T\n"
ev check "$ID"; assert_eq 4 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"                         # notes.txt is not a .log
assert_contains "$out" "fresh a b?c.log"; assert_contains "$out" "fresh new?line.log"; assert_contains "$out" "fresh esc??31m.log"
[[ "$out" != *$'\033'* ]] || fail "evidence: an escape character from a file name reached the output"
rm -rf "$ED"
# a huge single line, a long command line and NUL bytes: bounded, no crash
mkdir -p "$ED"; { printf 'HEAD %s %s\n$ ' "$C1" "$T"; head -c 1048576 /dev/zero | tr '\0' 'x'; printf '\nexit 0\n'; } > "$ED/big.log"
{ printf 'HEAD %s ' "$C1"; head -c 1048576 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$ED/bigline1.log"
ev check "$ID"; assert_eq 0 "$code"; assert_contains "$out" "fresh big.log exit=0"; assert_contains "$out" "unstamped bigline1.log"
[[ "${#out}" -lt 600 ]] || fail "evidence: output was not bounded (${#out} chars)"
rm -rf "$ED"
# symlinked log: never followed
if ln -s "$WORK/outside/x.log" "$WORK/lnk" 2>/dev/null && [[ -L "$WORK/lnk" ]]; then
  printf 'HEAD %s %s\nexit 0\n' "$C1" "$T" > "$WORK/target.log"; mkdir -p "$ED"; ln -s "$WORK/target.log" "$ED/link.log"
  ev check "$ID"; assert_eq "unstamped link.log exit=?" "$out"; rm -rf "$ED"
  mkdir -p "$WORK/realev"; printf 'HEAD %s %s\nexit 0\n' "$C1" "$T" > "$WORK/realev/a.log"; ln -s "$WORK/realev" "$ED"
  ev check "$ID"; assert_eq 0 "$code"; assert_eq "" "$out"; rm -f "$ED"
fi
# no evidence directory: nothing to say, still success
reset_repo; ev check "$ID"; assert_eq 0 "$code"; assert_eq "" "$out"
# refusals
for bad in nope -- --all -x "HEAD~99"; do ev check "$ID" "$bad"; [[ "$code" == 2 ]] || fail "evidence: graded head '$bad' was accepted: $out"; done
ev check t-ffff; assert_eq 2 "$code"; ev check "T-ABCD"; assert_eq 2 "$code"
git commit -q --allow-empty -m nothing; ev check "$ID" "$C1"; assert_eq 0 "$code"

# --- random loop: whatever line 1 holds, only well-formed lines come out, and `fresh` means the strict shape (checked with grep -E, not the tool's own regex)
reset_repo
segs=("HEAD" "head" "#" "$C1" "${C1:0:7}" "${C1:0:6}" "deadbeef" "(uncommitted)" "(x)" "+wt" "$T" "2026-10-09" "07:22:47" "—" "main" "x" "" "exit" "0")
RANDOM="${CANON_FUZZ_SEED:-42}"; N="${CANON_FUZZ_N:-300}"; mkdir -p "$ED"; : > "$WORK/expect.txt"
for ((i = 0; i < N; i++)); do
  n=$((RANDOM % 6 + 1)); line=""
  for ((j = 0; j < n; j++)); do line+="${line:+ }${segs[RANDOM % ${#segs[@]}]}"; done
  [[ $((RANDOM % 3)) == 0 ]] && line="HEAD $C1 $T${line:+ $line}"
  name="r$(printf '%03d' "$i").log"; printf '%s\nexit 0\n' "$line" > "$ED/$name"
  if printf '%s\n' "$line" | grep -Eq "^HEAD [0-9a-f]{7,40} [0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?Z?\$"; then
    sha="$(printf '%s' "$line" | awk '{print $2}')"
    if [[ "$C1" == "$sha"* ]]; then echo "fresh $name" >> "$WORK/expect.txt"; else echo "stale $name" >> "$WORK/expect.txt"; fi   # an unknown sha is stale, not fresh
  else echo "unstamped $name" >> "$WORK/expect.txt"; fi
done
ev check "$ID" "$C1"; assert_eq 0 "$code"
assert_eq "$(wc -l < "$WORK/expect.txt" | tr -d ' ')" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
diff <(printf '%s\n' "$out" | awk '{print $1, $2}') "$WORK/expect.txt" > "$WORK/diff.txt" || fail "evidence: the random loop disagreed with the oracle: $(head -5 "$WORK/diff.txt")"
while IFS= read -r l; do [[ "$l" =~ ^(fresh|stale|unstamped)\ [A-Za-z0-9._\ /=:+,?-]+\ exit=(\?|[0-9]+)( .*)?$ ]] || fail "evidence: odd output line '$l'"; done <<< "$out"
reset_repo

# --- t-a3d7: evidence-neutral paths ---------------------------------------------------------------------------------------------
# A later change to a root close-time doc keeps a log fresh; the docs tests read (AGENTS.md, CLAUDE.md), dist/ and a same-named file in
# a subfolder do not.
for n in LEARNINGS.md LEARNINGS-archive.md DECISIONS.md DECISIONS-archive.md HANDOFF.md PROMOTED.md .claude/subagent-runs.jsonl; do
  reset_repo; put n.log "HEAD $C1 $T\nexit 0\n"
  mkdir -p "$(dirname "$n")"; echo x > "$n"; git add -f "$n"; git commit -qm "neutral $n"
  ev check "$ID"; assert_contains "$out" "fresh n.log exit=0 (HEAD ${C1:0:7}, only .tickets/ and evidence-neutral files changed since"
  echo y >> "$n"; ev check "$ID"; assert_contains "$out" "fresh n.log exit=0"   # uncommitted, at the graded head: still neutral
  ev stamp "$ID" neutral -- true; assert_eq 0 "$code"                             # and a stamp is not refused over it
done
# t-0b14: a skill's eval history is neutral; every other path under skills/ (and a history.jsonl at any other depth) is not.
n=skills/alpha/evals/history.jsonl
reset_repo; put n.log "HEAD $C1 $T\nexit 0\n"
mkdir -p "$(dirname "$n")"; echo x > "$n"; git add -f "$n"; git commit -qm "neutral $n"
ev check "$ID"; assert_contains "$out" "fresh n.log exit=0 (HEAD ${C1:0:7}, only .tickets/ and evidence-neutral files changed since"
echo y >> "$n"; ev check "$ID"; assert_contains "$out" "fresh n.log exit=0"
ev stamp "$ID" neutral -- true; assert_eq 0 "$code"
for n in AGENTS.md CLAUDE.md sub/HANDOFF.md sub/CLAUDE.md dist/x LEARNINGS.md.bak .claude/other.jsonl skills/alpha/evals/evals.json skills/alpha/SKILL.md skills/alpha/evals/notes.md skills/history.jsonl skills/alpha/history.jsonl skills/alpha/evals/sub/history.jsonl; do
  reset_repo; put n.log "HEAD $C1 $T\nexit 0\n"
  mkdir -p "$(dirname "$n")"; echo x > "$n"; git add -f "$n"; git commit -qm "not neutral $n"
  ev check "$ID"; assert_contains "$out" "stale n.log exit=0 (HEAD ${C1:0:7}; 1 tracked file(s) changed since: $n)"
done
reset_repo
# No test reads a neutral file from the repo root, so exempting them cannot hide a change a stamped command saw. Readers in canon's
# suite take the repo root from $ROOT (or a ROOT-like variable); a fixture writing its own copy in a temp project does not count.
# The pattern a root reader of neutral file $1 must match: ROOT, a short separator, an optional .claude/ or skills/<..>/evals/ prefix, the name.
reader_rx() { printf '%s' "(ROOT|REPO_ROOT|CANON_ROOT)[^A-Za-z0-9_]{1,12}(\\.claude/|skills/[^ \"']*evals/)?${1//./\\.}"; }
# Proof the grep can fail (t-0b14): planted readers of the skill eval history, quoted, globbed and bare, must all match; a fixture's own copy must not.
for planted in 'cat "$ROOT/skills/sprint/evals/history.jsonl"' 'wc -l "$ROOT"/skills/*/evals/history.jsonl' 'x=$REPO_ROOT/skills/a/evals/history.jsonl' 'cat "$ROOT/history.jsonl"'; do
  printf '%s\n' "$planted" | grep -qE "$(reader_rx history.jsonl)" || fail "evidence: the root-reader grep misses a planted reader: $planted"
done
if printf '%s\n' 'cat "$proj/skills/sprint/evals/history.jsonl"' | grep -qE "$(reader_rx history.jsonl)"; then fail "evidence: the root-reader grep matches a fixture project's own history.jsonl"; fi
for n in LEARNINGS.md LEARNINGS-archive.md DECISIONS.md DECISIONS-archive.md HANDOFF.md PROMOTED.md subagent-runs.jsonl history.jsonl; do
  # tests/subagent-log-cli.sh reads canon's own audit log only to assert the test did NOT write to it, so a gate's real entries cannot
  # change its result; any other reader fails here. history.jsonl (t-0b14): tools/skill-eval-history.sh, tests/skill-eval-scope.sh and
# tests/sprint.sh mention it, each read and found to use only a fixture project's copy, never canon's own skills/*/evals/history.jsonl.
  hits="$(grep -nE "$(reader_rx "$n")" "$ROOT"/tests/*.sh "$ROOT"/tests/*.js "$ROOT"/scripts/*.sh 2>/dev/null | grep -v -e '^[^:]*tests/evidence\.sh:' -e '^[^:]*tests/subagent-log-cli\.sh:' || true)"
  [[ -z "$hits" ]] || fail "evidence: a test reads the neutral path $n from the repo root, so it cannot be neutral: $hits"
done

# --- t-a3d7: covered ---------------------------------------------------------------------------------------------------------------
# A full board-spec run whose only later change is the baseline counts as re-judged by a guard log at the graded head over exactly its
# reports, unchanged. The fakes stand in for the real runner and guard; the real runner's two output lines are pinned below.
sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | cut -d' ' -f1; else shasum -a 256 -- "$1" | cut -d' ' -f1; fi; }
mkdir -p "$WORK/fakes"
cat > "$WORK/fakes/run-board-spec.sh" <<'FAKE'
#!/usr/bin/env bash
out="$2"; echo "board run..."; echo "run-board-spec: report dir $(cd "$out" && pwd -P)"
for r in "$out"/board-spec-*-run*.json; do
  if command -v sha256sum >/dev/null 2>&1; then h="$(sha256sum -- "$r" | cut -d' ' -f1)"; else h="$(shasum -a 256 -- "$r" | cut -d' ' -f1)"; fi
  echo "run-board-spec: report ${r##*/} sha256 $h"
done
exit "${FAKE_RC:-1}"
FAKE
printf 'process.exit(Number(process.env.GUARD_RC || 0));\n' > "$WORK/fakes/board-spec-guard.js"
D=".tickets/$ID/evidence/full-reports"
covered_setup() {   # base commit with the fakes and a baseline; reports; the run log at A; a baseline-only commit B
  reset_repo
  mkdir -p tests; cp "$WORK/fakes/run-board-spec.sh" "$WORK/fakes/board-spec-guard.js" tests/; echo '{}' > tests/board-spec-baseline.json
  git add tests; git commit -qm fakes
  mkdir -p "$D"; echo '{"r":1}' > "$D/board-spec-chromium-run1.json"; echo '{"r":2}' > "$D/board-spec-webkit-run1.json"
  ev stamp "$ID" full -- bash tests/run-board-spec.sh --out "$REPO/$D"; assert_eq "${FAKE_RC:-1}" "$code"
  echo '{"flaky":[1]}' > tests/board-spec-baseline.json; git commit -qam "baseline only"
}
guard() { ev stamp "$ID" guard -- node tests/board-spec-guard.js "$@"; }
want_covered() { ev check "$ID"; assert_eq 0 "$code"; assert_contains "$out" "covered full.log exit=1 ("; assert_contains "$out" "re-guarded at"; assert_contains "$out" "by guard.log over 2 report(s))"; }
want_stale() { ev check "$ID"; assert_eq 0 "$code"; assert_contains "$out" "stale full.log exit=1"; [[ "$out" != *"covered full.log"* ]] || fail "evidence: $1: must not be covered: $out"; }
covered_setup; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; assert_eq 0 "$code"; want_covered
A="$(sed -n '1s/^HEAD \([0-9a-f]*\) .*/\1/p' "$ED/full.log")"
assert_contains "$out" "covered full.log exit=1 (HEAD ${A:0:7}; only tests/board-spec-baseline.json changed since; re-guarded at $(git rev-parse --short=7 HEAD) by guard.log over 2 report(s))$os_txt cmd: bash tests/run-board-spec.sh --out"
guard "$REPO/$D/board-spec-webkit-run1.json" "$REPO/$D/board-spec-chromium-run1.json"; want_covered            # absolute paths, any order
# t-278d: the hint's recipe (guard under its own name, reports inside evidence/) is accepted; the old way (the run's own log name) is not.
covered_setup; ev check "$ID"; assert_contains "$out" "hint: to cover it"; assert_contains "$out" "evidence.sh stamp $ID board-spec-guard -- node tests/board-spec-guard.js"
ev stamp "$ID" board-spec-guard -- node tests/board-spec-guard.js "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; assert_eq 0 "$code"
ev check "$ID"; assert_contains "$out" "covered full.log exit=1 ("; assert_contains "$out" "by board-spec-guard.log over 2 report(s))"
[[ "$out" != *"hint:"* ]] || fail "evidence: a covered run should carry no hint: $out"
covered_setup; ev stamp "$ID" full -- node tests/board-spec-guard.js "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"
ev check "$ID"; [[ "$out" != *"covered full.log"* ]] || fail "evidence: stamping the guard under the run's own name must not cover: $out"
# every refusal, one at a time
covered_setup; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; echo ' ' >> "$D/board-spec-webkit-run1.json"; want_stale "an edited report"
covered_setup; echo '{}' > "$D/board-spec-webkit-run2.json"; guard "$D"/board-spec-*.json; want_stale "an extra report"
covered_setup; rm "$D/board-spec-webkit-run1.json"; guard "$D/board-spec-chromium-run1.json"; want_stale "a missing report"
covered_setup; guard "$D/board-spec-chromium-run1.json"; want_stale "a guard over a subset"
covered_setup; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; want_stale "a duplicated guard argument"
covered_setup; guard --partial "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; want_stale "a guard --partial over a full run"
# a --grep run: the runner itself calls the guard with --partial, so the re-run may too (once, and no other option)
grep_setup() {
  covered_setup; ev stamp "$ID" full -- bash tests/run-board-spec.sh --out "$REPO/$D" --grep x
  git commit -qm "re-stamp needs a later baseline change" --allow-empty; echo '{"flaky":[2]}' > tests/board-spec-baseline.json; git commit -qam "baseline again"
}
grep_setup; guard --partial "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; want_covered
grep_setup; guard "$D/board-spec-chromium-run1.json" --partial "$D/board-spec-webkit-run1.json"; want_covered
grep_setup; guard --partial --partial "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; want_stale "--partial twice"
grep_setup; guard --partial --strict "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; want_stale "another option beside --partial"
covered_setup; guard --baseline x.json "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; want_stale "a guard --baseline"
covered_setup; GUARD_RC=1 guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; want_stale "a failing guard"
covered_setup; echo more >> src/a.txt; git commit -qam "and code"; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; want_stale "a second changed file"
covered_setup; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; echo dirty >> src/a.txt; want_stale "an uncommitted change"; git checkout -q -- src/a.txt
covered_setup; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"
  mkdir -p "$WORK/elsewhere"; cp "$D"/*.json "$WORK/elsewhere/"; mv "$D" "$D.moved"; ln -s "$WORK/elsewhere" "$D"; want_stale "a report folder that is a symlink"; rm "$D"; mv "$D.moved" "$D"
covered_setup; ln -sf "$REPO/$D/board-spec-webkit-run1.json" "$WORK/link.json"; rm "$D/board-spec-webkit-run1.json"; cp "$WORK/link.json" "$D/board-spec-webkit-run1.json" 2>/dev/null || true
  rm -f "$D/board-spec-webkit-run1.json"; echo '{"r":2}' > "$WORK/real.json"; ln -s "$WORK/real.json" "$D/board-spec-webkit-run1.json"
  guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; want_stale "a report that is a symlink"
# the reports outside this ticket's evidence/, and the run log of another command
reset_repo; mkdir -p tests; cp "$WORK/fakes/run-board-spec.sh" "$WORK/fakes/board-spec-guard.js" tests/; echo '{}' > tests/board-spec-baseline.json; git add tests; git commit -qm fakes
  mkdir -p out; echo '{"r":1}' > out/board-spec-webkit-run1.json; printf 'out/\n' >> .git/info/exclude
  ev stamp "$ID" full -- bash tests/run-board-spec.sh --out "$REPO/out"; echo '{"f":1}' > tests/board-spec-baseline.json; git commit -qam baseline
  ev stamp "$ID" guard -- node tests/board-spec-guard.js out/board-spec-webkit-run1.json; want_stale "reports outside evidence/"
covered_setup; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"
  sed -i.bak '2s/.*/$ bash tests\/other.sh --out x/' "$ED/full.log"; rm -f "$ED/full.log.bak"; want_stale "a run log of another command"
covered_setup; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"
  { head -n2 "$ED/full.log"; sed -n '3,$p' "$ED/full.log" | grep 'sha256' | head -1; sed -n '3,$p' "$ED/full.log"; } > "$WORK/dup.log"; cp "$WORK/dup.log" "$ED/full.log"; want_stale "a report printed twice"
covered_setup; mv "$ED/full.log" "$WORK/full.log"; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; mv "$WORK/full.log" "$ED/full.log"
  git commit -q --allow-empty -m later; sed -i.bak "1s/.*/HEAD $(git rev-parse HEAD~1) $T/" "$ED/guard.log"; rm -f "$ED/guard.log.bak"
  ev check "$ID"; assert_contains "$out" "fresh guard.log"; assert_contains "$out" "covered full.log"   # a guard stamped at an ancestor with no change since still counts
  echo more >> src/a.txt; git commit -qam code2; want_stale "a guard log that is itself stale"
# each refusal again, where only that one check can catch it (t-a3d7 mutant sweep)
covered_setup; mkdir -p "$WORK/other"; cp "$D"/*.json "$WORK/other/"; guard "$WORK/other/board-spec-chromium-run1.json" "$WORK/other/board-spec-webkit-run1.json"
  want_stale "a guard over same-named copies in another folder"
covered_setup; mkdir -p "$ED/../evidence-other"; cp "$D"/*.json "$ED/../evidence-other/"
  ev stamp "$ID" full -- bash tests/run-board-spec.sh --out "$REPO/.tickets/$ID/evidence-other"; echo '{"f":3}' > tests/board-spec-baseline.json; git commit -qam b3
  guard ".tickets/$ID/evidence-other/board-spec-chromium-run1.json" ".tickets/$ID/evidence-other/board-spec-webkit-run1.json"; want_stale "a sibling folder named evidence-other"; rm -rf "$ED/../evidence-other"
covered_setup; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"
  { sed -n '1,$p' "$ED/full.log" | sed '$d'; echo "run-board-spec: report dir $REPO/$D"; echo "exit 1"; } > "$WORK/two.log"; cp "$WORK/two.log" "$ED/full.log"; want_stale "two report dir lines"
covered_setup; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"
  sed -i.bak "s|^run-board-spec: report dir .*|run-board-spec: report dir $REPO/$D/gone|" "$ED/full.log"; rm -f "$ED/full.log.bak"; want_stale "a report dir that does not exist"
covered_setup; mkdir -p tests/zz; echo z > tests/zz/after.txt; git add tests/zz; git commit -qm "sorts after the baseline"
  guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; want_stale "a second changed file that sorts after the baseline"
covered_setup; ev stamp "$ID" a-guard -- node tests/board-spec-guard.js "$D/board-spec-chromium-run1.json"; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"
  ev check "$ID"; assert_contains "$out" "covered full.log exit=1 ("; assert_contains "$out" "by guard.log over 2 report(s))"   # a bad guard log listed first does not stop the search
covered_setup; ev stamp "$ID" a-guard -- node tests/board-spec-guard.js --partial "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"
  guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"
  ev check "$ID"; assert_contains "$out" "by guard.log over 2 report(s))"   # a.guard's --partial on a full run is refused, guard.log still found
# the run's own exit: 0 or 1 (the guard's verdict) can be covered; 2 (the runner's own failure) and a missing exit line cannot
FAKE_RC=0 covered_setup; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; ev check "$ID"; assert_contains "$out" "covered full.log exit=0 ("
FAKE_RC=2 covered_setup; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; ev check "$ID"
  assert_contains "$out" "stale full.log exit=2"; [[ "$out" != *"covered full.log"* ]] || fail "evidence: a run that exited 2 was covered: $out"
covered_setup; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; sed -i.bak '$d' "$ED/full.log"; rm -f "$ED/full.log.bak"
  ev check "$ID"; assert_contains "$out" "stale full.log exit=?"; [[ "$out" != *"covered full.log"* ]] || fail "evidence: a run with no exit line was covered: $out"
# the command must BE the runner or the guard, not a command that merely names them (anchors on both line-2 checks)
covered_setup; ev stamp "$ID" full -- env bash tests/run-board-spec.sh --out "$REPO/$D"; echo '{"f":9}' > tests/board-spec-baseline.json; git commit -qam b9
  guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; ev check "$ID"
  [[ "$out" != *"covered full.log"* ]] || fail "evidence: a run log of 'env bash tests/run-board-spec.sh' was covered: $out"
covered_setup; ev stamp "$ID" guard -- env node tests/board-spec-guard.js "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"
  want_stale "a guard log of 'env node tests/board-spec-guard.js'"
# exactly one changed file that is not the baseline: a near-miss name, and an unrelated file
for other in tests/board-spec-baseline-old.json src/only.txt; do
  reset_repo; mkdir -p tests; cp "$WORK/fakes/run-board-spec.sh" "$WORK/fakes/board-spec-guard.js" tests/; echo '{}' > tests/board-spec-baseline.json; git add tests; git commit -qm fakes
  mkdir -p "$D"; echo '{"r":1}' > "$D/board-spec-chromium-run1.json"; echo '{"r":2}' > "$D/board-spec-webkit-run1.json"
  ev stamp "$ID" full -- bash tests/run-board-spec.sh --out "$REPO/$D"
  mkdir -p "$(dirname "$other")"; echo x > "$other"; git add "$other"; git commit -qm "only $other"
  guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; want_stale "a single changed file $other"
done
# another fresh exit-0 log listed before the guard log does not end the search
covered_setup; ev stamp "$ID" a-other -- true; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; want_covered
# a folder named like a report is refused, not hashed
covered_setup; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; mkdir "$D/board-spec-webkit-run2.json"
  want_stale "a folder named like a report"; [[ "$out" != *"directory"* ]] || fail "evidence: check tried to read a folder as a report: $out"
# a guard log kept fresh by an evidence-neutral change still counts
covered_setup; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"; echo h > HANDOFF.md; git add -f HANDOFF.md; git commit -qm handoff
  ev check "$ID"; assert_contains "$out" "fresh guard.log exit=0 (HEAD"; assert_contains "$out" "covered full.log"
# a run with no report at all re-judges nothing
covered_setup; rm "$D"/*.json; ev stamp "$ID" full -- bash tests/run-board-spec.sh --out "$REPO/$D" --grep x 2>/dev/null || true
  echo '{"f":4}' > tests/board-spec-baseline.json; git commit -qam b4; ev stamp "$ID" guard -- node tests/board-spec-guard.js --partial; want_stale "no report"
# an ancestor stamp with only .tickets/ changes since, but an uncommitted tracked edit now, is stale
reset_repo; put anc.log "HEAD $C1 $T\nexit 0\n"; echo t >> ".tickets/$ID/ticket.md"; git commit -qam tk; echo dirty >> src/a.txt
  ev check "$ID"; assert_contains "$out" "stale anc.log exit=0 (HEAD ${C1:0:7}; tracked files are modified in the working tree since)"; git checkout -q -- src/a.txt
# an evidence folder with no log prints nothing and exits 0, under macOS's bash 3.2 as well
reset_repo; mkdir -p "$ED"; echo x > "$ED/notes.txt"
for sh in bash /bin/bash; do set +e; out="$(cd "$REPO" && "$sh" "$EV" check "$ID" 2>&1)"; code=$?; set -e; assert_eq 0 "$code"; assert_eq "" "$out"; done

# hostile run logs: random folder lines and report lines never make a log covered, and check never fails
covered_setup; guard "$D/board-spec-chromium-run1.json" "$D/board-spec-webkit-run1.json"
cp "$ED/full.log" "$WORK/full.orig"
bad=('run-board-spec: report dir ' "run-board-spec: report dir $REPO/$D/.." "run-board-spec: report dir $REPO/$D/../.." 'run-board-spec: report dir /' "run-board-spec: report dir $REPO/.tickets/t-ffff/evidence/full-reports"
     "run-board-spec: report dir $REPO/$D/" "run-board-spec: report dir  $REPO/$D" "run-board-spec: report dir $REPO/./$D" 'run-board-spec: report board-spec-webkit-run1.json sha256 0000000000000000000000000000000000000000000000000000000000000000'
     'run-board-spec: report ../board-spec-webkit-run1.json sha256 aaaa' "run-board-spec: report dir $(printf 'x%.0s' $(seq 1 3000))" $'run-board-spec: report dir \x01\x02' "run-board-spec: report dir \$(touch $WORK/pwned)")
for i in $(seq 1 120); do
  pick="${bad[$((RANDOM % ${#bad[@]}))]}"
  { head -n2 "$WORK/full.orig"; grep -v '^run-board-spec: report dir' "$WORK/full.orig" | sed -n '3,$p'; printf '%s\n' "$pick"; } > "$ED/full.log"
  if (( RANDOM % 2 )); then printf 'run-board-spec: report dir %s\n' "$REPO/$D" >> "$ED/full.log.tmp" && sed -i.bak '$d' "$ED/full.log" && rm -f "$ED/full.log.bak" "$ED/full.log.tmp"; fi
  printf 'exit 1\n' >> "$ED/full.log"
  ev check "$ID"; assert_eq 0 "$code"
  [[ "$out" != *"covered full.log"* ]] || fail "evidence: hostile run log made it covered: $pick"
done
[[ ! -e "$WORK/pwned" ]] || fail "evidence: a report dir line was executed"
reset_repo
# the real runner prints exactly the lines check parses
grep -qF 'echo "run-board-spec: report dir $OUT"' "$ROOT/tests/run-board-spec.sh" || fail "evidence: tests/run-board-spec.sh no longer prints its report dir line"
grep -qF 'echo "run-board-spec: report ${r##*/} sha256 $h"' "$ROOT/tests/run-board-spec.sh" || fail "evidence: tests/run-board-spec.sh no longer prints its report sha256 lines"
grep -qF 'OUT="$(cd "$OUT" && pwd -P)"' "$ROOT/tests/run-board-spec.sh" || fail "evidence: tests/run-board-spec.sh must print the resolved report dir"

# --- the rules the evaluator reads stay in the docs: a later edit cannot drop the independence floor or the budget without failing here ---------------
need() {   # need <file> <fixed phrase> <what it carries>
  grep -qF -- "$2" "$ROOT/$1" || fail "evidence: $1 no longer says: $3 ('$2')"
}
need skills/sprint/reference/eval.md '5b. **Reuse fresh builder evidence (floor and budget).**' "the evidence-reuse step exists"
need skills/sprint/reference/eval.md 'A `fresh` log with `exit=0` may stand in' "only a fresh, exit-0 log may be reused"
need skills/sprint/reference/eval.md 'A `stale` or `unstamped` log, an `exit=` other than 0, or no log gets no reuse' "stale, unstamped, failing and missing logs get no reuse"
need skills/sprint/reference/eval.md 'Every test file or suite this sprint added or changed, once' "floor (a): the evaluator runs the changed suites itself"
need skills/sprint/reference/eval.md 'min(3, number of new guards)' "floor (b): mutants the evaluator runs itself"
need skills/sprint/reference/eval.md 'pick 2 suites yourself' "floor (c): the spot-check against the log"
need skills/sprint/reference/eval.md 'drop reuse of that log' "a spot-check disagreement voids reuse"
need skills/sprint/reference/eval.md 'count the new guards yourself from the diff' "the evaluator counts the new guards, not the builder"
need skills/sprint/reference/eval.md 'A log with no list to sample from gets no reuse' "a log the spot-check cannot sample gets no reuse"
need skills/sprint/reference/eval.md 'every long command under `timeout 600`' "a per-command timeout value"
need skills/sprint/reference/eval.md 'a base-control run names the base commit, so it is never `fresh`' "a base control is never reused"
need skills/sprint/reference/eval.md '25 minutes from the epoch you stamped in step 1' "the 25-minute budget"
need skills/sprint/reference/eval.md 'every item without evidence is `not-run`' "a spent budget fails closed"
need skills/sprint/reference/eval.md 'Evidence reuse: <n> of <m>' "the report line"
need skills/sprint/reference/start.md 'evidence.sh stamp <id> <name> -- <command>' "the builder writes evidence with the stamp tool"
need skills/sprint/reference/start.md 'an `(uncommitted)` stamp is never reusable' "an uncommitted stamp is never reusable"
need skills/sprint/reference/complete.md "the evaluator's elapsed minutes" "the eval row records evaluator minutes"
need skills/sprint/reference/complete.md 'run `sprint check-evidence <id>`' "the evidence pre-flight before dispatch"
need skills/sprint/reference/complete.md 'On exit 1, do not dispatch' "a refused pre-flight blocks the dispatch"
need skills/sprint/reference/eval.md 'A `covered` run log stands in for the full board spec' "covered is reusable"
need skills/sprint/reference/start.md 'with `--out .tickets/<id>/evidence/<dir>`' "the full spec is stamped with its reports in evidence/"

echo "evidence: ok"
