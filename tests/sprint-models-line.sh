#!/usr/bin/env bash
# sprint-models-line — t-2a21: `sprint start` prints the run's preset and models in one line and records the preset, agent and pipeline
# on the ticket and in `sprint.started`; `sprint approve` prints the line again (with the Sign-off's model lines) and records a preset
# changed since start. On a Windows Copilot run (ToDo-Demo t-pnu4) nothing said which preset ran, so its cost could not be tied to one.
# Protects `sprint start`, `sprint approve` (its Models and Build model lines, run_preset_build) and the sprint.started event.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"   # the Models line comes from the board binary's model-summary

W="$(mktemp -d)"; W="$(cd "$W" && pwd -P)"
export CANON_HOME="$W/canon-home" CANON_GATE_SCOPE_DIR="$W/registry"
project="$(make_project)"; project="$(cd "$project" && pwd -P)"
trap 'rm -rf "$W" "$project"' EXIT
unset COCKPIT_AGENT COCKPIT_TICKET COPILOT_CLI CLAUDECODE CANON_TICKETS_DIR
cd "$project"
git commit -q --allow-empty -m init
SEED="$ROOT/tools/sprint-check-app/model-tiers.json"
# reg <step:agent=id ...> — the person's registry: the seed with these picks changed (both agents' columns are always written, so whether
# `copilot` is on this machine's PATH, which decides Admin's agent list, never changes the answer)
reg() {
  mkdir -p "$CANON_HOME/cockpit"
  python3 - "$SEED" "$CANON_HOME/cockpit/model-tiers.json" "$@" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
for kv in sys.argv[3:]:
    k, v = kv.split("=", 1); step, agent = k.split(":")
    doc["defaults"].setdefault(step, {})[agent] = v
json.dump(doc, open(sys.argv[2], "w"))
PY
}
ECONOMY=(plan:claude=claude-sonnet-5-5 build:claude=claude-haiku-5-5 plan:copilot=claude-sonnet-5.5 build:copilot=claude-haiku-5.5)
fm() { awk -v k="$2" -F': *' '$1 == k { print $2; exit }' ".tickets/$1/ticket.md"; }
end() { "$TKT" close "$1" --no-sprint >/dev/null; }   # one active sprint at a time: end each before the next start (approve reads only plan.md)
signoff() { printf '# Plan\n\n## Sign-off\n%s\n\n- [ ] Plan approved\n\n## Approach\nx\n' "$2" > ".tickets/$1/plan.md"; }

# 1. Copilot CLI outside the Cockpit, Economy: the line names Copilot's display names, and the ticket and event record the run
reg "${ECONOMY[@]}"
id="$("$TKT" create "Economy run" | awk '{ print $NF }')"
out="$(COPILOT_CLI=1 "$SPRINT" start "$id" 2>&1)"; end "$id"
assert_contains "$out" "Models (Economy · Copilot CLI): Plan Claude Sonnet 5.5 · Spec check Claude Sonnet 5.5 · Build Claude Haiku 5.5 · Close Claude Sonnet 5.5 · Reviewer Claude Sonnet 5.5 · Evaluator Claude Sonnet 5.5 · Second eval Off"   # t-3e06: Close after Build
assert_eq "economy" "$(fm "$id" run_preset)"
assert_eq "copilot" "$(fm "$id" run_agent)"
assert_eq "canon-default" "$(fm "$id" run_pipeline)"
ev="$(event_line sprint.started "$id")"
assert_contains "$ev" '"run_preset":"economy"'
assert_contains "$ev" '"run_agent":"copilot"'
assert_contains "$ev" '"run_pipeline":"canon-default"'

# 2. Claude Code (CLAUDECODE wins over COPILOT_CLI), one pick changed: Custom
reg "${ECONOMY[@]}" build:claude=claude-opus-5-5
id="$("$TKT" create "Custom run" | awk '{ print $NF }')"
out="$(CLAUDECODE=1 COPILOT_CLI=1 "$SPRINT" start "$id" 2>&1)"; end "$id"
assert_contains "$out" "Models (Custom · Claude Code): Plan Claude Sonnet 5.5 · Spec check Claude Sonnet 5.5 · Build Claude Opus 5.5 ·"
assert_eq "custom" "$(fm "$id" run_preset)"
assert_eq "claude" "$(fm "$id" run_agent)"

# 3. approve: the Sign-off's model lines show "(ticket)" (Gate model: the three gates, never Second eval); the Build line is Copilot's
reg "${ECONOMY[@]}"
id="$("$TKT" create "Approve run" | awk '{ print $NF }')"
COPILOT_CLI=1 "$SPRINT" start "$id" >/dev/null 2>&1; end "$id"
signoff "$id" "Tier: normal | Risk: x | Gate model: haiku | Build model: opus | Close model: sonnet"
out="$(COPILOT_CLI=1 "$SPRINT" approve "$id" 2>&1)"
assert_contains "$out" "Models (Economy · Copilot CLI): Plan Claude Sonnet 5.5 · Spec check haiku (ticket) · Build opus (ticket) · Close sonnet (ticket) · Reviewer haiku (ticket) · Evaluator haiku (ticket) · Second eval Off"
assert_contains "$out" "Build model (the ticket's Build model line): opus"
[[ -z "$(fm "$id" run_preset_build)" ]] || fail "approve under the start's preset wrote run_preset_build"
# no ticket line: the Build line names Copilot's own pick (it named Claude's alias before _run_agent)
id2="$("$TKT" create "Copilot build line" | awk '{ print $NF }')"
COPILOT_CLI=1 "$SPRINT" start "$id2" >/dev/null 2>&1; end "$id2"
signoff "$id2" "Tier: normal | Risk: x"
out="$(COPILOT_CLI=1 "$SPRINT" approve "$id2" 2>&1)"
assert_contains "$out" "Build model (Admin > Model tiers): claude-haiku-5.5"
# `Plan model: default` is no override (gate-model.sh's rule): no "(ticket)"
signoff "$id2" "Tier: normal | Risk: x | Plan model: default"
out="$(COPILOT_CLI=1 "$SPRINT" approve "$id2" 2>&1)"
assert_contains "$out" "Models (Economy · Copilot CLI): Plan Claude Sonnet 5.5 · Spec check"
# the picks changed after start: approve records the preset it resolves beside the start's
reg plan:claude=claude-sonnet-5-5 plan:copilot=claude-sonnet-5.5   # Balanced's build again, Plan on Sonnet: Custom
signoff "$id" "Tier: normal | Risk: x"
COPILOT_CLI=1 "$SPRINT" approve "$id" >/dev/null 2>&1
assert_eq "economy" "$(fm "$id" run_preset)"
assert_eq "custom" "$(fm "$id" run_preset_build)"
# a ticket started before the fields existed: nothing recorded at approve
id3="$("$TKT" create "Old ticket" | awk '{ print $NF }')"
"$SPRINT" start "$id3" >/dev/null 2>&1; end "$id3"
sed -i.bak '/^run_preset:/d' ".tickets/$id3/ticket.md" && rm -f ".tickets/$id3/ticket.md.bak"
signoff "$id3" "Tier: normal | Risk: x"
"$SPRINT" approve "$id3" >/dev/null 2>&1
[[ -z "$(fm "$id3" run_preset_build)$(fm "$id3" run_preset)" ]] || fail "approve wrote a preset on a ticket with no run_preset"

# 4. Pi keeps its session model and records no preset
id="$("$TKT" create "Pi run" | awk '{ print $NF }')"
out="$(COCKPIT_AGENT=pi "$SPRINT" start "$id" 2>&1)"; end "$id"
assert_contains "$out" "Models (Pi): this session keeps its model"
assert_eq "pi" "$(fm "$id" run_agent)"
! grep -q '^run_preset:' ".tickets/$id/ticket.md" || fail "Pi's ticket has a run_preset line"
ev="$(event_line sprint.started "$id")"
assert_contains "$ev" '"run_agent":"pi"'
[[ "$ev" != *run_preset* ]] || fail "Pi's sprint.started carries run_preset: $ev"

# an agent name that is no plain word is never written to the ticket (it falls back to the harness read)
id="$("$TKT" create "Odd agent" | awk '{ print $NF }')"
COCKPIT_AGENT=$'pi\nrun_preset: x' "$SPRINT" start "$id" >/dev/null 2>&1 || fail "sprint start failed on a COCKPIT_AGENT with a newline"
end "$id"
assert_eq "claude" "$(fm "$id" run_agent)"
grep -q '^run_preset: x' ".tickets/$id/ticket.md" && fail "COCKPIT_AGENT injected a frontmatter line"

# 5. a project pipeline override: run_pipeline is the resolved order's 12-hex digest
mkdir -p canon-config && printf 'extends: canon-default\noff: [code-simplifier]\n' > canon-config/pipeline.yaml
id="$("$TKT" create "Trimmed pipeline" | awk '{ print $NF }')"
"$SPRINT" start "$id" >/dev/null 2>&1; end "$id"
[[ "$(fm "$id" run_pipeline)" =~ ^[0-9a-f]{12}$ ]] || fail "run_pipeline with a project pipeline is '$(fm "$id" run_pipeline)', not 12 hex"
# a pipeline file the resolver refuses: no run_pipeline, and the start still succeeds
printf 'extends: canon-default\noff: [no-such-node]\n' > canon-config/pipeline.yaml
id="$("$TKT" create "Bad pipeline" | awk '{ print $NF }')"
"$SPRINT" start "$id" >/dev/null 2>&1 || fail "sprint start failed on a pipeline file the resolver refuses"
end "$id"
! grep -q '^run_pipeline:' ".tickets/$id/ticket.md" || fail "a refused pipeline still wrote run_pipeline: $(fm "$id" run_pipeline)"
rm -rf canon-config

# 6. a board without model-summary: no Models line, no preset, and the start still succeeds
stub="$W/old-board"; printf '#!/bin/sh\necho "usage: canon-go [port]"\n' > "$stub"; chmod +x "$stub"
id="$("$TKT" create "Old board" | awk '{ print $NF }')"
set +e; out="$(SPRINT_CHECK_BIN="$stub" "$SPRINT" start "$id" 2>&1)"; code=$?; set -e
assert_eq 0 "$code"
assert_contains "$out" "Sprint started: $id"
[[ "$out" != *"Models ("* ]] || fail "a board without model-summary still printed a Models line: $out"
assert_eq "" "$(fm "$id" run_preset)"

echo "sprint-models-line: ok"
