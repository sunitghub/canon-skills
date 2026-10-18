#!/usr/bin/env bash
# sprint-check-evidence (t-a3d7) — `sprint check-evidence <id>`, the pre-flight complete.md step 3 runs before dispatching the
# evaluator: ok only when every top-level evidence log is fresh with exit 0 or covered (evidence.sh check owns those words).
# Runs in a throwaway git repo; nothing touches the real tree or the real .tickets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-evidence.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg" LC_ALL=C
unset CANON_TICKETS_DIR
REPO="$WORK/repo"; ID=t-abcd; ED="$REPO/.tickets/$ID/evidence"
mkdir -p "$REPO" && cd "$REPO"
git init -q -b main . && git config user.name t && git config user.email t@t
mkdir -p ".tickets/$ID" src; echo a > src/a.txt; echo '# t' > ".tickets/$ID/ticket.md"
git add src && git commit -qm base
C1="$(git rev-parse HEAD)"; T="2026-10-14T10:00:00Z"

ce() { set +e; out="$(cd "$REPO" && bash "$ROOT/tools/sprint" check-evidence "$@" 2>&1)"; code=$?; set -e; }
put() { mkdir -p "$(dirname "$ED/$1")"; printf '%b' "$2" > "$ED/$1"; }

# usage
ce; assert_eq 2 "$code"; assert_contains "$out" "usage: sprint check-evidence"
ce nope; assert_eq 2 "$code"
ce 't-abcd;x'; assert_eq 2 "$code"
# no evidence at all: nothing to refuse
ce "$ID"; assert_eq 0 "$code"; assert_contains "$out" "no stamped logs"
# fresh exit 0 only: ok
put a.log "HEAD $C1 $T\n\$ bash tests/x.sh\nexit 0\n"; put b.log "HEAD $C1 $T\nexit 0\n"
ce "$ID"; assert_eq 0 "$code"; assert_contains "$out" "check-evidence: ok (2 log(s) fresh with exit 0 or covered)"; assert_count 0 "REFUSE" <(printf '%s' "$out")
# t-a83a: a stamp's `# on` line 3 puts " on: …" in check's line; still ok
put os.log "HEAD $C1 $T\n\$ bash tests/x.sh\n# on Linux 6.8.0 x86_64; bash 5.2.21\nexit 0\n"
ce "$ID"; assert_eq 0 "$code"; assert_contains "$out" "ok      fresh os.log exit=0 (HEAD ${C1:0:7} = graded, $T) on: Linux 6.8.0 x86_64, bash 5.2.21 cmd:"
assert_contains "$out" "check-evidence: ok (3 log(s)"; rm "$ED/os.log"
# each kind of bad log refuses on its own, named, with the fix hints
put c.log "HEAD $C1 $T\nexit 3\n"; ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  fresh c.log exit=3"; assert_contains "$out" "1 of 3 log(s)"
assert_contains "$out" "fix the failure and re-stamp; for a full board spec failing only on new flakes, list them, then stamp"
assert_contains "$out" "at HEAD (the run log becomes covered)"; assert_contains "$out" "do not dispatch it yet"
rm "$ED/c.log"
put d.log "no stamp\nexit 0\n"; ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  unstamped d.log"; assert_contains "$out" "move a history or off-tree log into a subfolder"
rm "$ED/d.log"
echo b >> src/a.txt; git commit -qam code
ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  stale a.log"; assert_contains "$out" "REFUSE  stale b.log"; assert_contains "$out" "re-stamp at HEAD"
C2="$(git rev-parse HEAD)"; put a.log "HEAD $C2 $T\nexit 0\n"; put b.log "HEAD $C2 $T\nexit 0\n"
ce "$ID"; assert_eq 0 "$code"
# an uncommitted tracked edit makes even a HEAD stamp refuse
echo c >> src/a.txt; ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "tracked files are modified"; git checkout -q -- src/a.txt
# a log with no exit line is not exit 0
put e.log "HEAD $C2 $T\nno exit line\n"; ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  fresh e.log exit=?"; rm "$ED/e.log"
# subfolders hold history: never counted, whatever they contain
put history/old.log "HEAD $C1 $T\nexit 1\n"; put history/deeper/x.log "garbage"
ce "$ID"; assert_eq 0 "$code"; assert_contains "$out" "check-evidence: ok (2 log(s)"
# a name stamp never writes is refused by name, so it cannot smuggle a fake `exit=0` into the line check prints (reviewer finding 1)
# (named to sort first, so a refusal that stopped the scan, or counted the name twice, shows in the count)
put '0 exit=0 y.log' "HEAD $C2 $T\nexit 1\n"; ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "REFUSE  0?exit?0?y.log: a name evidence.sh stamp never writes"
assert_contains "$out" "check-evidence: 1 of 3 log(s)"; assert_contains "$out" "ok      fresh a.log"; assert_contains "$out" "ok      fresh b.log"
[[ "$out" != *"ok      fresh 0"* ]] || fail "check-evidence: a crafted name passed as ok: $out"; rm "$ED/0 exit=0 y.log"
for bad in 'Upper.log' 'a b;c.log' $'esc\033[31m.log' '-dash.log'; do
  put "$bad" "HEAD $C2 $T\nexit 0\n"; ce "$ID"; assert_eq 1 "$code"; assert_contains "$out" "a name evidence.sh stamp never writes"
  [[ "$out" != *$'\033'* ]] || fail "check-evidence: an escape character reached the output"; rm -- "$ED/$bad"
done
ce "$ID"; assert_eq 0 "$code"
# a dotfile is never scanned, by check or by check-evidence (like a subfolder)
put .hidden.log "HEAD $C1 $T\nexit 1\n"; ce "$ID"; assert_eq 0 "$code"; rm "$ED/.hidden.log"
# a non-.log file is not counted either
put notes.txt "exit 1"; ce "$ID"; assert_eq 0 "$code"
# a failing evidence.sh (no ticket folder) is a usage error, not an ok
ce t-ffff; assert_eq 2 "$code"; assert_contains "$out" "evidence.sh check failed"
# outside a repository
mkdir -p "$WORK/nogit/.tickets/$ID"; set +e; out="$(cd "$WORK/nogit" && bash "$ROOT/tools/sprint" check-evidence "$ID" 2>&1)"; code=$?; set -e
assert_eq 2 "$code"

echo "sprint-check-evidence: ok"
