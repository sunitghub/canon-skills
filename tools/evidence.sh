#!/usr/bin/env bash
# evidence.sh — builder evidence a gate can check instead of re-running (t-e3cd).
#   evidence.sh stamp <ticket-id> <name> -- <command...>
#   evidence.sh check <ticket-id> [<graded-head>]
#   evidence.sh scope-audit      (t-29ee) exit 1 and name the lines when a source of a log's scope builds a suite path at run time
# stamp runs the command and writes .tickets/<id>/evidence/<name>.log: line 1 `HEAD <sha> <UTC time>`, line 2 `$ <command>`, line 3
# `# on <machine>; bash <x.y.z>` (t-c542: `canon-go machine`, e.g. "macOS 26.1, Darwin 25.1.0, arm64, 10 cores, 32 GB", else
# `uname -srm` when the board binary is missing or older; t-a83a: the machine, never its hostname; the bash running this script, which a `bash <script>` command
# also uses, not a shebang's own interpreter), the combined output, and a last line `exit <rc>` (never the command's own output: ours is
# appended after it). It exits with the command's own code.
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
# `exit=` is read from the LAST line only. Log content is never echoed beyond the sha, the time, a short sanitized `$` line and, before it,
# ` on: <os>, bash <x.y.z>` from a line 3 `# on …` (sanitized; absent for an older log, whose line is then unchanged). A stamp proves
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
source "$SCRIPT_DIR/platform-lib.sh"   # machine_line (t-c542)

usage() { echo "usage: evidence.sh stamp <ticket-id> <name> -- <command...> | evidence.sh check <ticket-id> [<graded-head>] | evidence.sh scope-audit" >&2; exit 2; }
refuse() { echo "evidence: $*" >&2; exit 125; }
die() { echo "evidence: $*" >&2; exit 2; }

id_re='^t-[a-z0-9]{4}$'
mode="${1-}"
[[ "$mode" == stamp || "$mode" == check || "$mode" == scope-audit ]] || usage
shift
id=""
if [[ "$mode" != scope-audit ]]; then
  [[ $# -ge 1 && "${1-}" =~ $id_re ]] || usage
  id="$1"; shift
fi

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
git -C "$root" rev-parse --verify -q HEAD >/dev/null 2>&1 || die "this repository has no commit yet"
if [[ "$mode" != scope-audit ]]; then
  "$SCRIPT_DIR/work-beat" touch || true   # t-187e
  tdir="${CANON_TICKETS_DIR:-$(tickets_dir)}"   # a plain clone has its own empty .tickets/: point this at the project's, and the stamp still names the clone's HEAD
  [[ -d "$tdir/$id" && ! -L "$tdir/$id" ]] || die "no ticket folder $id under $tdir"
  edir="$tdir/$id/evidence"
fi

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

# --- t-29ee: the scope of a log -------------------------------------------------------------------------------------------------------
# A log is stale after any non-neutral tracked change, except that a change to a shell suite `tests/<x>.sh` does not matter to a stamped
# command that cannot run it. Only two command shapes are known to read little of the tree, and the rule is conservative: when in doubt
# (any other command, a suite a source of the command names directly or through another suite, a deleted suite, a source that builds a suite
# path at run time) the log stays stale.
#   board spec  `[bash] tests/run-board-spec.sh [plain flags]`   reads the spec, the runner, tests/board-spec-*.js and tools/ (no *.md)
#   Go sweep    `mutant-sweep ... --map FILE=go -C tools/canon-go test [plain args] ...` for EVERY map   reads tools/canon-go (no *.md) and each FILE
# The stamped line is %q text from a file an agent can write, so it is only split (never evaluated) and matched strictly.
readers_board() { printf '%s\n' tests/sprint-check-app.spec.js tests/run-board-spec.sh ':(glob)tests/board-spec-*.js' tools ':(exclude,glob)**/*.md'; }
readers_go()    { printf '%s\n' tools/canon-go ':(exclude,glob)**/*.md'; }

# go_test_ok <test command> — 0 only for `go -C tools/canon-go test` with arguments from a short list: package paths inside that module (no `..`
# segment), -v -race -short, -count=N, -timeout D, -run NAME. Anything else is 1: -exec, -toolexec, a second -C, -overlay, -modfile, -o or a shell
# control character can run or read files the Go sources do not name.
go_test_ok() {
  local -a a=(); local i=4 t v
  read -r -a a <<< "$1" || true
  [[ "${a[0]-}" == go && "${a[1]-}" == -C && "${a[2]-}" == tools/canon-go && "${a[3]-}" == test ]] || return 1
  case "$1" in *[\;\&\|\(\)\<\>\$\`]*) return 1 ;; esac
  while (( i < ${#a[@]} )); do
    t="${a[$i]}"; i=$((i + 1))
    case "$t" in
      -v|-race|-short) ;;
      -count=*|-timeout=*) [[ "$t" =~ ^-(count|timeout)=[0-9]+[smh]?$ ]] || return 1 ;;
      -timeout) [[ "${a[$i]-}" =~ ^[0-9]+[smh]?$ ]] || return 1; i=$((i + 1)) ;;
      -run=*|-run)
        if [[ "$t" == -run ]]; then v="${a[$i]-}"; i=$((i + 1)); else v="${t#-run=}"; fi
        v="${v//\\\'/}"   # %q writes a quote as \'
        [[ "$v" =~ ^[A-Za-z0-9_]+$ ]] || return 1 ;;
      ./*) [[ "$t" =~ ^\./[A-Za-z0-9_./-]*$ && "/$t/" != */../* ]] || return 1 ;;
      *) return 1 ;;
    esac
  done
}

# reader_sources <line 2 of a log> prints the pathspecs, one per line, or nothing: then there is no scope.
reader_sources() {
  local c="${1#\$ }" ph=$'\001' t maps=0 want=0 bad=0 first rest=1 file
  local -a toks=() files=()
  c="${c//\\ /$ph}"
  read -r -a toks <<< "$c" || true
  [[ ${#toks[@]} -gt 0 ]] || return 0
  first="${toks[0]//$ph/ }"
  if [[ "$first" == bash && ${#toks[@]} -gt 1 ]]; then first="${toks[1]//$ph/ }"; rest=2; fi
  case "$first" in
    tests/run-board-spec.sh|./tests/run-board-spec.sh)
      for t in "${toks[@]:$rest}"; do t="${t//$ph/ }"; t="${t//\\/}"; [[ "$t" =~ ^[A-Za-z0-9_./=,:@%+-]+$ ]] || return 0; done   # %q escapes a comma; an escaped & or quote is still refused
      readers_board; return 0 ;;
    mutant-sweep|tools/mutant-sweep|./tools/mutant-sweep)
      for t in "${toks[@]:1}"; do
        t="${t//$ph/ }"
        if (( want )); then
          want=0; maps=$((maps + 1)); file="${t%%=*}"
          go_test_ok "${t#*=}" || bad=1
          [[ "$file" =~ ^[A-Za-z0-9_./-]+$ ]] || bad=1
          files+=("$file")
        elif [[ "$t" == --map ]]; then want=1
        fi
      done
      (( maps > 0 && ! bad && ! want )) || return 0
      readers_go
      for file in "${files[@]}"; do printf '%s\n' "$file"; done   # a mapped file is mutated and read by its test: in scope itself
      return 0 ;;
  esac
  return 0
}

# computed_suite_refs <tree> <pathspec>... — the lines of the reader sources that glob or build a `tests/` path at run time (`tests/*.sh`, `tests/$x`,
# `tests/"$x"`), which the names found by scope_suites would miss. The two lines that only CLASSIFY paths (tools/sprint, tools/tkt) are allowed; this file
# names the patterns, runs no suite, and is left out. Text mode (-a): a NUL byte must not hide a line. A name assembled from pieces (`"s"".sh"`, `${n}.sh`)
# is beyond any static scan: that residual risk is accepted, and the evaluator floor and the full suite still run.
computed_suite_refs() {
  local g="$1"; shift
  git -C "$root" grep -a -n -E 'tests/[^[:space:]"'"'"']*[$*?{]|tests/"' "$g" -- "$@" ':(exclude)tools/evidence.sh' 2>/dev/null \
    | grep -vF -e 'tests/*|test/*|spec/*' -e 'tests/sprint-check-app.spec.js|tests/run-board-spec.sh|tests/board-spec-*)' || true
}

# scope_audit — `evidence.sh scope-audit`: the offending lines for both shapes at HEAD, exit 1 when there are any. tests/evidence.sh runs it on the real repo.
scope_audit() {
  local kind p bad="" out; local -a rd
  for kind in board go; do
    rd=(); while IFS= read -r p; do rd+=("$p"); done < <(readers_$kind)
    out="$(computed_suite_refs HEAD "${rd[@]}")"
    if [[ -n "$out" ]]; then bad+="$out"$'\n'; fi
  done
  if [[ -n "$bad" ]]; then printf 'scope-audit: a reader source builds a suite path at run time, so an unnamed suite may be run; update the scope rule, then the allow-list in computed_suite_refs:\n%s' "$bad" >&2; return 1; fi
  echo "scope-audit: ok"
}

# scope_suites <tree> <pathspec>... — fills SCOPED: the shell suites (basenames in tests/ of that tree) that the reader sources name, and those the
# named suites name in turn, until nothing new is named. A name counts wherever it appears as a word `<name>.sh` (a path, a `source`, a comment):
# over-reading only keeps a log stale. Text mode (-a), so a NUL byte in a source does not hide the names.
scope_suites() {
  local g="$1" all words queue next w s
  shift
  SCOPED=""
  all="$(git -C "$root" ls-tree --name-only "$g" tests/ 2>/dev/null | sed -n 's|^tests/||p' | grep -E '^[A-Za-z0-9_.-]+\.sh$')" || all=""
  words="$(git -C "$root" grep -a -h -o -E '[A-Za-z0-9_.-]+\.sh' "$g" -- "$@" 2>/dev/null | sort -u)" || words=""
  queue="$(printf '%s\n' "$all" | grep -Fx -f <(printf '%s\n' "$words") || true)"
  while [[ -n "$queue" ]]; do
    SCOPED+="$queue"$'\n'
    next=""
    for s in $queue; do
      w="$(git -C "$root" grep -a -h -o -E '[A-Za-z0-9_.-]+\.sh' "$g" -- "tests/$s" 2>/dev/null | sort -u)" || w=""
      next+="$(printf '%s\n' "$all" | grep -Fx -f <(printf '%s\n' "$w") || true)"$'\n'
    done
    queue="$(printf '%s' "$next" | sed '/^$/d' | sort -u | grep -Fvx -f <(printf '%s' "$SCOPED") || true)"
  done
}

if [[ "$mode" == scope-audit ]]; then scope_audit; exit $?; fi

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
  os="$(machine_line)" && [[ -n "$os" ]] || os="$(uname -srm 2>/dev/null)" || os=unknown   # t-c542: canon-go machine, else uname
  printf 'HEAD %s %s\n$ %s\n# on %s; bash %s.%s.%s\n' "$head_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$cmd_text" "${os:-unknown}" \
    "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" "${BASH_VERSINFO[2]}" > "$tmp"
  t0=$SECONDS
  set +e; "$@" < /dev/null >> "$tmp" 2>&1; rc=$?; set -e
  secs=$((SECONDS - t0))
  if tracked_dirty || [[ "$(git -C "$root" rev-parse HEAD)" != "$head_sha" ]]; then
    refuse "tracked files or HEAD changed while the command ran, so the stamp would name a tree that was not tested; nothing was written"
  fi
  if [[ -s "$tmp" && -n "$(tail -c1 "$tmp")" ]]; then printf '\n' >> "$tmp"; fi
  printf 'exit %s\n' "$rc" >> "$tmp"
  chmod 644 "$tmp"; mv -f "$tmp" "$log"; trap - EXIT   # mktemp makes it 0600; the other logs are 0644
  echo "evidence: wrote $log (HEAD ${head_sha:0:7}, exit $rc)" >&2
  # t-9113: one event per written stamp (the command ran, whatever its exit), so the activity log can count reruns; observer-only
  canon_event evidence.stamped evidence "$root" "ticket=$id" "name=$name" "exit=$rc" "seconds=$secs"
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

# quarantine_only_diff <from> <to> — t-7f5f: 0 when every added or removed line of the board spec between the two commits is a
# `// QUARANTINE t-xxxx: reason` comment (checked line by line on -U0), else 1. Any other line, or a diff git cannot produce, is 1.
quarantine_only_diff() {
  local out line inhunk=0
  out="$(git -C "$root" diff -U0 --no-renames "$1" "$2" -- tests/sprint-check-app.spec.js 2>/dev/null)" || return 1
  while IFS= read -r line; do
    if (( ! inhunk )); then   # headers come only before the first hunk; after it `--- x` is a removed line `-- x`
      case "$line" in "diff --git "*|"index "*|"--- "*|"+++ "*|"") continue ;; esac
    fi
    case "$line" in
      "@@ "*) inhunk=1 ;;
      +*|-*) [[ "${line:1}" =~ ^[[:space:]]*//[[:space:]]*QUARANTINE[[:space:]]+t-[a-z0-9]{4}[[:space:]]*: ]] || return 1 ;;
      *) return 1 ;;
    esac
  done <<< "$out"
  return 0
}

# join_names <names...> — sets JOINED_N (how many) and JOINED: the first five names, printed with `safe`, then ` (+N more)` for the rest
join_names() {
  local p; JOINED=""; JOINED_N=0
  for p in "$@"; do JOINED_N=$((JOINED_N + 1)); if [[ $JOINED_N -le 5 ]]; then JOINED+="${JOINED:+, }$(safe "$p")"; fi; done
  if [[ $JOINED_N -gt 5 ]]; then JOINED+=" (+$((JOINED_N - 5)) more)"; fi
}

# classify_one <file> — sets LINE (the output line), KIND (its first word), CODE and BASEONLY (1 when the only non-neutral tracked change since
# the stamp is tests/board-spec-baseline.json, optionally with QUARANTINE-comment-only edits to the spec (t-7f5f): the one case `covered` may lift). Called directly, never in $(...), so the globals survive.
classify_one() {
  local f="$1" first last sha when cmdline osline shown full names p readers dropped kept ign wtline stamped_scope
  BASEONLY=0; SPECQ=0; CODE="?"; STAMP=""; SHOWN=""
  base="$(safe "${f##*/}")"
  if [[ -L "$f" || ! -f "$f" ]]; then KIND=unstamped; LINE="unstamped $base exit=?"; return 0; fi
  first="$(head -c 512 -- "$f" | LC_ALL=C tr -d '\000' | head -n1 | tr -d '\r')" || first=""   # `|| …`: head exiting early may SIGPIPE a writer, which pipefail would turn into a silent exit
  last="$(tail -c 256 -- "$f" | LC_ALL=C tr -d '\000' | tail -n1 | tr -d '\r')" || last=""
  if [[ "$last" =~ $exit_re ]]; then CODE="${BASH_REMATCH[1]}"; fi
  if [[ ! "$first" =~ $stamp_re ]]; then KIND=unstamped; CODE="?"; LINE="unstamped $base exit=?"; return 0; fi
  sha="${BASH_REMATCH[1]}"; when="${BASH_REMATCH[2]}"
  cmdline="$(head -c 512 -- "$f" | LC_ALL=C tr -d '\000' | sed -n '2p' | tr -d '\r')" || cmdline=""
  shown=""; if [[ "$cmdline" == '$ '* ]]; then shown=" cmd: $(safe "${cmdline:2:120}")"; fi
  osline="$(head -c 16384 -- "$f" | LC_ALL=C tr -d '\000' | sed -n '3p' | tr -d '\r')" || osline=""   # t-a83a; an old log has none. Bound as line2_of: a long line 2 must not cut it
  if [[ "$osline" == '# on '* && "${osline:5}" =~ [^[:space:]] ]]; then osline="${osline:5:80}"; shown=" on: $(safe "${osline//; /, }")$shown"; fi
  SHOWN="$shown"; STAMP="${sha:0:7}"
  wtline="stale $base exit=$CODE (HEAD ${sha:0:7}; tracked files are modified in the working tree since)$shown"   # tracked files differ from HEAD in the working tree
  KIND=stale
  full="$(git -C "$root" rev-parse --verify -q "$sha^{commit}" 2>/dev/null)" || { LINE="stale $base exit=$CODE (unknown commit $sha)$shown"; return 0; }
  if [[ "$full" == "$graded" ]]; then
    if (( wt_dirty )); then LINE="$wtline"
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
  dropped=(); kept=(); readers=()   # t-29ee: shell suites this log's command cannot run are not a reason to rerun it
  while IFS= read -r p; do [[ -n "$p" ]] && readers+=("$p"); done < <(reader_sources "$cmdline")
  if [[ ${#readers[@]} -gt 0 && ${#names[@]} -gt 0 ]]; then
    if [[ -n "$(computed_suite_refs "$graded" "${readers[@]}")" ]]; then readers=(); fi   # a source builds suite paths at run time: no scope
  fi
  if [[ ${#readers[@]} -gt 0 && ${#names[@]} -gt 0 ]]; then
    scope_suites "$full" "${readers[@]}"; stamped_scope="$SCOPED"   # the tree that was tested: a suite deleted since then was one it may have run
    scope_suites "$graded" "${readers[@]}"; SCOPED="$stamped_scope$SCOPED"
    for p in "${names[@]}"; do
      # a reader source is in scope itself, named or not; any other suite is out only when no source names it
      if [[ "$p" =~ ^tests/([A-Za-z0-9_.-]+\.sh)$ ]] && ! printf '%s\n' "${readers[@]}" | grep -Fxq -- "$p" \
         && ! printf '%s' "$SCOPED" | grep -Fxq -- "${BASH_REMATCH[1]}"; then dropped+=("$p"); else kept+=("$p"); fi
    done
    names=(); [[ ${#kept[@]} -eq 0 ]] || names=("${kept[@]}")
  fi
  if [[ ${#names[@]} -eq 0 && ${#dropped[@]} -gt 0 ]]; then   # t-29ee: everything that changed is outside this log's scope
    join_names "${dropped[@]}"
    if (( wt_dirty )); then LINE="$wtline"
    else KIND=fresh; LINE="fresh $base exit=$CODE (HEAD ${sha:0:7}; only files outside its scope changed since: $JOINED; $when)$shown"; fi
    return 0
  fi
  if [[ ${#names[@]} -eq 0 ]]; then
    if (( wt_dirty )); then LINE="$wtline"
    elif git -C "$root" diff --quiet --no-renames "$full" "$graded" -- . ':(exclude).tickets' 2>/dev/null; then
      KIND=fresh; LINE="fresh $base exit=$CODE (HEAD ${sha:0:7}, only .tickets/ changed since, $when)$shown"
    else KIND=fresh; LINE="fresh $base exit=$CODE (HEAD ${sha:0:7}, only .tickets/ and evidence-neutral files changed since, $when)$shown"; fi
    return 0
  fi
  if [[ ${#names[@]} -eq 1 && "${names[0]}" == tests/board-spec-baseline.json ]]; then BASEONLY=1
  else   # t-7f5f: a quarantine also adds/removes a `// QUARANTINE t-xxxx:` comment in the spec, which changes no behaviour
    BASEONLY=1
    for p in "${names[@]}"; do
      case "$p" in tests/board-spec-baseline.json) ;; tests/sprint-check-app.spec.js) SPECQ=1 ;; *) BASEONLY=0 ;; esac
    done
    if (( BASEONLY && SPECQ )) && ! quarantine_only_diff "$full" "$graded"; then BASEONLY=0; fi
  fi
  join_names "${names[@]}"
  ign=""; if [[ ${#dropped[@]} -gt 0 ]]; then ign=" (+${#dropped[@]} outside its scope ignored)"; fi
  LINE="stale $base exit=$CODE (HEAD ${sha:0:7}; $JOINED_N tracked file(s) changed since: $JOINED$ign)$shown"
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
FILES=(); KINDS=(); CODES=(); LINES=(); BASES=(); SPECQS=(); STAMPS=(); SHOWNS=()
for f in "$edir"/*.log; do
  classify_one "$f"
  FILES+=("$f"); KINDS+=("$KIND"); CODES+=("$CODE"); LINES+=("$LINE"); BASES+=("$BASEONLY"); SPECQS+=("$SPECQ"); STAMPS+=("$STAMP"); SHOWNS+=("$SHOWN")
done
for i in "${!FILES[@]}"; do
  if [[ "${BASES[$i]}" == 1 && "${CODES[$i]}" =~ ^[01]$ ]]; then   # exit 2: the run itself failed, nothing to re-judge
    g="$(covered_by "${FILES[$i]}")"
    if [[ -n "$g" ]]; then
      what="only tests/board-spec-baseline.json changed since"
      if [[ "${SPECQS[$i]}" == 1 ]]; then what="only tests/board-spec-baseline.json and QUARANTINE comment lines in tests/sprint-check-app.spec.js changed since"; fi
      LINES[$i]="covered $(safe "${FILES[$i]##*/}") exit=${CODES[$i]} (HEAD ${STAMPS[$i]}; $what; re-guarded at ${graded:0:7} by $(safe "${g% *}") over ${g##* } report(s))${SHOWNS[$i]}"
    elif [[ "$(line2_of "${FILES[$i]}")" =~ ^\$\ (bash\ )?(\./)?tests/run-board-spec\.sh(\ |$) ]]; then
      # t-278d: the recipe, so the next stamp neither overwrites the run's log nor leaves its reports outside evidence/.
      LINES[$i]+=$'\n'"  hint: to cover it, keep the run's --out folder inside .tickets/$id/evidence/, then stamp the guard under its OWN name, never this log's (that overwrites it): evidence.sh stamp $id board-spec-guard -- node tests/board-spec-guard.js <those reports>"
    fi
  fi
  echo "${LINES[$i]}"
done
exit 0
