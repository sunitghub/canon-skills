#!/usr/bin/env bash
# run.sh — t-e85f: one run of the canon-vs-plain bench. Builds the to-do app of step-1.md .. step-3.md with `claude -p` (Sonnet 5.5),
# either plain (an empty git repo, no canon on PATH, no user CLAUDE.md) or canon (the sprint skill from a scratch clone of this
# repo, all model tiers pinned to Sonnet, one `sprint start` .. `sprint complete` per step), and appends one TSV row per step.
#   bench/vs-plain/run.sh <plain|canon> <run-number> [--steps N] [--results FILE]
# Sessions write only a fresh project per step and the session folder (BENCH_WORK, else mktemp -d: the canon clone used as CANON_HOME
# and its temp folder); everything run.sh itself runs or writes after a session is in the host folder (BENCH_HOST, else
# /tmp/canon-bench-host.*, which also holds the projects), which no session can write. The user's state is fingerprinted around each session and a change marks the row
# `contaminated`, as does a transcript that reads the hidden tests. Step 3 starts both arms from baseline-3/. The hidden tests run
# from outside the project after the session, the app under sandbox-exec. BENCH_CLAUDE overrides the claude binary (the test's stub),
# BENCH_PROJECTS the projects' root, BENCH_MAX_USD caps one session (default 5). It spends money: README.md says what a run costs.
set -euo pipefail

BENCH="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(git -C "$BENCH" rev-parse --show-toplevel)"
usage() { echo "usage: bench/vs-plain/run.sh <plain|canon> <run-number> [--steps 1-3] [--results FILE]" >&2; exit 2; }

arm="${1:-}"; run="${2:-}"; shift 2 2>/dev/null || usage
[[ "$arm" == plain || "$arm" == canon ]] || usage
[[ "$run" =~ ^[0-9]+$ ]] || usage
steps=3; results="$BENCH/results/results.tsv"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --steps) steps="${2:-}"; [[ "$steps" =~ ^[1-3]$ ]] || usage; shift 2 ;;
    --results) results="${2:-}"; [[ -n "$results" ]] || usage; shift 2 ;;
    *) usage ;;
  esac
done
CLAUDE_BIN="${BENCH_CLAUDE:-claude}"
MODEL=claude-sonnet-5-5
command -v node >/dev/null || { echo "run.sh: needs node" >&2; exit 1; }
command -v "$CLAUDE_BIN" >/dev/null || { echo "run.sh: no claude binary ($CLAUDE_BIN)" >&2; exit 1; }

# Two roots. W is what sessions may write (the canon clone used as CANON_HOME, the session TMPDIR); each step's project is its own
# fresh mktemp -d. H is the host's own: the clean canon clone run.sh runs canon from, the setup HOME, the reference app, the session
# output and logs, the scoring folder, the projects. It sits in /tmp, outside canon's repo (whose CLAUDE.md a project below it would load)
# and every folder a session may write,
# so a session can neither plant code that run.sh runs nor redirect a write run.sh makes (a symlink at an output path).
W="${BENCH_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/canon-bench.XXXXXX")}"; mkdir -p "$W"; W="$(cd -P "$W" && pwd -P)"
H="${BENCH_HOST:-$(mktemp -d /tmp/canon-bench-host.XXXXXX)}"; mkdir -p "$H"; H="$(cd -P "$H" && pwd -P)"
# git that run.sh runs in a folder a session wrote: no fsmonitor or hook from that repo's own config can run (env config wins over it)
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1=/dev/null GIT_CONFIG_KEY_2=commit.gpgsign GIT_CONFIG_VALUE_2=false
NODE="$(node -p process.execPath)"   # the real binary: the scoring sandbox lets only it start
command -v sandbox-exec >/dev/null || { echo "run.sh: scoring runs the session's app under macOS sandbox-exec, which is missing" >&2; exit 1; }
commit="$(git -C "$REPO" rev-parse --short=12 HEAD)"
mkdir -p "$(dirname "$results")"
HEADER=$'date\tarm\trun\tstep\tstatus\treason\tcommit\tmodel\tentry\tcost_usd\tinput_tokens\toutput_tokens\tcache_read\tcache_write\tminutes\tturns\tpassed\ttotal\tplanning\timplementation\tgates\tgate_runs\tsession'
[[ -s "$results" ]] || printf '%s\n' "$HEADER" > "$results"

# A PATH with no canon on it: every folder holding a sprint or tkt is dropped (the plain arm, and the canon arm's base).
clean_path() {
  local out="" d IFS=:
  for d in $PATH; do
    [[ -n "$d" && ! -x "$d/sprint" && ! -x "$d/tkt" ]] && out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}
BASE_PATH="$(clean_path)"

# No bypass mode: every Bash command runs in Claude Code's sandbox, which writes only to the project, Claude's own folders and the
# allowWrite list: W, which holds the session's TMPDIR (canon's mktemp stays inside it since t-7ab9, 0.73.1; before, the dry run's sprint
# stopped at `sprint approve`). A write into HOME is refused (probed 2026-11-21). An unsandboxed
# retry is refused, and Edit/Write stay in the project (acceptEdits). Same for both arms.
mkdir -p "$W/tmp"
sandbox_for() { node -e 'console.log(JSON.stringify({ sandbox: { enabled: true, autoAllowBashIfSandboxed: true, allowUnsandboxedCommands: false, filesystem: { allowWrite: process.argv.slice(1).filter(Boolean) } } }))' "$1" "$W"; }

# The user's state a session must not touch: canon's project list and Cockpit files under the real HOME.
fingerprint() {
  local f
  for f in "$HOME/.config/canon/projects" "$HOME/.canon/cockpit/projects.json" "$HOME/.canon/cockpit/model-tiers.json"; do
    if [[ -f "$f" ]]; then cksum < "$f"; else echo none; fi
  done
}

# Canon's install for this run: a clone at HEAD, its prebuilt canon-go copied in, every model tier pinned to Sonnet. CH is the session's
# CANON_HOME, writable by it (canon writes its events there). HC, in H, is the clone every canon command run.sh itself runs comes from.
CH="$W/canon"
HC="$H/canon"
clone_canon() {
  git clone -q --no-hardlinks "$REPO" "$1"
  git -C "$1" checkout -q --detach "$commit"
  if [[ -x "$REPO/tools/canon-go-bin/canon-go" ]]; then mkdir -p "$1/tools/canon-go-bin"; cp "$REPO/tools/canon-go-bin/canon-go" "$1/tools/canon-go-bin/"; fi
}
if [[ "$arm" == canon && ! -d "$CH" ]]; then
  clone_canon "$CH"
  [[ -d "$HC/.git" ]] || clone_canon "$HC"
  mkdir -p "$CH/cockpit"
  node -e '
    const fs = require("fs"); const [seed, out, model] = process.argv.slice(1);
    const d = JSON.parse(fs.readFileSync(seed, "utf8"));
    for (const step of Object.keys(d.defaults)) if (d.defaults[step].claude) d.defaults[step].claude = model;
    fs.writeFileSync(out, JSON.stringify(d, null, 2) + "\n");' "$CH/tools/sprint-check-app/model-tiers.json" "$CH/cockpit/model-tiers.json" "$MODEL"
fi

# new_project <dir> [<seed folder>]: a fresh git repo (the seed's files committed); for canon, the sprint skill added and committed.
new_project() {
  local p="$1" seed="${2:-}"
  mkdir -p "$p"
  git -C "$p" init -q -b main
  git -C "$p" config user.name bench; git -C "$p" config user.email bench@example.invalid
  [[ -z "$seed" ]] || cp -R "$seed"/. "$p"/
  if [[ "$arm" == canon ]]; then
    mkdir -p "$H/setup-home"
    (cd "$p" && HOME="$H/setup-home" XDG_CONFIG_HOME="$H/setup-home/.config" CANON_HOME="$CH" PATH="$HC/tools:$BASE_PATH" \
      "$HC/tools/skills.sh" add sprint </dev/null >"$H/skills-add.log" 2>&1) \
      || { echo "run.sh: skills.sh add sprint failed, see $H/skills-add.log" >&2; exit 1; }
  fi
  git -C "$p" add -A
  git -C "$p" commit -q --allow-empty -m "chore: start"
}

# canon_changed: 0 when any file the clean clone tracks differs in CH (content, or a symlink's target), read without git in CH
canon_changed() {
  local f
  while IFS= read -r -d '' f; do
    if [[ -L "$HC/$f" ]]; then
      [[ -L "$CH/$f" && "$(readlink "$HC/$f")" == "$(readlink "$CH/$f")" ]] || return 0
    else
      [[ ! -L "$CH/$f" ]] && cmp -s "$HC/$f" "$CH/$f" || return 0
    fi
  done < <(git -C "$HC" ls-files -z)
  return 1
}

prompt_for() {
  local spec; spec="$(cat "$BENCH/step-$1.md")"
  if [[ "$arm" == plain ]]; then
    printf '%s\n\nWork only inside this folder. Commit your work to main when done. Never push.\n' "$spec"
  else
    printf '%s\n' "Use canon's sprint workflow for this request: run \`sprint start\`, fill in acceptance.md and plan.md, and run the spec check." \
      "The plan is approved in advance: run \`sprint approve <id>\` and build it." \
      "Then close it with \`sprint complete\` and every gate it asks for; the close confirmation is also given in advance." \
      "Commit your work and merge it to main locally. Never push. Work only inside this folder." "" "Request:" "" "$spec"
  fi
}

# One step's score: the hidden tests for steps 1..N run against the project from outside it. total is fixed by the reference app
# (baseline-3 with its plant fixed), so a step whose app does not even load scores 0 of the real count, not 0 of 1. The session's app
# is code an AI wrote: it runs under sandbox-exec, which refuses every file write but the scoring folder's and every network call.
score() {
  local app="$1" n="$2" i files=() ref out st
  for i in $(seq 1 "$n"); do files+=("$BENCH/hidden/step-$i.test.js"); done
  ref="$H/ref"; mkdir -p "$ref"
  sed "s/'--overdue': t => t.due \&\& t.due <= now,/'--overdue': t => !t.done \&\& t.due \&\& t.due < now,/" "$BENCH/baseline-3/todo.js" > "$ref/todo.js"
  total="$(BENCH_APP_DIR="$ref" node --test --test-reporter=tap "${files[@]}" 2>/dev/null | sed -n 's/^# tests //p')"
  st="$(mktemp -d "$H/score.XXXXXX")"
  # no program but node itself may start (no launchctl, open or osascript to leave the sandbox through), and no Apple events
  # and no native code (--no-addons): node cannot reach mach services or register its own outside the profile's reach
  out="$(cd "$st" && NODE_OPTIONS=--no-addons TMPDIR="$st" BENCH_APP_DIR="$app" sandbox-exec -p "(version 1)(allow default)(deny network*)(deny appleevent-send)(deny mach-register)(deny process-exec)(allow process-exec (literal \"$NODE\"))(deny file-write*)(allow file-write* (subpath \"$st\") (literal \"/dev/null\") (regex #\"^/dev/(fd/|tty|std)\"))" \
    "$NODE" --test --test-reporter=tap "${files[@]}" 2>/dev/null || true)"
  passed="$(printf '%s\n' "$out" | sed -n 's/^# pass //p')"
  [[ -n "$passed" ]] || passed=0
}

# Each project is a fresh mktemp -d, step 3's made only after step 2's session has ended, so no earlier session could plant in it.
# They live under the host folder (BENCH_PROJECTS overrides), which only the project's own session may write, while it runs.
newdir() { local d r="${BENCH_PROJECTS:-$H/projects}"; mkdir -p "$r"; d="$(mktemp -d "$r/bench-proj.XXXXXX")"; cd -P "$d" && pwd -P; }
for step in $(seq 1 "$steps"); do
  if [[ "$step" == 1 ]]; then proj="$(newdir)"; new_project "$proj"; fi
  if [[ "$step" == 3 ]]; then proj="$(newdir)"; new_project "$proj" "$BENCH/baseline-3"; fi
  printf '%s\n' "$proj" > "$H/proj-$step.path"
  env_path="$BASE_PATH"; [[ "$arm" == plain ]] || env_path="$CH/tools:$BASE_PATH"
  before_tickets="$(ls "$proj/.tickets" 2>/dev/null | sort || true)"
  fp_before="$(fingerprint)"
  start=$(date +%s); status=ok; reason=""; rc=0
  (cd "$proj" && PATH="$env_path" CANON_HOME="$CH" TMPDIR="$W/tmp" "$CLAUDE_BIN" -p "$(prompt_for "$step")" --model "$MODEL" --setting-sources project,local \
    --output-format json --permission-mode acceptEdits --allowedTools Agent Bash Read Grep Glob Edit Write --settings "$(sandbox_for "$proj")" \
    --max-budget-usd "${BENCH_MAX_USD:-5}" \
    > "$H/step-$step.json" 2> "$H/step-$step.err") || rc=$?
  minutes="$(awk -v s="$start" -v e="$(date +%s)" 'BEGIN { printf "%.1f", (e - s) / 60 }')"
  # The session's own numbers; anything unreadable is a failed row, never a zero-cost success.
  parsed="$(node -e '
    const fs = require("fs"); let j;
    try { j = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { console.log("ERR\tunreadable claude -p output"); process.exit(0); }
    if (j.is_error) { console.log("ERR\tclaude -p reported an error: " + String(j.result || j.subtype || "").replace(/\s+/g, " ").slice(0, 120)); process.exit(0); }
    if (typeof j.total_cost_usd !== "number") { console.log("ERR\tno total_cost_usd in claude -p output"); process.exit(0); }
    let u = { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 };
    const mu = j.modelUsage && Object.values(j.modelUsage);
    if (mu && mu.length) for (const m of mu) { u.input_tokens += m.inputTokens || 0; u.output_tokens += m.outputTokens || 0; u.cache_read_input_tokens += m.cacheReadInputTokens || 0; u.cache_creation_input_tokens += m.cacheCreationInputTokens || 0; }
    else u = Object.assign(u, j.usage || {});
    console.log(["OK", j.total_cost_usd.toFixed(4), u.input_tokens, u.output_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens, j.num_turns ?? "n/a", j.session_id || "n/a"].join("\t"));
  ' "$H/step-$step.json")"
  IFS=$'\t' read -r kind cost in_t out_t cr cw turns session <<< "$parsed"
  if [[ "$kind" != OK ]]; then status=failed; reason="$cost"; cost=n/a; in_t=n/a; out_t=n/a; cr=n/a; cw=n/a; turns=n/a; session=n/a; fi
  if [[ "$rc" != 0 && "$status" == ok ]]; then status=failed; reason="claude -p exited $rc"; fi
  [[ "$status" != failed || -n "$reason" ]] || reason="claude -p exited $rc"
  # Contamination: the user's state changed, the session's transcript read the hidden tests, or it changed canon's own tracked files.
  # (compared with the clean clone's tracked files by content, so no git runs in the folder the session wrote)
  if [[ "$arm" == canon ]] && canon_changed; then
    status=contaminated; reason="the session changed canon's own files in its CANON_HOME"
  fi
  if [[ "$(fingerprint)" != "$fp_before" ]]; then status=contaminated; reason="the user's canon state changed during the session"; fi
  tdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$proj" | sed 's/[^A-Za-z0-9]/-/g')"
  if [[ -d "$tdir" ]] && grep -rqs "vs-plain/hidden" "$tdir"; then status=contaminated; reason="the transcript reads the hidden tests"; fi
  # Canon's split: the ticket this step created, closed or not; its token-spend phases; its gate runs from the subagent log.
  planning=n/a; impl=n/a; gates=n/a; gate_runs=n/a; entry=claude-p
  if [[ "$arm" == canon ]]; then
    entry="claude-p+sprint"
    tid="$(comm -13 <(printf '%s\n' "$before_tickets") <(ls "$proj/.tickets" 2>/dev/null | sort) | grep -E '^t-' | tail -1 || true)"
    if [[ -z "$tid" ]]; then
      [[ "$status" != ok ]] || { status=incomplete; reason="no sprint ticket was created"; }
    else
      if ! grep -qE '^status: closed' "$proj/.tickets/$tid/ticket.md" 2>/dev/null; then
        [[ "$status" != ok ]] || { status=incomplete; reason="$tid never reached sprint complete"; }
      fi
      ts="$(cd "$proj" && PATH="$HC/tools:$BASE_PATH" CANON_HOME="$CH" "$HC/tools/sprint" token-spend --ticket "$tid" 2>/dev/null \
        | awk -v t="$tid" '$1 == t { print $3 "\t" $4 "\t" $5; exit }' || true)"
      [[ -z "$ts" ]] || IFS=$'\t' read -r planning impl gates <<< "$ts"
      if [[ -f "$proj/.claude/subagent-runs.jsonl" ]]; then
        gate_runs="$(node -e '
          const rows = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return null; } })
            .filter(r => r && r.ticket === process.argv[2]);
          console.log(rows.length ? rows.map(r => `${r.agent_type}=${r.tokens ?? "n/a"}tok/${r.minutes ?? "n/a"}min`).join(";") : "n/a");
        ' "$proj/.claude/subagent-runs.jsonl" "$tid")"
      fi
    fi
  fi
  score "$proj" "$step"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)	$arm	$run	$step	$status	${reason//$'\t'/ }	$commit	$MODEL	$entry	$cost	$in_t	$out_t	$cr	$cw	$minutes	$turns	$passed	$total	$planning	$impl	$gates	$gate_runs	$session" >> "$results"
  echo "run.sh: $arm run $run step $step: $status${reason:+ ($reason)}, \$$cost, ${minutes} min, $passed/$total hidden tests"
done
echo "run.sh: rows in $results; session folder $W, host folder $H (proj-<step>.path names each project)"
