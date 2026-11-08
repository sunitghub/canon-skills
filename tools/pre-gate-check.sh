#!/usr/bin/env bash
# pre-gate-check.sh <ticket-id> — t-014f: cheap deterministic checks on the sprint's changed files, stamped as
# evidence before any gate is dispatched, so the evaluator reads the result instead of rediscovering it.
#   Runs shellcheck (warning severity and up: info notes such as SC1091 must not refuse a close) on changed .sh, node --check on changed .js, go vet on the changed Go packages. A failing tool exits
#   non-zero (the stamped log then ends `exit 1`, which `sprint check-evidence` refuses). A MISSING tool is never a
#   pass: the line says `<tool> skipped | no <tool>`.
#   A project with tests/gate-cases/ also runs the gate eval set (gate-cases.sh run) and says `gate cases N/N`; a failing case is non-zero (t-2178).
#   Advisory only (never a refusal): symbols declared in a changed file and referenced nowhere (dead-code-scan.sh
#   --changed), and every changed file the scan cannot read ("not scanned").
# Output: the one stamped line (plus the failing tool's output when a check fails); the full log is
# <tickets dir>/<id>/evidence/pre-gate.log (the checkout's .tickets/, or CANON_TICKETS_DIR when it has none), written through evidence.sh stamp.
# Changed files = committed diff from PRE_GATE_BASE (default: merge-base HEAD origin/main) to HEAD. Complexity is not
# checked: no tool in canon's stack measures it (go vet, shellcheck and node --check do not), and none is added.
set -euo pipefail

_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$_SOURCE" ]; do
  _DIR="$(cd -P "$(dirname "$_SOURCE")" && pwd)"
  _SOURCE="$(readlink "$_SOURCE")"
  [[ "$_SOURCE" != /* ]] && _SOURCE="$_DIR/$_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_SOURCE")" && pwd)"

run_checks() {
  local base files f line="pre-gate" fails="" out rc=0 sc=() nd=() gd=() d
  if [[ -n "${PRE_GATE_BASE-}" ]]; then base="$PRE_GATE_BASE"
  else base="$(git merge-base HEAD origin/main 2>/dev/null)" || { echo "pre-gate: no git baseline (merge-base HEAD origin/main failed); set PRE_GATE_BASE" >&2; return 2; }
  fi
  files="$(git -c core.quotePath=false diff --name-only --diff-filter=d "$base" HEAD | grep -v '^\.tickets/' || true)"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case "$f" in
      *.sh|*.bash) sc+=("$f") ;;
      *.js|*.mjs|*.cjs) nd+=("$f") ;;
      *.go) d="$(dirname "$f")"; [[ " ${gd[*]-} " == *" $d "* ]] || gd+=("$d") ;;
    esac
  done <<<"$files"

  if ((${#sc[@]})); then
    if command -v shellcheck >/dev/null 2>&1; then
      if out="$(shellcheck -x -S warning "${sc[@]}" 2>&1)"; then line+=" | shellcheck ${#sc[@]} ok"
      else line+=" | shellcheck FAIL"; fails+="$out"$'\n'; rc=1; fi
    else line+=" | shellcheck skipped | no shellcheck"; fi
  fi
  if ((${#nd[@]})); then
    if command -v node >/dev/null 2>&1; then
      local bad=0
      for f in "${nd[@]}"; do out="$(node --check "$f" 2>&1)" || { bad=1; fails+="$out"$'\n'; }; done
      if ((bad)); then line+=" | node --check FAIL"; rc=1; else line+=" | node --check ${#nd[@]} ok"; fi
    else line+=" | node --check skipped | no node"; fi
  fi
  if ((${#gd[@]})); then
    if command -v go >/dev/null 2>&1; then
      local bad=0 mod rel
      for d in "${gd[@]}"; do
        mod="$d"; while [[ "$mod" != . && ! -f "$mod/go.mod" ]]; do mod="$(dirname "$mod")"; done
        [[ -f "$mod/go.mod" ]] || continue
        rel="./${d#"$mod"/}"; [[ "$d" == "$mod" ]] && rel=.
        out="$(cd "$mod" && go vet "$rel" 2>&1)" || { bad=1; fails+="$out"$'\n'; }
      done
      if ((bad)); then line+=" | go vet FAIL"; rc=1; else line+=" | go vet ${#gd[@]} pkg ok"; fi
    else line+=" | go vet skipped | no go"; fi
  fi

  # t-2178: the gate eval set. A project with tests/gate-cases/ runs it here, before any gate: a guard that stopped catching its recorded miss fails the close.
  local gcroot gc gcrc=0 gsum gskip
  gcroot="$(git rev-parse --show-toplevel 2>/dev/null)" || gcroot=""
  if [[ -n "$gcroot" && -d "$gcroot/tests/gate-cases" ]]; then
    gc="$(GATE_CASES_DIR="$gcroot/tests/gate-cases" "$SCRIPT_DIR/gate-cases.sh" run 2>&1)" || gcrc=$?
    gsum="$(sed -n 's/^gate cases: \([0-9]*\) of \([0-9]*\) pass.*/\1\/\2/p' <<<"$gc" | tail -n 1)"   # the summary is the last such line: a failing case's own output may print one
    gskip="$(sed -n 's/^gate cases: .*, \([0-9]*\) skipped$/\1/p' <<<"$gc" | tail -n 1)"
    [[ -z "$gskip" ]] || gsum+=" (${gskip} skipped)"
    if ((gcrc)); then line+=" | gate cases FAIL ${gsum:-?}"; fails+="$gc"$'\n'; rc=1; else line+=" | gate cases ${gsum:-?}"; fi
  fi

  # Advisory: dead code in changed files (declarations from them, references from every tracked file).
  local args=() scan dead="" ns=""
  while IFS= read -r f; do [[ -n "$f" ]] && args+=(--changed "$f"); done <<<"$files"
  if ((${#args[@]})); then
    scan="$("$SCRIPT_DIR/dead-code-scan.sh" "${args[@]}" 2>/dev/null)" || scan=""
    dead="$(awk -F'\t' '$1=="DEAD" { if (++n <= 8) l = l (l == "" ? "" : " ") $2 ":" $3 } END { if (n > 8) l = l " +" (n - 8) " more"; if (l != "") print l }' <<<"$scan")"
    ns="$(sed -n 's/^# not scanned: //p' <<<"$scan")"
  fi
  line+=" | dead code (advisory): ${dead:-none} | not scanned: ${ns:-none}"
  printf '%s\n' "$line"
  [[ -z "$fails" ]] || printf '%s' "$fails"
  return "$rc"
}

if [[ "${1-}" == --run ]]; then run_checks; exit $?; fi

id="${1-}"
[[ "$id" =~ ^t-[a-z0-9]{4}$ ]] || { echo "usage: pre-gate-check.sh <ticket-id>" >&2; exit 2; }
set +e; msg="$("$SCRIPT_DIR/evidence.sh" stamp "$id" pre-gate -- bash "$SCRIPT_DIR/pre-gate-check.sh" --run 2>&1)"; rc=$?; set -e
# 125 or 2 from evidence.sh itself (a refusal, a missing ticket): nothing was stamped, say why.
if [[ $rc -eq 125 || ( $rc -eq 2 && "$msg" != "evidence: wrote "* ) ]]; then printf '%s\n' "$msg" >&2; exit "$rc"; fi
# Show the stamped result: everything between the three header lines and the final `exit` line. The log's path is evidence.sh's to name (it honours
# CANON_TICKETS_DIR, so a land worktree or a plain clone with no .tickets/ of its own stamps into the project's): read it from its own line, never recompute it.
log="$(awk '/^evidence: wrote / { sub(/^evidence: wrote /, ""); sub(/ \(HEAD [^)]*\)$/, ""); print; exit }' <<<"$msg")"
if [[ -z "$log" || ! -f "$log" || ! -r "$log" ]]; then echo "pre-gate-check: stamped, but evidence.sh did not name a readable log: $msg" >&2; exit "$rc"; fi
sed -e '1,3d' -e '$d' "$log"
exit "$rc"
