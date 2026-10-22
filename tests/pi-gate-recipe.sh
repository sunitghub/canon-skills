#!/usr/bin/env bash
# pi-gate-recipe (t-294e) — the pi close-gate recipe in skills/sprint/reference/complete.md stays hermetic and tool-limited. Every Pi
# gate is dispatched from that one command line, so a dropped flag silently loads extensions, MCP or extra tools into a gate that
# must be read-only and independent. Pins: the three hermetic flags, --no-extensions and --no-mcp, the --tools allowlist, an explicit
# <provider>/<model>, and no --exclude-tools denylist (it never removed a tool an extension adds or overrides).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/helpers.sh"
DOC="${PI_GATE_RECIPE_DOC:-$ROOT/skills/sprint/reference/complete.md}"

recipe="$(grep -m1 -E '^[[:space:]]+`pi -p ' "$DOC" || true)"
[[ -n "$recipe" ]] || fail "no \`pi -p …\` recipe line found in $DOC"

for flag in --no-session --no-context-files --no-skills --no-prompt-templates --no-extensions --no-mcp \
            '--tools read,bash,grep,find,ls' '--model "<provider>/'; do
  [[ "$recipe" == *"$flag"* ]] || fail "the pi gate recipe lacks $flag: $recipe"
done
[[ "$recipe" != *--exclude-tools* ]] || fail "the pi gate recipe still carries the --exclude-tools denylist: $recipe"

echo "pi-gate-recipe: ok"
