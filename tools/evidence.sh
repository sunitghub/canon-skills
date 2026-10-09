#!/usr/bin/env bash
# evidence.sh — builder evidence a gate can check instead of re-running (t-e3cd).
#   evidence.sh stamp <ticket-id> <name> -- <command...>
#   evidence.sh check <ticket-id> [<graded-head>]
# stamp runs the command and writes .tickets/<id>/evidence/<name>.log: line 1 `HEAD <sha> <UTC time>`, line 2 `$ <command>`, the combined
# output, and a last line `exit <rc>` (never the command's own output: ours is appended after it). It exits with the command's own code.
# It refuses, running nothing and writing nothing, with 125 (like `timeout`, so a command's own exit 2 is not mistaken for a refusal) when
# tracked files are modified (a stamp names the commit that was tested, so the tree must BE that commit; untracked files and .tickets/ are
# ignored), and again, writing nothing, if tracked files changed while the command ran.
# check classifies every evidence/*.log against a graded head (default HEAD), one line each:
#   fresh <file> exit=<N>      line 1 is exactly `HEAD <sha> <time>` and the sha is the graded head or an ancestor with no tracked file
#                              outside .tickets/ changed since (stricter than the stale-eval guard's allow-list, which it need not copy)
#   stale <file> exit=<N>      stamped, but older with such changes, an unknown sha, or not an ancestor
#   unstamped <file> exit=?    anything else: `# HEAD …`, `(uncommitted)`, `+wt`, no line 1, empty, binary, a symlink (never followed)
# `exit=` is read from the LAST line only. Log content is never echoed beyond the sha, the time and a short sanitized `$` line. A stamp proves
# freshness, not truth: the evaluator still runs its own floor (eval.md). check exits 0 for any content; 2 for a usage or repository error.
# CANON_TICKETS_DIR (optional) names the .tickets/ directory to use, for a stamp taken in a plain clone, whose own .tickets/ is not the project's.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

tracked_dirty() {   # tracked files (worktree or index) differ from HEAD, outside .tickets/
  ! git -C "$root" diff --quiet HEAD -- . ':(exclude).tickets' 2>/dev/null
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
  cmd_text="$*"; cmd_text="${cmd_text//[$'\n\r']/ }"
  printf 'HEAD %s %s\n$ %s\n' "$head_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$cmd_text" > "$tmp"
  set +e; "$@" < /dev/null >> "$tmp" 2>&1; rc=$?; set -e
  if tracked_dirty || [[ "$(git -C "$root" rev-parse HEAD)" != "$head_sha" ]]; then
    refuse "tracked files or HEAD changed while the command ran, so the stamp would name a tree that was not tested; nothing was written"
  fi
  if [[ -s "$tmp" && -n "$(tail -c1 "$tmp")" ]]; then printf '\n' >> "$tmp"; fi
  printf 'exit %s\n' "$rc" >> "$tmp"
  mv -f "$tmp" "$log"; trap - EXIT
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

stamp_re='^HEAD ([0-9a-f]{7,40}) ([0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?Z?)( [^()]*)?$'
exit_re='^exit (0|[1-9][0-9]{0,2})$'
safe() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._ /=:+,-' '?'; }

shopt -s nullglob
for f in "$edir"/*.log; do
  base="$(safe "${f##*/}")"
  if [[ -L "$f" || ! -f "$f" ]]; then echo "unstamped $base exit=?"; continue; fi
  first="$(head -c 512 -- "$f" | LC_ALL=C tr -d '\000' | head -n1 | tr -d '\r')" || first=""   # `|| …`: head exiting early may SIGPIPE a writer, which pipefail would turn into a silent exit
  last="$(tail -c 256 -- "$f" | LC_ALL=C tr -d '\000' | tail -n1 | tr -d '\r')" || last=""
  code="?"; if [[ "$last" =~ $exit_re ]]; then code="${BASH_REMATCH[1]}"; fi
  if [[ ! "$first" =~ $stamp_re ]]; then echo "unstamped $base exit=?"; continue; fi
  sha="${BASH_REMATCH[1]}"; when="${BASH_REMATCH[2]}"
  cmdline="$(head -c 512 -- "$f" | LC_ALL=C tr -d '\000' | sed -n '2p' | tr -d '\r')" || cmdline=""
  shown=""; if [[ "$cmdline" == '$ '* ]]; then shown=" cmd: $(safe "${cmdline:2:120}")"; fi
  full="$(git -C "$root" rev-parse --verify -q "$sha^{commit}" 2>/dev/null)" || { echo "stale $base exit=$code (unknown commit $sha)$shown"; continue; }
  if [[ "$full" == "$graded" ]]; then echo "fresh $base exit=$code (HEAD ${sha:0:7} = graded, $when)$shown"; continue; fi
  if ! git -C "$root" merge-base --is-ancestor "$full" "$graded" 2>/dev/null; then
    echo "stale $base exit=$code (HEAD ${sha:0:7} is not an ancestor of ${graded:0:7})$shown"; continue
  fi
  names=(); while IFS= read -r -d '' p; do names+=("$p"); done < <(git -C "$root" diff --name-only -z --no-renames "$full" "$graded" -- . ':(exclude).tickets')
  if [[ ${#names[@]} -eq 0 ]]; then echo "fresh $base exit=$code (HEAD ${sha:0:7}, only .tickets/ changed since, $when)$shown"; continue; fi
  list=""; n=0
  for p in "${names[@]}"; do n=$((n + 1)); if [[ $n -le 5 ]]; then list+="${list:+, }$(safe "$p")"; fi; done
  more=""; if [[ $n -gt 5 ]]; then more=" (+$((n - 5)) more)"; fi
  echo "stale $base exit=$code (HEAD ${sha:0:7}; $n tracked file(s) changed since: $list$more)$shown"
done
exit 0
