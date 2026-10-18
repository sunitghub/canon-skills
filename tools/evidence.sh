#!/usr/bin/env bash
# evidence.sh — builder evidence a gate can check instead of re-running (t-e3cd).
#   evidence.sh stamp <ticket-id> <name> -- <command...>
#   evidence.sh check <ticket-id> [<graded-head>]
# stamp runs the command and writes .tickets/<id>/evidence/<name>.log: line 1 `HEAD <sha> <UTC time>`, line 2 `$ <command>`, the combined
# output, and a last line `exit <rc>` (never the command's own output: ours is appended after it). It exits with the command's own code.
# It refuses, running nothing and writing nothing, with 125 (like `timeout`, so a command's own exit 2 is not mistaken for a refusal) when
# tracked files are modified (a stamp names the commit that was tested, so the tree must BE that commit; untracked files, .tickets/ and
# the evidence-neutral close-time docs below are ignored), and again, writing nothing, if tracked files changed while the command ran.
# check classifies every evidence/*.log (top level only: subfolders hold history) against a graded head (default HEAD), one line each:
#   fresh <file> exit=<N>      line 1 is exactly `HEAD <sha> <time>` (nothing after the time) and the sha is the graded head or an ancestor with no
#                              tracked file changed since, committed or not, other than the evidence-neutral paths below
#   covered <file> exit=<N>    t-a3d7: a tests/run-board-spec.sh log whose reports sit in a folder inside this evidence/ dir, stale only because
#                              tests/board-spec-baseline.json changed since, that ended in exit 0 or 1 (the guard's verdict; 2 is the
#                              runner's own failure: the tree moved or a process leaked), and re-judged at the graded head by a fresh exit-0 log of
#                              `node tests/board-spec-guard.js` over exactly those reports, each still matching the sha256 the run log printed
#   stale <file> exit=<N>      stamped, but older with such changes, an unknown sha, or not an ancestor
#   unstamped <file> exit=?    anything else: `# HEAD …`, `(uncommitted)`, `+wt`, no line 1, empty, binary, a symlink (never followed)
#   (t-278d) a log stale only for the baseline but not covered gets a `  hint:` line after it with the covered recipe.
# `exit=` is read from the LAST line only. Log content is never echoed beyond the sha, the time and a short sanitized `$` line. A stamp proves
# freshness, not truth: the evaluator still runs its own floor (eval.md). check exits 0 for any content; 2 for a usage or repository error.
# CANON_TICKETS_DIR (optional) names the .tickets/ directory to use, for a stamp taken in a plain clone, whose own .tickets/ is not the project's.
set -euo pipefail

# Resolve symlinks so SCRIPT_DIR points to the real file location.
_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$_SOURCE" ]; do
  _DIR="$(cd -P "$(dirname "$_SOURCE")" && pwd)"
  _SOURCE="$(readlink "$_SOURCE")"
  [[ "$_SOURCE" != /* ]] && _SOURCE="$_DIR/$_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_SOURCE")" && pwd)"
source "$SCRIPT_DIR/ticket-root.sh"

usage() { echo "usage: evidence.sh stamp <ticket-id> <name> -- <command...> | evidence.sh check <ticket-id> [<graded-head>]" >&2; exit 2; }
refuse() { echo "evidence: $*" >&2; exit 125; }
die() { echo "evidence: $*" >&2; exit 2; }

id_re='^t-[0-9a-f]{4}$'
mode="${1-}"
[[ "$mode" == stamp || "$mode" == check ]] || usage
shift
[[ $# -ge 1 && "${1-}" =~ $id_re ]] || usage
id="$1"; shift

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
git -C "$root" rev-parse --verify -q HEAD >/dev/null 2>&1 || die "this repository has no commit yet"
tdir="${CANON_TICKETS_DIR:-$(tickets_dir)}"   # a plain clone has its own empty .tickets/: point this at the project's, and the stamp still names the clone's HEAD
[[ -d "$tdir/$id" && ! -L "$tdir/$id" ]] || die "no ticket folder $id under $tdir"
edir="$tdir/$id/evidence"

# Evidence-neutral paths (t-a3d7): written at close, and read by no test (tests/evidence.sh greps the suite to prove it), so a change to
# them cannot change what a stamped command saw. Repo root only. Narrower than the stale-eval guard's late-doc list in tools/sprint on
# purpose: tests read the root AGENTS.md and CLAUDE.md, and dist/ holds built binaries. Also skills/<name>/evals/history.jsonl (t-0b14):
# the skill-eval gate appends a pass rate after the full-suite stamp; the glob is exactly three segments, so evals.json and SKILL.md stay in.
NEUTRAL=(':(exclude).tickets' ':(exclude,literal)LEARNINGS.md' ':(exclude,literal)LEARNINGS-archive.md' ':(exclude,literal)DECISIONS.md'
  ':(exclude,literal)DECISIONS-archive.md' ':(exclude,literal)HANDOFF.md' ':(exclude,literal)PROMOTED.md' ':(exclude,literal).claude/subagent-runs.jsonl'
  ':(exclude,glob)skills/*/evals/history.jsonl')
tracked_dirty() {   # tracked files (worktree or index) differ from HEAD, outside the evidence-neutral paths
  ! git -C "$root" diff --quiet HEAD -- . "${NEUTRAL[@]}" 2>/dev/null
}

if [[ "$mode" == stamp ]]; then
  [[ $# -ge 3 && "$2" == -- ]] || usage
  name="$1"; shift 2
  [[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || usage
  [[ ! -L "$edir" ]] || refuse "$edir is a symlink"
  [[ ! -e "$edir" || -d "$edir" ]] || refuse "$edir is not a directory"
  log="$edir/$name.log"
  [[ ! -L "$log" ]] || refuse "$log is a symlink"
  [[ ! -e "$log" || -f "$log" ]] || refuse "$log is not a plain file"
  if tracked_dirty; then refuse "tracked files differ from HEAD: commit first, because a stamp names the commit that was tested"; fi
  head_sha="$(git -C "$root" rev-parse HEAD)"
  mkdir -p "$edir"
  tmp="$(mktemp "$edir/.stamp.XXXXXX")"; trap 'rm -f "$tmp"' EXIT
  cmd_text="$(printf '%q ' "$@")"; cmd_text="${cmd_text% }"   # %q keeps the quoting, so two commands that differ only in quoting give different lines
  printf 'HEAD %s %s\n$ %s\n' "$head_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$cmd_text" > "$tmp"
  set +e; "$@" < /dev/null >> "$tmp" 2>&1; rc=$?; set -e
  if tracked_dirty || [[ "$(git -C "$root" rev-parse HEAD)" != "$head_sha" ]]; then
    refuse "tracked files or HEAD changed while the command ran, so the stamp would name a tree that was not tested; nothing was written"
  fi
  if [[ -s "$tmp" && -n "$(tail -c1 "$tmp")" ]]; then printf '\n' >> "$tmp"; fi
  printf 'exit %s\n' "$rc" >> "$tmp"
  chmod 644 "$tmp"; mv -f "$tmp" "$log"; trap - EXIT   # mktemp makes it 0600; the other logs are 0644
  echo "evidence: wrote $log (HEAD ${head_sha:0:7}, exit $rc)" >&2
  exit "$rc"
fi

# --- check ---
graded="${1-}"
if [[ -z "$graded" ]]; then graded="HEAD"
else
  [[ "$graded" != -* ]] || die "graded head must not start with '-'"
fi
graded="$(git -C "$root" rev-parse --verify -q "$graded^{commit}" 2>/dev/null)" || die "graded head '${1-HEAD}' is not a commit"
[[ -d "$edir" && ! -L "$edir" ]] || exit 0
wt_dirty=0   # grading HEAD while tracked files are modified: a stamp cannot vouch for a tree it did not see
if [[ "$graded" == "$(git -C "$root" rev-parse HEAD)" ]] && tracked_dirty; then wt_dirty=1; fi
nfile="$(mktemp)"; trap 'rm -f "$nfile"' EXIT

stamp_re='^HEAD ([0-9a-f]{7,40}) ([0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?Z?)$'
exit_re='^exit (0|[1-9][0-9]{0,2})$'
safe() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._ /=:+,\\-' '?'; }

shopt -s nullglob
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | cut -d' ' -f1; else shasum -a 256 -- "$1" | cut -d' ' -f1; fi; }
line2_of() { head -c 16384 -- "$1" | LC_ALL=C tr -d '\000' | sed -n '2p' | tr -d '\r'; }   # a longer line 2 is cut, so it parses as nothing

# classify_one <file> — sets LINE (the output line), KIND (its first word), CODE and BASEONLY (1 when the only non-neutral tracked change since
# the stamp is tests/board-spec-baseline.json, the one case `covered` may lift). Called directly, never in $(...), so the globals survive.
classify_one() {
  local f="$1" first last sha when cmdline shown full names p list n more
  BASEONLY=0; CODE="?"; STAMP=""; SHOWN=""
  base="$(safe "${f##*/}")"
  if [[ -L "$f" || ! -f "$f" ]]; then KIND=unstamped; LINE="unstamped $base exit=?"; return 0; fi
  first="$(head -c 512 -- "$f" | LC_ALL=C tr -d '\000' | head -n1 | tr -d '\r')" || first=""   # `|| …`: head exiting early may SIGPIPE a writer, which pipefail would turn into a silent exit
  last="$(tail -c 256 -- "$f" | LC_ALL=C tr -d '\000' | tail -n1 | tr -d '\r')" || last=""
  if [[ "$last" =~ $exit_re ]]; then CODE="${BASH_REMATCH[1]}"; fi
  if [[ ! "$first" =~ $stamp_re ]]; then KIND=unstamped; CODE="?"; LINE="unstamped $base exit=?"; return 0; fi
  sha="${BASH_REMATCH[1]}"; when="${BASH_REMATCH[2]}"
  cmdline="$(head -c 512 -- "$f" | LC_ALL=C tr -d '\000' | sed -n '2p' | tr -d '\r')" || cmdline=""
  shown=""; if [[ "$cmdline" == '$ '* ]]; then shown=" cmd: $(safe "${cmdline:2:120}")"; fi
  SHOWN="$shown"; STAMP="${sha:0:7}"
  KIND=stale
  full="$(git -C "$root" rev-parse --verify -q "$sha^{commit}" 2>/dev/null)" || { LINE="stale $base exit=$CODE (unknown commit $sha)$shown"; return 0; }
  if [[ "$full" == "$graded" ]]; then
    if (( wt_dirty )); then LINE="stale $base exit=$CODE (HEAD ${sha:0:7}; tracked files are modified in the working tree since)$shown"
    else KIND=fresh; LINE="fresh $base exit=$CODE (HEAD ${sha:0:7} = graded, $when)$shown"; fi
    return 0
  fi
  if ! git -C "$root" merge-base --is-ancestor "$full" "$graded" 2>/dev/null; then
    LINE="stale $base exit=$CODE (HEAD ${sha:0:7} is not an ancestor of ${graded:0:7})$shown"; return 0
  fi
  if ! git -C "$root" diff --name-only -z --no-renames "$full" "$graded" -- . "${NEUTRAL[@]}" > "$nfile" 2>/dev/null; then
    LINE="stale $base exit=$CODE (HEAD ${sha:0:7}; git could not compare it with ${graded:0:7})$shown"; return 0
  fi
  names=(); while IFS= read -r -d '' p; do names+=("$p"); done < "$nfile"
  if [[ ${#names[@]} -eq 0 ]]; then
    if (( wt_dirty )); then LINE="stale $base exit=$CODE (HEAD ${sha:0:7}; tracked files are modified in the working tree since)$shown"
    elif git -C "$root" diff --quiet --no-renames "$full" "$graded" -- . ':(exclude).tickets' 2>/dev/null; then
      KIND=fresh; LINE="fresh $base exit=$CODE (HEAD ${sha:0:7}, only .tickets/ changed since, $when)$shown"
    else KIND=fresh; LINE="fresh $base exit=$CODE (HEAD ${sha:0:7}, only .tickets/ and evidence-neutral files changed since, $when)$shown"; fi
    return 0
  fi
  if [[ ${#names[@]} -eq 1 && "${names[0]}" == tests/board-spec-baseline.json ]]; then BASEONLY=1; fi
  list=""; n=0
  for p in "${names[@]}"; do n=$((n + 1)); if [[ $n -le 5 ]]; then list+="${list:+, }$(safe "$p")"; fi; done
  more=""; if [[ $n -gt 5 ]]; then more=" (+$((n - 5)) more)"; fi
  LINE="stale $base exit=$CODE (HEAD ${sha:0:7}; $n tracked file(s) changed since: $list$more)$shown"
}

# covered_by <run-log> — t-a3d7: prints "<guard log> <report count>" when a fresh exit-0 guard log re-judges this run's reports at the
# graded head, else nothing. Every input is a file an agent can write, so each link is checked once, never trusted: the run log is a
# run-board-spec log that printed exactly one report folder and one sha256 per report; the folder is a real directory inside this
# ticket's evidence/ (the printed path is the resolved one, so no symlinked component); the reports there are exactly the printed set,
# unchanged, none a symlink; and the guard log runs `node tests/board-spec-guard.js` over exactly those files and nothing else (an
# option such as --baseline or --strict is not a report, so it fails that), except --partial once when the run was a --grep run, which
# is how the runner itself calls the guard (${GREP:+--partial}). A dirty tree needs no check here: no guard log is fresh then.
covered_by() {
  local run="$1" dir rdir recorded names actual="" fpath g a apath adir got i partial_ok=0 partial_seen
  local -a args
  [[ "$(line2_of "$run")" =~ ^\$\ (bash\ )?(\./)?tests/run-board-spec\.sh(\ |$) ]] || return 0
  if [[ " $(line2_of "$run") " == *" --grep "* ]]; then partial_ok=1; fi
  dir="$(LC_ALL=C grep -a -E '^run-board-spec: report dir ' -- "$run" | sed 's/^run-board-spec: report dir //' | tr -d '\r')" || dir=""
  rdir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 0   # none, or a second folder line, is no real path
  [[ "$rdir" == "$REDIR"/* && "$dir" == "$rdir" ]] || return 0
  recorded="$(LC_ALL=C grep -a -E '^run-board-spec: report board-spec-[a-z]+-run[0-9]+\.json sha256 [0-9a-f]{64}$' -- "$run" | sed 's/^run-board-spec: report //' | sort)" || recorded=""
  [[ -n "$recorded" ]] || return 0   # a run with no report re-judges nothing
  for fpath in "$rdir"/board-spec-*-run*.json; do
    [[ -f "$fpath" && ! -L "$fpath" ]] || return 0
    actual+="${fpath##*/} sha256 $(sha256_of "$fpath")"$'\n'
  done
  [[ "$(printf '%s' "$actual" | sort)" == "$recorded" ]] || return 0   # also refuses a report printed twice
  names="$(printf '%s\n' "$recorded" | cut -d' ' -f1)"
  for i in "${!FILES[@]}"; do
    [[ "${KINDS[$i]}" == fresh && "${CODES[$i]}" == 0 ]] || continue
    g="${FILES[$i]}"
    [[ "$(line2_of "$g")" =~ ^\$\ node\ tests/board-spec-guard\.js\ (.+)$ ]] || continue
    read -r -a args <<< "${BASH_REMATCH[1]}"   # split on spaces without globbing; a %q-quoted path never names a report
    got=""; partial_seen=0
    for a in "${args[@]}"; do
      if [[ "$a" == --partial ]] && (( partial_ok && ! partial_seen )); then partial_seen=1; continue; fi
      if [[ "$a" == /* ]]; then apath="$a"; else apath="$root/$a"; fi
      adir="$(cd "$(dirname "$apath")" 2>/dev/null && pwd -P)" || { got="x"; break; }
      [[ "$adir" == "$rdir" ]] || { got="x"; break; }
      got+="${apath##*/}"$'\n'
    done
    [[ "$got" != x && "$(printf '%s' "$got" | sort)" == "$names" ]] || continue
    printf '%s %s' "${g##*/}" "$(printf '%s\n' "$names" | wc -l | tr -d ' ')"; return 0
  done
  return 0   # the caller assigns this under set -e
}

REDIR="$(cd "$edir" && pwd -P)"
FILES=(); KINDS=(); CODES=(); LINES=(); BASES=(); STAMPS=(); SHOWNS=()
for f in "$edir"/*.log; do
  classify_one "$f"
  FILES+=("$f"); KINDS+=("$KIND"); CODES+=("$CODE"); LINES+=("$LINE"); BASES+=("$BASEONLY"); STAMPS+=("$STAMP"); SHOWNS+=("$SHOWN")
done
for i in "${!FILES[@]}"; do
  if [[ "${BASES[$i]}" == 1 && "${CODES[$i]}" =~ ^[01]$ ]]; then   # exit 2: the run itself failed, nothing to re-judge
    g="$(covered_by "${FILES[$i]}")"
    if [[ -n "$g" ]]; then
      LINES[$i]="covered $(safe "${FILES[$i]##*/}") exit=${CODES[$i]} (HEAD ${STAMPS[$i]}; only tests/board-spec-baseline.json changed since; re-guarded at ${graded:0:7} by $(safe "${g% *}") over ${g##* } report(s))${SHOWNS[$i]}"
    elif [[ "$(line2_of "${FILES[$i]}")" =~ ^\$\ (bash\ )?(\./)?tests/run-board-spec\.sh(\ |$) ]]; then
      # t-278d: the recipe, so the next stamp neither overwrites the run's log nor leaves its reports outside evidence/.
      LINES[$i]+=$'\n'"  hint: to cover it, keep the run's --out folder inside .tickets/$id/evidence/, then stamp the guard under its OWN name, never this log's (that overwrites it): evidence.sh stamp $id board-spec-guard -- node tests/board-spec-guard.js <those reports>"
    fi
  fi
  echo "${LINES[$i]}"
done
exit 0
