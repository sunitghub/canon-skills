#!/usr/bin/env bash
# gate-cases.sh — t-2178: the gate eval set. Each time a close gate misses something (a script guard that let a bad state through, a
# reviewer or evaluator that said the wrong thing), the miss becomes a case in tests/gate-cases/<slug>/ so the same miss cannot return unseen.
#   gate-cases.sh add --gate guard|reviewer|evaluator --slug <name> --miss "<what went wrong>" [--source <ticket>]
#                     [--cmd "<command>" --expect-exit N --expect-text "<text>"] [--expect "<what the gate should have said>"] [--state <dir>]
#                     (a guard case with --cmd is run; a guard miss nothing catches yet has --expect instead and is recorded, to become a run case once a guard exists)
#   gate-cases.sh run [--json]    check every case: a `run` case (a script guard) in a scratch copy of its state/, a `recorded` case listed
#   gate-cases.sh ls              one line per case
# A case is case.md (frontmatter: gate, kind, miss, source, and for a run case cmd, expect_exit, expect_text; for a recorded case expect) plus an
# optional state/ folder (a state/setup.sh runs first, in the scratch copy). A guard case is `run`: the command runs offline with HOME, CANON_HOME and
# TMPDIR pinned inside the scratch folder and CANON_ROOT set to this repo; it passes when its exit code and its expected text both match. A reviewer or
# evaluator case is `recorded`: a model's answer differs from run to run (t-6387), so the miss is kept as data with what the gate should have said, and
# never run. `run` exits 1 when a run case fails or a case file is malformed. The cases folder is tests/gate-cases/ of the git repo you are in
# (GATE_CASES_DIR overrides it).
set -euo pipefail

_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$_SOURCE" ]; do
  _DIR="$(cd -P "$(dirname "$_SOURCE")" && pwd)"
  _SOURCE="$(readlink "$_SOURCE")"
  [[ "$_SOURCE" != /* ]] && _SOURCE="$_DIR/$_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_SOURCE")" && pwd)"
CANON_ROOT="${CANON_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

die() { echo "gate-cases: $*" >&2; exit 2; }

cases_dir() {
  if [[ -n "${GATE_CASES_DIR:-}" ]]; then printf '%s\n' "$GATE_CASES_DIR"; return; fi
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository (or set GATE_CASES_DIR)"
  printf '%s\n' "$root/tests/gate-cases"
}

# field <case.md> <key>: the value of `key: value` in the frontmatter (the lines between the first two `---`), empty when absent
field() {
  awk -v k="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }
  ' "$1"
}

# one_line <text>: a frontmatter value is one line; refuse anything else
one_line() { [[ "$2" != *$'\n'* && "$2" != *$'\r'* ]] || die "$1 must be one line"; }

cmd_add() {
  local gate="" slug="" miss="" source="" cmd="" ex_exit="" ex_text="" expect="" state=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gate) gate="${2-}"; shift 2 || die "--gate needs a value" ;;
      --slug) slug="${2-}"; shift 2 || die "--slug needs a value" ;;
      --miss) miss="${2-}"; shift 2 || die "--miss needs a value" ;;
      --source) source="${2-}"; shift 2 || die "--source needs a value" ;;
      --cmd) cmd="${2-}"; shift 2 || die "--cmd needs a value" ;;
      --expect-exit) ex_exit="${2-}"; shift 2 || die "--expect-exit needs a value" ;;
      --expect-text) ex_text="${2-}"; shift 2 || die "--expect-text needs a value" ;;
      --expect) expect="${2-}"; shift 2 || die "--expect needs a value" ;;
      --state) state="${2-}"; shift 2 || die "--state needs a value" ;;
      *) die "unknown option: $1" ;;
    esac
  done
  case "$gate" in guard|reviewer|evaluator) ;; *) die "--gate must be guard, reviewer or evaluator" ;; esac
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--slug must be lower-case letters, digits and hyphens"
  [[ -n "$miss" ]] || die "--miss is required: say in one line what the gate got wrong"
  [[ -z "$source" || "$source" =~ ^t-[a-z0-9]{4}$ ]] || die "--source must be a ticket id like t-1234"
  [[ -z "$ex_exit" || "$ex_exit" =~ ^[0-9]{1,3}$ ]] || die "--expect-exit must be a number"
  one_line --miss "$miss"; one_line --cmd "$cmd"; one_line --expect-text "$ex_text"; one_line --expect "$expect"
  local kind=recorded
  if [[ "$gate" == guard && -n "$cmd" ]]; then
    kind=run
    [[ -n "$ex_exit" || -n "$ex_text" ]] || die "a guard case with --cmd needs --expect-exit or --expect-text"
  elif [[ "$gate" == guard ]]; then
    [[ -n "$expect" ]] || die "a guard case needs --cmd (the command that must catch the miss), or --expect for a miss no guard catches yet (then it is recorded, not run)"
  else
    [[ -n "$expect" ]] || die "a $gate case needs --expect: what the gate should have said"
    [[ -z "$cmd" ]] || die "a $gate case is recorded, not run: --cmd belongs to a guard case"
  fi
  [[ -z "$state" || -d "$state" ]] || die "--state is not a folder: $state"
  local dir; dir="$(cases_dir)/$slug"
  [[ ! -e "$dir" ]] || die "case $slug already exists: $dir"
  mkdir -p "$dir"
  {
    printf -- '---\ngate: %s\nkind: %s\nmiss: %s\n' "$gate" "$kind" "$miss"
    [[ -z "$source" ]] || printf 'source: %s\n' "$source"
    if [[ "$kind" == run ]]; then
      printf 'cmd: %s\n' "$cmd"
      [[ -z "$ex_exit" ]] || printf 'expect_exit: %s\n' "$ex_exit"
      [[ -z "$ex_text" ]] || printf 'expect_text: %s\n' "$ex_text"
    else
      printf 'expect: %s\n' "$expect"
    fi
    printf -- '---\n'
  } > "$dir/case.md"
  if [[ -n "$state" ]]; then mkdir -p "$dir/state"; cp -R "$state"/. "$dir/state/"; fi
  echo "gate-cases: added $slug ($gate, $kind) → $dir"
}

# json_str <text>: a JSON string literal
json_str() { printf '%s' "$1" | awk 'BEGIN { ORS = ""; printf "\"" } { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, ""); if (NR > 1) printf "\\n"; printf "%s", $0 } END { printf "\"" }'; }

cmd_ls() {
  local d dir; dir="$(cases_dir)"
  [[ -d "$dir" ]] || { echo "gate cases: none (no $dir)"; return 0; }
  for d in "$dir"/*/; do
    [[ -f "${d}case.md" ]] || continue
    printf '%s  %s  %s  %s\n' "$(basename "$d")" "$(field "${d}case.md" gate)" "$(field "${d}case.md" kind)" "$(field "${d}case.md" miss)"
  done
}

cmd_run() {
  local json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in --json) json=true; shift ;; *) die "unknown option: $1" ;; esac
  done
  local dir; dir="$(cases_dir)"
  if [[ ! -d "$dir" ]]; then
    if $json; then echo '{"pass":0,"run":0,"recorded":0,"cases":[]}'; else echo "gate cases: none (no $dir)"; fi
    return 0
  fi
  local d slug gate kind miss cmd ex_exit ex_text tmp out rc why result pass=0 total=0 recorded=0 bad=0 items="" sep=""
  for d in "$dir"/*/; do
    [[ -f "${d}case.md" ]] || continue
    slug="$(basename "$d")"
    gate="$(field "${d}case.md" gate)"; kind="$(field "${d}case.md" kind)"; miss="$(field "${d}case.md" miss)"
    why=""; result=pass
    if [[ -z "$gate" || -z "$miss" || ( "$kind" != run && "$kind" != recorded ) ]]; then
      result=fail; why="malformed case.md: it needs gate, kind (run or recorded) and miss in its frontmatter"
    elif [[ "$kind" == recorded ]]; then
      result=recorded
      [[ -n "$(field "${d}case.md" expect)" ]] || { result=fail; why="malformed case.md: a recorded case needs expect"; }
    else
      cmd="$(field "${d}case.md" cmd)"; ex_exit="$(field "${d}case.md" expect_exit)"; ex_text="$(field "${d}case.md" expect_text)"
      if [[ -z "$cmd" || ( -z "$ex_exit" && -z "$ex_text" ) ]]; then
        result=fail; why="malformed case.md: a run case needs cmd and expect_exit or expect_text"
      else
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-case.XXXXXX")"
        mkdir -p "$tmp/work" "$tmp/home" "$tmp/canon-home" "$tmp/tmp"
        [[ ! -d "${d}state" ]] || cp -R "${d}state"/. "$tmp/work/"
        rc=0
        if [[ -f "$tmp/work/setup.sh" ]]; then
          out="$(cd "$tmp/work" && HOME="$tmp/home" CANON_HOME="$tmp/canon-home" TMPDIR="$tmp/tmp" CANON_ROOT="$CANON_ROOT" bash ./setup.sh 2>&1)" || rc=$?
          [[ "$rc" -eq 0 ]] || { result=fail; why="setup.sh failed (exit $rc): $out"; }
        fi
        if [[ "$result" == pass ]]; then
          rc=0
          out="$(cd "$tmp/work" && HOME="$tmp/home" CANON_HOME="$tmp/canon-home" TMPDIR="$tmp/tmp" CANON_ROOT="$CANON_ROOT" bash -c "$cmd" 2>&1)" || rc=$?
          if [[ -n "$ex_exit" && "$rc" != "$ex_exit" ]]; then result=fail; why="expected exit $ex_exit, got $rc"; fi
          if [[ -n "$ex_text" && "$out" != *"$ex_text"* ]]; then result=fail; why="${why:+$why; }expected the output to contain: $ex_text"; fi
          [[ "$result" == pass ]] || why="$why. Output: $(printf '%s' "$out" | tail -c 400)"
        fi
        case "$tmp" in "${TMPDIR:-/tmp}"/gate-case.*) rm -rf "$tmp" ;; esac
      fi
    fi
    case "$result" in
      recorded) recorded=$((recorded + 1)) ;;
      pass) total=$((total + 1)); pass=$((pass + 1)) ;;
      fail) total=$((total + 1)); bad=$((bad + 1)) ;;
    esac
    if $json; then
      items+="$sep{\"slug\":$(json_str "$slug"),\"gate\":$(json_str "$gate"),\"kind\":$(json_str "$kind"),\"result\":\"$result\",\"miss\":$(json_str "$miss")$([[ -z "$why" ]] || printf ',"why":%s' "$(json_str "$why")")}"; sep=","
    else
      case "$result" in
        pass) echo "  ok        $slug ($gate)" ;;
        recorded) echo "  recorded  $slug ($gate): $miss" ;;
        fail) echo "  FAIL      $slug ($gate): $why" ;;
      esac
    fi
  done
  if $json; then printf '{"pass":%d,"run":%d,"recorded":%d,"cases":[%s]}\n' "$pass" "$total" "$recorded" "$items"
  else echo "gate cases: $pass of $total pass, $recorded recorded"; fi
  [[ "$bad" -eq 0 ]]
}

sub="${1-}"
[[ $# -gt 0 ]] && shift
case "$sub" in
  add) cmd_add "$@" ;;
  run) cmd_run "$@" ;;
  ls) cmd_ls ;;
  *) echo "usage: gate-cases.sh add --gate guard|reviewer|evaluator --slug <name> --miss \"<text>\" [--source t-xxxx] [--cmd \"<cmd>\" --expect-exit N --expect-text \"<text>\"] [--expect \"<text>\"] [--state <dir>] | run [--json] | ls" >&2; exit 2 ;;
esac
