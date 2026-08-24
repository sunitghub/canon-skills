#!/usr/bin/env bash
# gate-model.sh — read a plan.md's `## Sign-off` → `Gate model:` value.
# Sourced by sprint-headless and by tests/gate-model-parity.sh. Not standalone.
#
# One canonical bash implementation, extracted from sprint-headless when the
# cockpit daemon needed the same resolution in Go (t-842b). The Go port in
# tools/cockpit-daemon/main.go mirrors gate_model_resolve exactly; the two are
# pinned to one fixture set by tests/gate-model-parity.sh (cross-runtime port,
# per standards/efficiency.md). Change one, change both, or the parity test fails.

# gate_model_parse <plan-file> — prints the raw lowercased `Gate model:` value
# from the Sign-off section's Tier line, or nothing. Scoped to that one section
# and that one line: a `Tier:`-looking line in a later section is ignored.
gate_model_parse() {
  awk '
    /^##[[:space:]]+Sign-off[[:space:]]*$/ { in_so=1; next }
    in_so && /^##[[:space:]]/ { exit }
    in_so && /^[[:space:]]*[Tt]ier[[:space:]]*:/ {
      if (match($0, /[Gg]ate[[:space:]]+model[[:space:]]*:[[:space:]]*/)) {
        s = substr($0, RSTART+RLENGTH)
        sub(/[[:space:]]*\|.*$/, "", s)
        gsub(/[[:space:]]/, "", s)
        print tolower(s)
      }
      exit
    }
  ' "$1"
}

# gate_model_resolve <plan-file> — prints the model to pass as `--model`, or
# nothing when no override applies. `session` and an absent field both mean "no
# override" → the CLI's own default. Exits 2 on a value that is present but
# invalid, so a typo fails loudly instead of silently running on the default.
gate_model_resolve() {
  local plan="$1" v
  v="$(gate_model_parse "$plan")"
  [[ -z "$v" || "$v" == "session" ]] && return 0
  # Must START with a letter or digit, not just consist of the allowed charset.
  # `-` is legal inside a model id (claude-sonnet-5) but a LEADING one makes the
  # value a flag: `--model --dangerously-skip-permissions` hands the CLI a second
  # option instead of a value. plan.md is writable by the very agent this value
  # configures, so a permissive charset here is a privilege-escalation path, not
  # a typo class — see standards/agent-design.md on durable state an agent can
  # rewrite.
  if [[ ! "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Error: Gate model '$v' in $plan ## Sign-off is invalid (alias or model id — must start with a letter or digit; letters, digits, '.', '_', '-' only)." >&2
    return 2
  fi
  printf '%s\n' "$v"
}
