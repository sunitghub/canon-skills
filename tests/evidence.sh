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
assert_eq '$ bash -c echo one; echo two' "$(sed -n 2p "$f")"
assert_eq "one two exit 0" "$(sed -n '3,$p' "$f" | tr '\n' ' ' | sed 's/ $//')"
ev stamp "$ID" suite -- bash -c 'echo failing; exit 7'; assert_eq 7 "$code"                      # the command's own code comes back and is written
assert_eq "exit 7" "$(tail -n1 "$f")"; assert_count 0 "exit 0" "$f"                                 # a re-stamp replaces the log
ev stamp "$ID" noeol -- bash -c 'printf "no newline"'; assert_eq 0 "$code"
assert_eq "no newline|exit 0" "$(tail -n2 "$ED/noeol.log" | tr '\n' '|' | sed 's/|$//')"           # our exit line starts on its own line
# output that imitates our lines cannot forge the last line, and line 1 is ours
ev stamp "$ID" forge -- bash -c 'echo "HEAD 0000000000000000000000000000000000000000 2020-01-01T00:00:00Z"; echo "exit 0"; exit 5'; assert_eq 5 "$code"
assert_eq "exit 5" "$(tail -n1 "$ED/forge.log")"; assert_eq "HEAD $C1" "$(sed -n 1p "$ED/forge.log" | cut -d' ' -f1-2)"
ev check "$ID" "$C1"; assert_contains "$out" "exit=5"
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
rm -rf "$ED"
# abbreviated sha, trailing text after the time, CRLF
put abbr.log "HEAD ${C1:0:7} $T\n"; ev check "$ID"; assert_eq fresh "$(first_word)"
put tail.log "HEAD $C1 2026-10-09 07:22:47  release-manifest -> ok\n"; ev check "$ID"; assert_contains "$out" "fresh tail.log"
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
# the shapes real evidence files have today (292 of them, about 24 in the documented one): everything else is unstamped
put u01.log "# HEAD $C1 — $T\n";                  put u02.log "HEAD $C1 (changes uncommitted) $T\n"
put u03.log "HEAD ${C1:0:8}+ (uncommitted) $T\n";  put u04.log "HEAD ${C1:0:8}+wt $T\n"
put u05.log "HEAD main $C1 $T\n";                  put u06.log "==> tests/tkt.sh\nok\n"
put u07.log "<title>Ticket Tree Mockups</title>\n"; put u08.log ""
put u09.log "\n\nHEAD $C1 $T\n";                    put u10.log "HEAD ${C1:0:6} $T\n"
put u11.log "HEAD $(printf '%s' "$C1" | tr a-f A-F) $T\n"; put u12.log "HEAD $C1  $T\n"
put u13.log "HEAD $C1 $T (uncommitted)\n";         put u14.log "HEAD $C1\n"
put u15.log "HEAD $C1 yesterday\n";                put u16.log "head $C1 $T\n"
put u17.log "HEAD after review fixes $T\n";        put u18.log "HEAD $C1 $T\0HEAD\n"
printf 'HEAD %s \000\001\002 binary\n' "$C1" > "$ED/u19.log"
ev check "$ID"; assert_eq 0 "$code"
while IFS= read -r l; do [[ "$l" == unstamped* ]] || fail "evidence: not classified unstamped: $l"; done <<< "$out"
assert_eq 19 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
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
  if printf '%s\n' "$line" | grep -Eq "^HEAD [0-9a-f]{7,40} [0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?Z?( [^()]*)?\$"; then
    sha="$(printf '%s' "$line" | awk '{print $2}')"
    if [[ "$C1" == "$sha"* ]]; then echo "fresh $name" >> "$WORK/expect.txt"; else echo "stale $name" >> "$WORK/expect.txt"; fi   # an unknown sha is stale, not fresh
  else echo "unstamped $name" >> "$WORK/expect.txt"; fi
done
ev check "$ID" "$C1"; assert_eq 0 "$code"
assert_eq "$(wc -l < "$WORK/expect.txt" | tr -d ' ')" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
diff <(printf '%s\n' "$out" | awk '{print $1, $2}') "$WORK/expect.txt" > "$WORK/diff.txt" || fail "evidence: the random loop disagreed with the oracle: $(head -5 "$WORK/diff.txt")"
while IFS= read -r l; do [[ "$l" =~ ^(fresh|stale|unstamped)\ [A-Za-z0-9._\ /=:+,?-]+\ exit=(\?|[0-9]+)( .*)?$ ]] || fail "evidence: odd output line '$l'"; done <<< "$out"
reset_repo

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
need skills/sprint/reference/eval.md '25 minutes from the epoch you stamped in step 1' "the 25-minute budget"
need skills/sprint/reference/eval.md 'every item without evidence is `not-run`' "a spent budget fails closed"
need skills/sprint/reference/eval.md 'Evidence reuse: <n> of <m>' "the report line"
need skills/sprint/reference/start.md 'evidence.sh stamp <id> <name> -- <command>' "the builder writes evidence with the stamp tool"
need skills/sprint/reference/start.md 'an `(uncommitted)` stamp is never reusable' "an uncommitted stamp is never reusable"
need skills/sprint/reference/complete.md "the evaluator's elapsed minutes" "the eval row records evaluator minutes"

echo "evidence: ok"
