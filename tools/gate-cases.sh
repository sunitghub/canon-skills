#!/usr/bin/env bash
# gate-cases.sh — t-2178: the gate eval set. Each time a close gate misses something (a script guard that let a bad state through, a
# reviewer or evaluator that said the wrong thing), the miss becomes a case in tests/gate-cases/<slug>/ so the same miss cannot return unseen.
#   gate-cases.sh add --gate guard|reviewer|evaluator --slug <name> --miss "<what went wrong>" [--source <ticket>]
#                     [--cmd "<command>" --expect-exit N --expect-text "<text>" [--needs <tool>]] [--expect "<what the gate should have said>"] [--state <dir>]
#                     (a guard case with --cmd is run; a guard miss nothing catches yet has --expect instead and is recorded, to become a run case once a guard exists)
#   gate-cases.sh run [--json]    check every case: a `run` case (a script guard) in a scratch copy of its state/, a `recorded` case listed
#   gate-cases.sh ls              one line per case
#   gate-cases.sh replay <case>... --config split|folded [--runs N] [--model m] [--out f] --yes
#                     t-b809: re-run today's close gates on a past commit (a `replay` case) with `claude -p`, to score a gate change such as
#                     folding the reviewer into the evaluator. Spends money: without --yes it prints the call count and exits 2. One JSONL row
#                     per gate call (verdict, caught, leak, tokens, duration_ms, cost_usd); prompts in tools/gate-replay/. Never run by `run`.
#   gate-cases.sh replay --summary <results.jsonl>   per config and run: catches, the control's verdict, tokens and minutes per close
# A case is case.md (frontmatter: gate, kind, miss, source, and for a run case cmd, expect_exit, expect_text; for a recorded case expect; for a
# replay case ref (the commit the gate graded), base, ticket, fix (the commit that fixed the finding), catch (a regex for the finding; empty
# only with expect_verdict: pass, a clean control) and a state/ticket/ folder with the ticket's acceptance.md and plan.md as graded) plus an
# optional state/ folder (a state/setup.sh runs first, in the scratch copy). A run case may say `needs: <tool>`: where the tool is missing it is skipped, never failed. A guard case is `run`: the command runs in a clean environment (env -i: only PATH and
# the pinned HOME, CANON_HOME, TMPDIR, XDG_CONFIG_HOME, CANON_ROOT and a git config that reads nothing), so a caller's CANON_TICKETS_DIR or GIT_DIR cannot
# reach it; it passes when its exit code and its expected text both match, and `needs: <tool>` skips it where that tool is missing. A case should not need
# the network; nothing enforces that. A reviewer or
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
  local gate="" slug="" miss="" source="" cmd="" ex_exit="" ex_text="" expect="" state="" needs=""
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
      --needs) needs="${2-}"; shift 2 || die "--needs needs a value" ;;
      --state) state="${2-}"; shift 2 || die "--state needs a value" ;;
      *) die "unknown option: $1" ;;
    esac
  done
  case "$gate" in guard|reviewer|evaluator) ;; *) die "--gate must be guard, reviewer or evaluator" ;; esac
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--slug must be lower-case letters, digits and hyphens"
  [[ -n "$miss" ]] || die "--miss is required: say in one line what the gate got wrong"
  [[ -z "$source" || "$source" =~ ^t-[a-z0-9]{4}$ ]] || die "--source must be a ticket id like t-1234"
  [[ -z "$ex_exit" || ( "$ex_exit" =~ ^[0-9]{1,3}$ && "$ex_exit" -le 255 ) ]] || die "--expect-exit must be a number from 0 to 255"
  [[ -z "$needs" || "$needs" =~ ^[A-Za-z0-9._+-]+$ ]] || die "--needs must be one command name"
  one_line --miss "$miss"; one_line --cmd "$cmd"; one_line --expect-text "$ex_text"; one_line --expect "$expect"
  local kind=recorded
  if [[ "$gate" == guard && -n "$cmd" ]]; then
    kind=run
    [[ -n "$ex_exit" || -n "$ex_text" ]] || die "a guard case with --cmd needs --expect-exit or --expect-text"
    [[ -z "$expect" ]] || die "--expect belongs to a recorded case; a run case has --expect-exit and --expect-text"
  elif [[ "$gate" == guard ]]; then
    [[ -n "$expect" ]] || die "a guard case needs --cmd (the command that must catch the miss), or --expect for a miss no guard catches yet (then it is recorded, not run)"
  else
    [[ -n "$expect" ]] || die "a $gate case needs --expect: what the gate should have said"
    [[ -z "$cmd" ]] || die "a $gate case is recorded, not run: --cmd belongs to a guard case"
  fi
  [[ -z "$needs" || "$kind" == run ]] || die "--needs belongs to a run case"
  [[ -z "$state" || -d "$state" ]] || die "--state is not a folder: $state"
  local dir; dir="$(cases_dir)/$slug"
  [[ ! -e "$dir" ]] || die "case $slug already exists: $dir"
  mkdir -p "$dir"
  {
    printf -- '---\ngate: %s\nkind: %s\nmiss: %s\n' "$gate" "$kind" "$miss"
    [[ -z "$source" ]] || printf 'source: %s\n' "$source"
    if [[ "$kind" == run ]]; then
      [[ -z "$needs" ]] || printf 'needs: %s\n' "$needs"
      printf 'cmd: %s\n' "$cmd"
      [[ -z "$ex_exit" ]] || printf 'expect_exit: %s\n' "$ex_exit"
      [[ -z "$ex_text" ]] || printf 'expect_text: %s\n' "$ex_text"
    else
      printf 'expect: %s\n' "$expect"
    fi
    printf -- '---\n'
  } > "$dir/case.md"
  if [[ -n "$state" ]]; then mkdir -p "$dir/state"; cp -R "$state"/. "$dir/state/" || { rm -rf "$dir"; die "could not copy --state: nothing was added"; }; fi
  echo "gate-cases: added $slug ($gate, $kind) → $dir"
}

# json_str <text>: a JSON string literal
json_str() { printf '%s' "$1" | tr '\001-\011\013-\037\177' ' ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN { ORS = ""; printf "\"" } NR > 1 { printf "\\n" } { printf "%s", $0 } END { printf "\"" }'; }

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
    if $json; then echo '{"pass":0,"run":0,"recorded":0,"replay":0,"skipped":0,"cases":[]}'; else echo "gate cases: none (no $dir)"; fi
    return 0
  fi
  local d slug gate kind miss cmd ex_exit ex_text needs tmp out rc why result pass=0 total=0 recorded=0 replay=0 skipped=0 bad=0 items="" sep="" cleanenv=()
  for d in "$dir"/*/; do
    [[ -f "${d}case.md" ]] || continue
    slug="$(basename "$d")"
    gate="$(field "${d}case.md" gate)"; kind="$(field "${d}case.md" kind)"; miss="$(field "${d}case.md" miss)"
    why=""; result=pass
    if [[ -z "$gate" || -z "$miss" || ( "$kind" != run && "$kind" != recorded && "$kind" != replay ) ]]; then
      result=fail; why="malformed case.md: it needs gate, kind (run, recorded or replay) and miss in its frontmatter"
    elif [[ "$kind" == replay ]]; then
      # t-b809: a replay case spends claude -p calls, so it runs only through `replay --yes`, never here (pre-gate runs this at every close)
      result=replay; why="$(replay_problem "${d}case.md")"
      [[ -z "$why" ]] || { result=fail; why="malformed case.md: $why"; }
    elif [[ "$kind" == recorded ]]; then
      result=recorded
      [[ -n "$(field "${d}case.md" expect)" ]] || { result=fail; why="malformed case.md: a recorded case needs expect"; }
    else
      needs="$(field "${d}case.md" needs)"
      cmd="$(field "${d}case.md" cmd)"; ex_exit="$(field "${d}case.md" expect_exit)"; ex_text="$(field "${d}case.md" expect_text)"
      if [[ -z "$cmd" || ( -z "$ex_exit" && -z "$ex_text" ) ]]; then
        result=fail; why="malformed case.md: a run case needs cmd and expect_exit or expect_text"
      else
        if [[ -n "$needs" ]] && ! command -v "$needs" >/dev/null 2>&1; then
          result=skipped; why="needs $needs, which is not installed"
        fi
      fi
      if [[ "$result" == pass && -n "$cmd" && ( -n "$ex_exit" || -n "$ex_text" ) ]]; then
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-case.XXXXXX")"
        mkdir -p "$tmp/work" "$tmp/home" "$tmp/canon-home" "$tmp/tmp"
        [[ ! -d "${d}state" ]] || cp -R "${d}state"/. "$tmp/work/"
        # env -i: a caller's CANON_TICKETS_DIR, GIT_DIR, COCKPIT_* or CLAUDE_* never reaches a case (it could write into the caller's tickets or repo)
        cleanenv=(env -i PATH="$PATH" HOME="$tmp/home" CANON_HOME="$tmp/canon-home" TMPDIR="$tmp/tmp" XDG_CONFIG_HOME="$tmp/xdg" CANON_ROOT="$CANON_ROOT" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C)
        rc=0
        if [[ -f "$tmp/work/setup.sh" ]]; then
          out="$(cd "$tmp/work" && "${cleanenv[@]}" bash ./setup.sh 2>&1)" || rc=$?
          [[ "$rc" -eq 0 ]] || { result=fail; why="setup.sh failed (exit $rc): $out"; }
        fi
        if [[ "$result" == pass ]]; then
          rc=0
          out="$(cd "$tmp/work" && "${cleanenv[@]}" bash -c "$cmd" 2>&1)" || rc=$?
          if [[ -n "$ex_exit" && "$rc" != "$ex_exit" ]]; then result=fail; why="expected exit $ex_exit, got $rc"; fi
          if [[ -n "$ex_text" && "$out" != *"$ex_text"* ]]; then result=fail; why="${why:+$why; }expected the output to contain: $ex_text"; fi
          [[ "$result" == pass ]] || why="$why. Output: $(printf '%s' "$out" | tail -c 400)"
        fi
        case "$tmp" in "${TMPDIR:-/tmp}"/gate-case.*) rm -rf "$tmp" ;; esac
      fi
    fi
    case "$result" in
      recorded) recorded=$((recorded + 1)) ;;
      replay) replay=$((replay + 1)) ;;
      skipped) skipped=$((skipped + 1)) ;;
      pass) total=$((total + 1)); pass=$((pass + 1)) ;;
      fail) total=$((total + 1)); bad=$((bad + 1)) ;;
    esac
    if $json; then
      items+="$sep{\"slug\":$(json_str "$slug"),\"gate\":$(json_str "$gate"),\"kind\":$(json_str "$kind"),\"result\":\"$result\",\"miss\":$(json_str "$miss")$([[ -z "$why" ]] || printf ',"why":%s' "$(json_str "$why")")}"; sep=","
    else
      case "$result" in
        pass) echo "  ok        $slug ($gate)" ;;
        recorded) echo "  recorded  $slug ($gate): $miss" ;;
        replay) echo "  replay    $slug ($gate): $miss" ;;
        skipped) echo "  skipped   $slug ($gate): $why" ;;
        fail) echo "  FAIL      $slug ($gate): $why" ;;
      esac
    fi
  done
  if $json; then printf '{"pass":%d,"run":%d,"recorded":%d,"replay":%d,"skipped":%d,"cases":[%s]}\n' "$pass" "$total" "$recorded" "$replay" "$skipped" "$items"
  else echo "gate cases: $pass of $total pass, $recorded recorded$([[ "$replay" -eq 0 ]] || printf ', %d replay' "$replay")$([[ "$skipped" -eq 0 ]] || printf ', %d skipped' "$skipped")"; fi
  [[ "$bad" -eq 0 ]]
}

# replay_problem <case.md>: why a replay case is malformed (one line), or nothing
replay_problem() {
  local f="$1" k rc=0
  for k in ref base ticket; do [[ -n "$(field "$f" "$k")" ]] || { echo "a replay case needs $k"; return; }; done
  [[ "$(field "$f" ticket)" =~ ^t-[a-z0-9]{4}$ ]] || { echo "ticket must be a ticket id like t-1234"; return; }
  local catch; catch="$(field "$f" catch)"
  if [[ -z "$catch" ]]; then
    [[ "$(field "$f" expect_verdict)" == pass ]] || echo "a replay case needs catch (it may be empty only with expect_verdict: pass)"
    return
  fi
  [[ "$(field "$f" fix)" =~ ^[0-9a-f]{7,40}$ ]] || { echo "a replay case needs fix (the commit that fixed the finding, 7 to 40 hex digits)"; return; }
  printf '' | grep -qiE -- "$catch" 2>/dev/null || rc=$?
  [[ "$rc" -le 1 ]] || echo "catch is not a valid regex: $catch"
}

# triage_text <bucket section heading or empty>: from a report on stdin, the text of its Act On and Consider buckets. With a heading
# (the folded report's `## Reviewer findings (advisory)`) only that section is read; without one, the `## Triage` section.
triage_text() {
  awk -v sec="${1:-## Triage}" '
    index($0, sec) == 1 { on = 1; keep = (sec != "## Triage"); next }
    on && /^## / { on = 0 }
    !on { next }
    { line = $0; sub(/^[^A-Za-z]*/, "", line) }
    line ~ /^(Act On|Consider)([^A-Za-z]|$)/ { keep = 1 }
    line ~ /^(Noted|Dismissed)([^A-Za-z]|$)/ { keep = 0 }
    keep { print }
  '
}

# replay_verdict <gate> <report file>: pass, fail or none
replay_verdict() {
  local v
  if [[ "$1" == reviewer ]]; then
    v="$(grep -oE '^[^A-Za-z]*(YES|NO)([^A-Za-z]|$)' "$2" | tail -n 1 | grep -oE 'YES|NO')" || v=""
    case "$v" in YES) echo pass ;; NO) echo fail ;; *) echo none ;; esac
  else
    v="$(grep -oE '^(pass|fail):' "$2" | head -n 1)" || v=""
    case "$v" in pass:) echo pass ;; fail:) echo fail ;; *) echo none ;; esac
  fi
}

# replay_call <gate> <prompt file> → sets R_VERDICT R_CAUGHT R_LEAK R_TOKENS R_MS R_COST R_ERR and writes the reply to $R_REPORT.
# Runs in $R_WT with the pinned env; killed by its own PID after GATE_REPLAY_TIMEOUT seconds (default 1800).
replay_call() {
  local gate="$1" prompt agent out err pid waited=0 limit="${GATE_REPLAY_TIMEOUT:-1800}" rc=0 parsed
  prompt="$(sed -e "s|{{ID}}|$R_ID|g" -e "s|{{BASE}}|$R_BASE|g" -e "s|{{REF}}|$CANON_ROOT/skills/sprint/reference|g" "$2")"
  case "$gate" in reviewer) agent=canon-reviewer ;; *) agent=canon-evaluator ;; esac
  out="$R_TMP/out.json"; err="$R_TMP/err.txt"
  R_VERDICT=none R_CAUGHT=false R_LEAK=false R_TOKENS=0 R_MS=0 R_COST=0 R_ERR=""
  # HOME stays real so claude keeps its login; canon's own state, temp and config go to scratch. A live gate-scope record (made in
  # cmd_replay, as gate-snapshot.sh pre does at a real close) makes canon update, skills.sh and uninstall refuse the real home.
  # Bash is allowed as at a real close (t-b809: without it the evaluator grades everything not-run and fails a clean control).
  ( cd "$R_WT" && exec env CANON_HOME="$R_TMP/canon-home" TMPDIR="$R_TMP/tmp" XDG_CONFIG_HOME="$R_TMP/xdg" CANON_GATE_SCOPE_DIR="$R_TMP/scope" \
      CANON_TICKETS_DIR="$R_WT/.tickets" claude -p "$prompt" --agent "$agent" --model "$R_MODEL" --output-format json \
      --permission-mode dontAsk --add-dir "$CANON_ROOT/skills/sprint/reference" \
      --allowedTools Bash Read Grep Glob LS --disallowedTools Write Edit NotebookEdit ) >"$out" 2>"$err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= limit )); then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; R_VERDICT=error; R_ERR="timeout after ${limit}s"; return 0; fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid" || rc=$?
  if (( rc != 0 )); then R_VERDICT=error; R_ERR="claude exited $rc: $(tail -c 300 "$err")"; return 0; fi
  parsed="$("$R_BOARD" headless-json < "$out")"
  if [[ "$(cut -f1 <<<"$parsed")" != False ]]; then R_VERDICT=error; R_ERR="claude reported an error: $(head -c 300 "$out")"; return 0; fi
  cut -f3- <<<"$parsed" | tr '\002' '\n' > "$R_REPORT"
  parsed="$("$R_BOARD" headless-usage < "$out")"
  if [[ "$(cut -f1 <<<"$parsed")" == PARSE_ERROR ]]; then R_VERDICT=error; R_ERR="no usage in claude's reply"; return 0; fi
  R_TOKENS="$(cut -f1 <<<"$parsed")"; R_MS="$(cut -f2 <<<"$parsed")"; R_COST="$(cut -f3 <<<"$parsed")"
  R_VERDICT="$(replay_verdict "$gate" "$R_REPORT")"
  if [[ -n "$R_CATCH" ]]; then
    case "$gate" in
      reviewer) triage_text < "$R_REPORT" | grep -qiE -- "$R_CATCH" && R_CAUGHT=true ;;
      folded) triage_text '## Reviewer findings (advisory)' < "$R_REPORT" | grep -qiE -- "$R_CATCH" && R_CAUGHT=true ;;
    esac
    if [[ "$gate" != reviewer && "$R_VERDICT" == fail ]] && grep -qiE -- "$R_CATCH" "$R_REPORT"; then R_CAUGHT=true; fi
  fi
  [[ -z "$R_FIX" ]] || ! grep -qi -- "${R_FIX:0:7}" "$R_REPORT" || R_LEAK=true
  return 0
}

replay_row() {  # one JSONL row for the current call
  printf '{"case":%s,"kind":"%s","config":"%s","run":%d,"gate":"%s","model":%s,"verdict":"%s","caught":%s,"leak":%s,"tokens":%d,"duration_ms":%d,"cost_usd":%s,"report":%s%s}\n' \
    "$(json_str "$R_SLUG")" "$R_KIND" "$R_CONFIG" "$R_RUN" "$1" "$(json_str "$R_MODEL")" "$R_VERDICT" "$R_CAUGHT" "$R_LEAK" "$R_TOKENS" "$R_MS" "$R_COST" \
    "$(json_str "$R_REPORT")" "$([[ -z "$R_ERR" ]] || printf ',"error":%s' "$(json_str "$R_ERR")")" >> "$R_OUT"
}

repo_print() { git -C "$R_ROOT" rev-parse HEAD; git -C "$R_ROOT" symbolic-ref -q HEAD || true; git -C "$R_ROOT" status --porcelain; }

R_TMP=""
replay_cleanup() {
  [[ -n "$R_TMP" ]] || return 0
  CANON_GATE_SCOPE_DIR="$R_TMP/scope" gate_scope_remove "$R_TMP/snap" || true
  [[ ! -d "$R_TMP/wt" ]] || git -C "$R_ROOT" worktree remove --force "$R_TMP/wt" >/dev/null 2>&1 || true
  case "$R_TMP" in "${R_TMPBASE}"/gate-replay.*) rm -rf "$R_TMP" ;; esac
  R_TMP=""
}

# replay --summary <jsonl>: per config and run, catches out of expected, the control's verdict, leaks, and tokens and minutes per close
replay_summary() {
  [[ -f "$1" ]] || die "no results file: $1"
  awk '
    function v(k,   m) { if (match($0, "\"" k "\":(\"[^\"]*\"|[^,}]*)")) { m = substr($0, RSTART + length(k) + 3, RLENGTH - length(k) - 3); gsub(/"/, "", m); return m } return "" }
    function med(s,   a, n, i, j, t) { n = split(s, a, " "); for (i = 2; i <= n; i++) for (j = i; j > 1 && a[j-1] + 0 > a[j] + 0; j--) { t = a[j]; a[j] = a[j-1]; a[j-1] = t }
      return n == 0 ? 0 : (n % 2 ? a[(n+1)/2] : (a[n/2] + a[n/2+1]) / 2) }
    {
      c = v("config"); r = v("run"); k = c SUBSEP r; cr = k SUBSEP v("case")
      if (!(k in seen)) { seen[k] = 1; order[++no] = k }
      if (!(cr in cs)) { cs[cr] = 1; ckeys[k] = ckeys[k] " " v("case"); kind[cr] = v("kind") }
      tok[cr] += v("tokens"); ms[cr] += v("duration_ms")
      if (v("caught") == "true") caught[cr] = 1
      if (v("leak") == "true") leak[k]++
      if (v("verdict") == "error") err[k]++
      if (v("kind") == "control" && (v("gate") == "evaluator" || v("gate") == "folded")) ctl[k] = ctl[k] (ctl[k] == "" ? "" : ",") v("verdict")
    }
    END {
      printf "%-7s %-3s %-9s %-8s %-5s %-6s %-12s %-12s %-9s\n", "config", "run", "caught", "control", "leaks", "errors", "tok/close", "tok total", "min/close"
      for (i = 1; i <= no; i++) {
        k = order[i]; split(k, kk, SUBSEP); n = split(ckeys[k], cl, " "); got = 0; ex = 0; ts = ""; mss = ""; tt = 0
        for (j = 1; j <= n; j++) { cr = k SUBSEP cl[j]; if (kind[cr] == "defect") { ex++; if (cr in caught) got++ } ts = ts " " tok[cr]; mss = mss " " ms[cr]; tt += tok[cr] }
        printf "%-7s %-3s %-9s %-8s %-5d %-6d %-12d %-12d %-9.1f\n", kk[1], kk[2], got "/" ex, (ctl[k] == "" ? "-" : ctl[k]), leak[k], err[k], med(ts), tt, med(mss) / 60000
      }
      for (cr in cs) { split(cr, p, SUBSEP); if (kind[cr] == "defect") printf "case %s %s run %s: %s\n", p[3], p[1], p[2], ((cr in caught) ? "caught" : "missed") | "sort" }
    }' "$1"
}

cmd_replay() {
  local config="" runs=1 yes=false out="" slugs=() s
  R_MODEL="claude-sonnet-5-5"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --summary) [[ $# -eq 2 ]] || die "usage: replay --summary <results.jsonl>"; replay_summary "$2"; return ;;
      --config) config="${2-}"; shift 2 || die "--config needs a value" ;;
      --runs) runs="${2-}"; shift 2 || die "--runs needs a value" ;;
      --model) R_MODEL="${2-}"; shift 2 || die "--model needs a value" ;;
      --out) out="${2-}"; shift 2 || die "--out needs a value" ;;
      --yes) yes=true; shift ;;
      -*) die "unknown option: $1" ;;
      *) slugs+=("$1"); shift ;;
    esac
  done
  case "$config" in split|folded) ;; *) die "--config must be split or folded" ;; esac
  [[ "$runs" =~ ^[1-9][0-9]?$ ]] || die "--runs must be a number from 1 to 99"
  [[ "$R_MODEL" =~ ^[A-Za-z0-9._-]+$ ]] || die "--model must be a model id or alias"
  ((${#slugs[@]})) || die "name at least one replay case"
  local dir; dir="$(cases_dir)"
  for s in "${slugs[@]}"; do
    [[ -f "$dir/$s/case.md" && "$(field "$dir/$s/case.md" kind)" == replay ]] || die "not a replay case: $s"
    local why; why="$(replay_problem "$dir/$s/case.md")"; [[ -z "$why" ]] || die "$s: malformed case.md: $why"
  done
  local per=1; [[ "$config" == split ]] && per=2
  local calls=$(( ${#slugs[@]} * runs * per ))
  if ! $yes; then
    echo "gate-cases: replay would make $calls claude -p calls (${#slugs[@]} case(s) × $runs run(s) × $per gate(s), model $R_MODEL) plus one auth probe; nothing was run. Add --yes to spend them." >&2
    exit 2
  fi
  command -v claude >/dev/null 2>&1 || die "claude is not on PATH"
  source "$SCRIPT_DIR/platform-lib.sh"
  R_BOARD="$(board_helper_bin)" || exit 2
  "$R_BOARD" --help 2>/dev/null | grep -q headless-usage || die "the board binary has no headless-usage; build or update it"
  R_ROOT="$(git -C "$dir" rev-parse --show-toplevel)"
  R_TMPBASE="${TMPDIR:-/tmp}"; R_TMPBASE="${R_TMPBASE%/}"
  if [[ -z "$out" ]]; then out="$(mktemp -d "$R_TMPBASE/gate-replay-out.XXXXXX")/replay.jsonl"; fi
  R_OUT="$out"; mkdir -p "$(dirname "$R_OUT")" "${R_OUT%.jsonl}-reports"
  if ! claude -p "Reply with exactly: ok" --model haiku --output-format json >/dev/null 2>&1; then
    echo "gate-cases: claude -p did not answer (not logged in?); no case was run" >&2; exit 2
  fi
  git -C "$R_ROOT" worktree prune
  source "$SCRIPT_DIR/gate-scope-lib.sh"
  R_PRINT="$(repo_print)"
  trap replay_cleanup EXIT
  trap 'replay_cleanup; exit 130' INT TERM
  local failed=0 run gate gates
  if [[ "$config" == split ]]; then gates="reviewer evaluator"; else gates="folded"; fi
  R_CONFIG="$config"
  for s in "${slugs[@]}"; do
    R_SLUG="$s"; R_ID="$(field "$dir/$s/case.md" ticket)"; R_BASE="$(field "$dir/$s/case.md" base)"
    R_CATCH="$(field "$dir/$s/case.md" catch)"; R_FIX="$(field "$dir/$s/case.md" fix)"
    if [[ -n "$R_CATCH" ]]; then R_KIND=defect; else R_KIND=control; fi
    for ((run = 1; run <= runs; run++)); do
      R_RUN="$run"; R_ERR=""; R_VERDICT=none R_CAUGHT=false R_LEAK=false R_TOKENS=0 R_MS=0 R_COST=0 R_REPORT=""
      local ref; ref="$(field "$dir/$s/case.md" ref)"
      if ! git -C "$R_ROOT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || ! git -C "$R_ROOT" rev-parse --verify --quiet "$R_BASE^{commit}" >/dev/null; then
        R_VERDICT=error; R_ERR="ref $ref or base $R_BASE does not resolve"; replay_row "-"; failed=1; continue
      fi
      R_TMP="$(mktemp -d "$R_TMPBASE/gate-replay.XXXXXX")"
      mkdir -p "$R_TMP/canon-home" "$R_TMP/tmp" "$R_TMP/xdg" "$R_TMP/scope"
      CANON_GATE_SCOPE_DIR="$R_TMP/scope" gate_scope_create "$R_TMP/snap" >/dev/null || die "could not register the gate scope in $R_TMP/scope"
      git -C "$R_ROOT" worktree add --detach --quiet "$R_TMP/wt" "$ref"
      R_WT="$R_TMP/wt"
      mkdir -p "$R_WT/.tickets/$R_ID" "$R_WT/.claude"
      cp -R "$dir/$s/state/ticket"/. "$R_WT/.tickets/$R_ID/"
      [[ -e "$R_WT/.claude/agents" ]] || ln -s "$CANON_ROOT/agents" "$R_WT/.claude/agents"
      for gate in $gates; do
        R_REPORT="${R_OUT%.jsonl}-reports/$s-$config-$run-$gate.md"
        replay_call "$gate" "$SCRIPT_DIR/gate-replay/$gate.md"
        # as gate-snapshot.sh post does at a real close: a gate that changed the real checkout stops the whole replay
        if [[ "$(repo_print)" != "$R_PRINT" ]]; then R_VERDICT=error; R_ERR="the gate changed the real checkout $R_ROOT (git status, HEAD or branch); replay stopped"; fi
        [[ "$R_VERDICT" != error ]] || failed=1
        replay_row "$gate"
        echo "gate-cases: $s $config run $run $gate: $R_VERDICT, caught $R_CAUGHT, $R_TOKENS tokens${R_ERR:+ ($R_ERR)}" >&2
        [[ "$R_ERR" != *"replay stopped" ]] || { echo "gate-cases: results in $R_OUT"; exit 1; }
      done
      replay_cleanup
    done
  done
  echo "gate-cases: results in $R_OUT"
  return "$failed"
}

sub="${1-}"
[[ $# -gt 0 ]] && shift
case "$sub" in
  add) cmd_add "$@" ;;
  run) cmd_run "$@" ;;
  ls) cmd_ls ;;
  replay) cmd_replay "$@" ;;
  *) echo "usage: gate-cases.sh add --gate guard|reviewer|evaluator --slug <name> --miss \"<text>\" [--source t-xxxx] [--cmd \"<cmd>\" --expect-exit N --expect-text \"<text>\"] [--expect \"<text>\"] [--state <dir>] | run [--json] | ls | replay <case>... --config split|folded [--runs N] [--model m] [--out f] --yes | replay --summary <results.jsonl>" >&2; exit 2 ;;
esac
