#!/usr/bin/env bash
# model-registry-parity (t-d40b) — the copies of a model id that live outside the registry cannot drift from it silently.
# The registry (tools/sprint-check-app/model-tiers.json, the tracked seed) owns the aliases. Two copies sit beside it: the
# daemon's Copilot id map (copilotModelIDs in tools/canon-go/internal/daemon/main.go, Copilot's own spelling of the same
# models) and complete.md's note of the same pairs. The agents' `model:` floor is pinned to the eval default by
# tests/skills-agents.sh. A new Sonnet or Haiku in the seed that the daemon map or the note does not follow fails here,
# instead of a Copilot gate quietly running on the old model. (Making the daemon follow the user's own registry at run
# time is t-6760's job; this only locks what the repo ships.)

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/helpers.sh"
REGISTRY="${PARITY_REGISTRY:-$ROOT/tools/sprint-check-app/model-tiers.json}"
MAIN_GO="${PARITY_DAEMON_GO:-$ROOT/tools/canon-go/internal/daemon/main.go}"
COMPLETE_MD="${PARITY_COMPLETE_MD:-$ROOT/skills/sprint/reference/complete.md}"

# the id Copilot lists for a registry id: drop a date suffix, and write the trailing version with a dot (4-5 -> 4.5)
copilot_id() { printf '%s\n' "$1" | sed -E 's/-[0-9]{8}$//; s/^(.*[a-z])-([0-9]+)-([0-9]+)$/\1-\2.\3/'; }
registry_id() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(next((m["id"] for m in d["models"]["anthropic"] if m.get("alias")==sys.argv[2] and not m.get("legacy")), ""))' "$REGISTRY" "$1"; }
daemon_id() { sed -n '/^var copilotModelIDs = map/,/^}/p' "$MAIN_GO" | sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\"\\([^\"]*\\)\",.*/\\1/p"; }
# the note wraps across lines, so read it as one line first
note_id() { tr '\n' ' ' < "$COMPLETE_MD" | sed -n "s/.*\`$1\`[^\`]*→[[:space:]]*\`\\(claude-[a-z0-9.-]*\\)\`.*/\\1/p" | head -1; }

for alias in sonnet haiku; do
  reg="$(registry_id "$alias")"
  [[ -n "$reg" ]] || fail "the registry has no active Anthropic model with the alias $alias"
  want="$(copilot_id "$reg")"
  assert_eq "$want" "$(daemon_id "$alias")"     # copilotModelIDs["$alias"] is Copilot's spelling of the registry's $alias model ($reg)
  [[ "$(note_id "$alias")" == "$want" ]] || fail "complete.md's Copilot note maps $alias to '$(note_id "$alias")', not $want (the registry's $alias is $reg)"
done

echo "model-registry-parity: ok"
