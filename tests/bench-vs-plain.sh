#!/usr/bin/env bash
# bench-vs-plain (t-e85f) — bench/vs-plain/run.sh and report.sh against a stub claude (no money spent): a session never sees the hidden
# tests, run.sh writes nothing outside its scratch folder and results file, a failed session (is_error, a non-zero exit, unreadable
# output) is a failed row and never a zero-cost success, a session that changes the user's canon state or whose transcript reads the
# hidden tests is contaminated, the canon arm's split reads n/a when there is no data and a sprint that never closed is incomplete,
# and report.sh keeps only ok rows (naming the dropped ones) with $ per passing test n/a at 0 passes. Also the hidden tests against
# baseline-3/: steps 1-2 pass and step 3 fails as shipped, and all pass once the plant is fixed. Prod path: the bench whose numbers
# t-508e puts in the README (the cost of canon vs plain Claude Code), and its canon-lean arm (t-8882: the lean-tools ship decision).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
T="$(mktemp -d)"; T="$(cd -P "$T" && pwd -P)"; trap 'rm -rf "$T"' EXIT
B="$ROOT/bench/vs-plain"
FIXED='s/'"'"'--overdue'"'"': t => t.due \&\& t.due <= now,/'"'"'--overdue'"'"': t => !t.done \&\& t.due \&\& t.due < now,/'

# --- the hidden tests against the reference app
tap() { BENCH_APP_DIR="$1" node --test --test-reporter=tap "${@:2}" 2>/dev/null | sed -nE 's/^# (pass|fail) /\1=/p' | tr '\n' ' ' || true; }
mkdir -p "$T/ref"; cp "$B/baseline-3/todo.js" "$T/ref/"
assert_eq "pass=24 fail=0 " "$(tap "$T/ref" "$B/hidden/step-1.test.js" "$B/hidden/step-2.test.js")" "baseline-3 passes steps 1-2"
assert_eq "pass=0 fail=3 " "$(tap "$T/ref" "$B/hidden/step-3.test.js")" "baseline-3's plant fails every step-3 test"
sed -i.bak "$FIXED" "$T/ref/todo.js"
assert_eq "pass=27 fail=0 " "$(tap "$T/ref" "$B/hidden/step-1.test.js" "$B/hidden/step-2.test.js" "$B/hidden/step-3.test.js")" "the fixed plant passes all"

# --- a stub claude: writes the fixed app, says whether it could see a hidden test, and answers as STUB_MODE says
mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "session in $PWD" >> "$STUB_LOG"
echo "args: $(printf "%s " "$@" | tr "\n" " ")" >> "$STUB_LOG"
echo "canon on PATH: $(command -v sprint tkt 2>/dev/null | tr "\n" " ")" >> "$STUB_LOG"
echo "tmpdir: $TMPDIR" >> "$STUB_LOG"
if [[ -n "$(find . \( -name 'step-*.test.js' -o -name lib.js \) -print -quit)" ]]; then echo HIDDEN-SEEN >> "$STUB_LOG"; fi
cp "$STUB_APP" ./todo.js
enc="$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$CLAUDE_CONFIG_DIR/projects/$enc"
echo '{"type":"user"}' > "$CLAUDE_CONFIG_DIR/projects/$enc/s.jsonl"
case "${STUB_MODE:-ok}" in
  leak) (cd "$STUB_HIDDEN" && grep -h bench-canary lib.js) | sed 's/"/ /g; s/^/{"tool_result":"/; s/$/"}/' >> "$CLAUDE_CONFIG_DIR/projects/$enc/s.jsonl" ;;   # a read by a path without vs-plain/hidden
  peek) echo '{"tool":"Read","path":"/x/bench/vs-plain/hidden/step-1.test.js"}' >> "$CLAUDE_CONFIG_DIR/projects/$enc/s.jsonl" ;;
  touch) mkdir -p "$HOME/.config/canon"; echo /somewhere >> "$HOME/.config/canon/projects" ;;
  error) echo '{"is_error":true,"result":"rate limited","total_cost_usd":0}'; exit 0 ;;
  maxed) echo '{"is_error":false,"subtype":"error_max_budget_usd","total_cost_usd":5.01}'; exit 0 ;;
  exit) echo '{"is_error":false,"total_cost_usd":0.5,"num_turns":3}'; exit 3 ;;
  garbage) echo 'not json'; exit 0 ;;
  closed) mkdir -p .tickets/t-abcd .claude; printf -- '---\nid: t-abcd\nstatus: closed\n---\n' > .tickets/t-abcd/ticket.md
          echo '{"agent_type":"reviewer","tokens":1200,"minutes":2,"ticket":"t-abcd"}' >> .claude/subagent-runs.jsonl ;;
  escape) { echo 'try { require("fs").writeFileSync(process.env.STUB_ESCAPE, "x"); } catch {}'
           echo 'try { require("child_process").execFileSync("/bin/sh", ["-c", "touch \"$STUB_ESCAPE.exec\""]); } catch {}'
           echo 'try { process.dlopen({ exports: {} }, "/nonexistent.node"); } catch (e) { if (e.code !== "ERR_DLOPEN_DISABLED") process.exit(7); }'   # native code allowed: the app dies, the score drops
           cat "$STUB_APP"; } | grep -v '^#!' > ./todo.js ;;
  plant) printf '#!/usr/bin/env bash\ntouch "%s"\n' "$STUB_PLANTED" > "$CANON_HOME/tools/sprint"
         mkdir -p .tickets/t-abcd; printf -- '---\nid: t-abcd\nstatus: closed\n---\n' > .tickets/t-abcd/ticket.md ;;
  two) mkdir -p .tickets/t-0001 .tickets/t-ffff .claude   # the closed one sorts first by id: the row must still read it
       printf -- '---\nid: t-0001\nstatus: closed\ncreated: 2026-01-01T00:00:00Z\n---\n' > .tickets/t-0001/ticket.md
       printf -- '---\nid: t-ffff\nstatus: in_progress\ncreated: 2026-01-02T00:00:00Z\n---\n' > .tickets/t-ffff/ticket.md
       echo '{"agent_type":"evaluator","tokens":900,"minutes":3,"ticket":"t-0001"}' >> .claude/subagent-runs.jsonl ;;
  open) mkdir -p .tickets/t-abcd; printf -- '---\nid: t-abcd\nstatus: in_progress\n---\n' > .tickets/t-abcd/ticket.md ;;
esac
echo '{"is_error":false,"total_cost_usd":0.25,"num_turns":7,"session_id":"s1","modelUsage":{"claude-sonnet-5-5":{"inputTokens":100,"outputTokens":50,"cacheReadInputTokens":1000,"cacheCreationInputTokens":10}}}'
EOF
chmod +x "$T/bin/claude"
cp "$T/ref/todo.js" "$T/fixed.js"
export STUB_APP="$T/fixed.js" STUB_LOG="$T/stub.log" BENCH_CLAUDE="$T/bin/claude"
export HOME="$T/home" CLAUDE_CONFIG_DIR="$T/claude-config" XDG_CONFIG_HOME="$T/home/.config" CANON_HOME="$T/no-canon"
mkdir -p "$HOME" "$T/tmpd"
repo_before="$(git -C "$ROOT" status --porcelain)"

# bench <mode> <arm> <steps> -> the last result row's fields: status reason cost passed total planning gates gate_runs
echo 0 > "$T/n"
bench() {
  local n; n=$(($(cat "$T/n") + 1)); echo "$n" > "$T/n"; : > "$STUB_LOG"
  STUB_MODE="$1" STUB_HIDDEN="$B/hidden" BENCH_WORK="$T/w$n" BENCH_HOST="$T/host$n" TMPDIR="$T/tmpd" "$B/run.sh" "$2" 1 --steps "$3" --results "$T/r$n.tsv" >/dev/null 2>"$T/err$n" \
    || fail "run.sh $1 $2 exited non-zero: $(cat "$T/err$n")"
  tail -1 "$T/r$n.tsv" | awk -F'\t' '{ print $5 "|" $6 "|" $10 "|" $17 "|" $18 "|" $19 "|" $21 "|" $22 }'
}

row="$(bench ok plain 3)"
assert_eq "ok||0.2500|27|27|n/a|n/a|n/a" "$row" "plain step 3: a clean row, scored on all 27 hidden tests"
assert_eq 3 "$(grep -c '^session in' "$STUB_LOG")" "three sessions"
grep -q HIDDEN-SEEN "$STUB_LOG" && fail "a session could see the hidden tests"
# no bypass mode: Bash in the sandbox with no unsandboxed retry, edits kept in the project (the session runs unattended as the user)
args="$(grep -m1 "^args:" "$STUB_LOG")"
[[ "$args" == *"--permission-mode acceptEdits"* && "$args" == *'"sandbox":{"enabled":true'* && "$args" == *'"allowUnsandboxedCommands":false'* ]] || fail "sessions run sandboxed: $args"
[[ "$args" != *bypassPermissions* && "$args" != *dangerously* ]] || fail "no bypass mode: $args"
# the sandbox may write the run's scratch folder and nothing else, and the session's TMPDIR is inside it (the inherited one is refused)
p1="$(cat "$T/host1/proj-1.path")"
[[ "$p1" == "$T/host1/projects/bench-proj."* ]] || fail "each project is a fresh folder in the host folder: $p1"
[[ "$args" == *'"filesystem":{"allowWrite":["'"$p1"'","'"$T/w1"'"]}'* ]] || fail "allowWrite names only the project and the session folder: $args"
[[ "$(cat "$T/host1/proj-3.path")" != "$p1" ]] || fail "step 3 gets its own fresh project"
assert_eq "tmpdir: $T/w1/tmp" "$(grep -m1 '^tmpdir:' "$STUB_LOG")"
seen="$(grep -m1 "^canon on PATH:" "$STUB_LOG")"
assert_eq "canon on PATH: " "$seen" "the plain arm finds no sprint or tkt"
# nothing run.sh writes after a session lives where the session could write (a symlink there would redirect it): outputs go to the host folder
[[ -z "$(find "$T/w1" "$p1" \( -name 'step-*.json' -o -name 'step-*.err' -o -name 'skills-add.log' -o -name 'score.*' \) -print -quit)" ]] || fail "run.sh wrote its own files into a session folder"
[[ -s "$T/host1/step-1.json" ]] || fail "the session output is in the host folder"
assert_eq "1|13" "$(awk -F'\t' 'NR==2 { print $4 "|" $18 }' "$T/r1.tsv")" "step 1 scores its 13 tests"
[[ "$(awk -F'\t' 'NR==3 { print $18 }' "$T/r1.tsv")" == 24 ]] || fail "step 2 scores steps 1-2 (24)"
assert_eq "$(awk -F'\t' 'NR==2 { print $11 "/" $12 "/" $13 "/" $14 "/" $16 "/" $23 }' "$T/r1.tsv")" "100/50/1000/10/7/s1" "tokens, turns and session from modelUsage"
[[ -z "$(find "$HOME" -mindepth 1 -print -quit)" ]] || fail "run.sh wrote under HOME: $(find "$HOME" -mindepth 1 -print -quit)"
assert_eq "$repo_before" "$(git -C "$ROOT" status --porcelain)" "the repo's tree is unchanged"

for m in error exit garbage; do
  row="$(bench "$m" plain 1)"
  [[ "$row" == failed\|?*\|n/a\|* ]] || fail "$m: a failed session must be a failed row with a reason and no cost: $row"
done
[[ "$(bench error plain 1)" == *"rate limited"* ]] || fail "is_error keeps the session's reason"
[[ "$(bench exit plain 1)" == *"exited 3"* ]] || fail "a non-zero exit is named"

# scoring runs the session's app (code an AI wrote) under sandbox-exec: its writes outside the scoring folder are refused
export STUB_ESCAPE="$T/escaped"
[[ "$(bench escape plain 1)" == "ok||0.2500|13|13|"* ]] || fail "the escaping app still scores"
[[ ! -e "$T/escaped" ]] || fail "scoring let the session's app write outside its folder"
[[ ! -e "$T/escaped.exec" ]] || fail "scoring let the session's app start another program (launchctl, open, sh)"
[[ "$(bench peek plain 1)" == "contaminated|the transcript reads the hidden tests|"* ]] || fail "a transcript reading the hidden tests is contaminated"
[[ "$(bench leak plain 1)" == "contaminated|the transcript reads the hidden tests|"* ]] || fail "the hidden tests read by a relative path (their canary in the transcript) is contaminated"
[[ "$(bench maxed plain 1)" == "failed|"*"error_max_budget_usd"* ]] || fail "a max-budget/max-turns result is a failed row, even without is_error"
[[ "$(bench touch plain 1)" == "contaminated|the user's canon state changed"* ]] || fail "a change to the user's canon state is contaminated"
rm -rf "$HOME/.config"

# canon arm: a clone of this repo as CANON_HOME, models pinned, the sprint skill added under a scratch HOME
row="$(bench closed canon 1)"
[[ "$(grep -m1 "^canon on PATH:" "$STUB_LOG")" == "canon on PATH: $T/w"*"/canon/tools/sprint "* ]] || fail "canon finds its scratch clone's sprint first: $(grep -m1 "^canon on PATH:" "$STUB_LOG")"
assert_eq "ok||0.2500|13|13|n/a|n/a|reviewer=1200tok/2min" "$row" "canon: closed sprint, no transcripts -> n/a split, gate runs read"
n="$(cat "$T/n")"; w="$T/w$n"
p1="$(cat "$T/host$n/proj-1.path")"
norm_args() { grep -m1 "^args:" "$STUB_LOG" | sed "s|$1|PROJ|g; s|$2|WORK|g"; }
canon_args="$(norm_args "$p1" "$w")"
assert_eq "ok||0.2500|13|13|n/a|n/a|evaluator=900tok/3min" "$(bench two canon 1)" "canon: of two new tickets the closed one is the step's, whatever the id order"
[[ -f "$p1/.claude/skills/sprint/SKILL.md" || -f "$p1/.agents/skills/sprint/SKILL.md" ]] || fail "canon: the sprint skill is installed in the project"
node -e 'const d=require(process.argv[1]); for (const [s,v] of Object.entries(d.defaults)) if (v.claude && v.claude !== "claude-sonnet-5-5") { console.error(s, v.claude); process.exit(1); }' \
  "$w/canon/cockpit/model-tiers.json" || fail "canon: every model tier is pinned to Sonnet"
# projects sit outside TMPDIR (bench above), so skills.sh registers the project: in the scratch HOME, never the real one
[[ "$(grep -c . "$T/host$n/setup-home/.config/canon/projects" 2>/dev/null)" == 1 ]] || fail "canon: skills.sh's project list did not go to the scratch HOME"
[[ -z "$(find "$HOME" -mindepth 1 -print -quit)" ]] || fail "canon: run.sh wrote under HOME"
assert_eq "canon	claude-sonnet-5-5	claude-p+sprint" "$(awk -F'\t' 'NR==2 { print $2 "\t" $8 "\t" $9 }' "$T/r$n.tsv")" "the row names arm, model, entry point"
# canon-lean (t-8882): the canon arm plus bench/vs-plain/lean-tools.txt's names as permissions.deny in the session settings, nothing else changed
[[ "$(bench closed canon-lean 1)" == "ok||0.2500|13|13|n/a|n/a|reviewer=1200tok/2min" ]] || fail "canon-lean: a closed sprint reads like canon's"
n="$(cat "$T/n")"; lp="$(cat "$T/host$n/proj-1.path")"
deny="$(node -e 'console.log(JSON.stringify({ permissions: { deny: require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(l => l.trim()) } }).slice(1, -1))' "$B/lean-tools.txt")"
lean_args="$(norm_args "$lp" "$T/w$n")"
[[ "$lean_args" == *",$deny}"* ]] || fail "canon-lean: the session settings deny the owner file's tools: $lean_args"
assert_eq "$canon_args" "${lean_args/",$deny"/}" "canon-lean: the argv is canon's apart from the deny list"
[[ "$canon_args" != *permissions* ]] || fail "canon: no deny list in the canon arm"
[[ -f "$lp/.claude/skills/sprint/SKILL.md" || -f "$lp/.agents/skills/sprint/SKILL.md" ]] || fail "canon-lean: the sprint skill is installed"
assert_eq "canon-lean	claude-p+sprint" "$(awk -F'\t' 'NR==2 { print $2 "\t" $9 }' "$T/r$n.tsv")" "canon-lean: the row names its arm and canon's entry point"
[[ "$(bench open canon 1)" == "incomplete|t-abcd never reached sprint complete|"* ]] || fail "an open sprint is incomplete"
# a session may write its own CANON_HOME: code it plants there never runs outside the sandbox (run.sh's own commands use a second clone)
export STUB_PLANTED="$T/planted"
[[ "$(bench plant canon 1)" == "contaminated|the session changed canon's own files in its CANON_HOME|"* ]] || fail "a session that edits canon's files is contaminated"
[[ ! -e "$T/planted" ]] || fail "run.sh ran code the session planted in its CANON_HOME"
[[ "$(bench ok canon 1)" == "incomplete|no sprint ticket was created|"* ]] || fail "no sprint at all is incomplete"
assert_eq "$repo_before" "$(git -C "$ROOT" status --porcelain)" "the repo's tree is unchanged after the canon runs"

# --- report.sh: means over ok rows only, dropped rows named, $ per passing test n/a at 0 passes
{ head -1 "$T/r1.tsv"
  printf 'd\tplain\t1\t1\tok\t\tc\tm\te\t0.50\t1\t1\t1\t1\t2.0\t3\t20\t24\tn/a\tn/a\tn/a\tn/a\ts\n'
  printf 'd\tplain\t2\t1\tok\t\tc\tm\te\t1.50\t1\t1\t1\t1\t4.0\t3\t20\t24\tn/a\tn/a\tn/a\tn/a\ts\n'
  printf 'd\tplain\t3\t1\tfailed\trate limited\tc\tm\te\tn/a\tn/a\tn/a\tn/a\tn/a\t1.0\tn/a\t0\t24\tn/a\tn/a\tn/a\tn/a\tn/a\n'
  printf 'd\tcanon\t1\t1\tok\t\tc\tm\te\t2.00\t1\t1\t1\t1\t9.0\t3\t0\t24\t10k\t20k\t30k\tspeccheck=1000tok/1min;reviewer=2000tok/2min;evaluator=5000tok/3min\ts\n'
  printf 'd\tcanon-lean\t1\t1\tok\t\tc\tm\te\t1.00\t1\t1\t1\t1\t8.0\t3\t24\t24\t5k\t6k\t7k\treviewer=4000tok/2min\ts\n'
} > "$T/rep.tsv"
rep="$("$B/report.sh" "$T/rep.tsv")"
[[ "$rep" == *"| plain | 1 | 2 | 1 | 1.00 | 3.0 | 20.0 / 24 | 0.050 | n/a | n/a | n/a | n/a |"* ]] || fail "report: plain means over the 2 ok rows: $rep"
[[ "$rep" == *"| canon | 1 | 1 | 0 | 2.00 | 9.0 | 0.0 / 24 | n/a | 10k | 20k | 30k | 3k |"* ]] || fail "report: canon split, 0 passes -> n/a: $rep"
[[ "$rep" == *"| canon-lean | 1 | 1 | 0 | 1.00 | 8.0 | 24.0 / 24 | 0.042 | 5k | 6k | 7k | 4k |"* ]] || fail "report: canon-lean carries the canon split: $rep"
[[ "$rep" == *"- plain run 3 step 1: failed (rate limited)"* ]] || fail "report: the dropped row is named"

echo "bench-vs-plain: ok"
