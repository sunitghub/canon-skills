#!/usr/bin/env bash
# submodule-setup.sh — Wire canon-skills into a parent project when used as a git submodule.
#
# Usage (from parent project root):
#   bash canon-skills/scripts/submodule-setup.sh
#
# Or from anywhere inside the parent project:
#   /path/to/canon-skills/scripts/submodule-setup.sh
#
# What it does:
#   1. Adds canon's MCP server to the parent project's config files
#      (opencode.json, .vscode/mcp.json, .claude/settings.json)
#   2. Adds a reference to canon's AGENTS.md so agent instructions are picked up
#   3. Creates .tickets/ directory for sprint management
#   4. Guides you through adding skills

set -euo pipefail

# ── Locate canon root (this script lives in canon-skills/scripts/) ──────────
CANON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Detect parent project (caller's working directory) ──────────────────────
PARENT="${1:-$(pwd)}"
# Resolve to absolute path
case "$PARENT" in
  /*) ;;
  *)  PARENT="$(cd "$PARENT" && pwd)" ;;
esac

# If PARENT looks like it's inside canon itself, bail
if [ "$PARENT" = "$CANON" ] || [ "${PARENT#$CANON/}" != "$PARENT" ]; then
  echo "Error: target directory looks like it is inside canon-skills."
  echo "Run this script from your parent project's root."
  exit 1
fi

# ── Determine the relative path from parent to canon ───────────────────────
# We use python to compute the relative path reliably across platforms
REL=""
if command -v python3 &>/dev/null; then
  REL=$(python3 -c "
import os.path
try:
    p = os.path.relpath('$CANON', '$PARENT')
    print(p)
except ValueError:
    print('')
")
elif command -v python &>/dev/null; then
  REL=$(python -c "
import os.path
try:
    p = os.path.relpath('$CANON', '$PARENT')
    print(p)
except ValueError:
    print('')
")
fi

if [ -z "$REL" ]; then
  # Fallback: if on different drives (Windows), use absolute path
  REL="$CANON"
fi

echo "canon-skills  →  $CANON"
echo "parent project →  $PARENT"
echo "relative path  →  $REL"
echo ""

# ── 1. opencode.json ───────────────────────────────────────────────────────
OC_FILE="$PARENT/opencode.json"
OC_ENTRY='    "canon-mcp-server": {
      "type": "local",
      "command": ["python", "'"$REL"'/mcp-launcher.py"],
      "cwd": "'"$REL"'",
      "enabled": true
    }'

if [ -f "$OC_FILE" ]; then
  if grep -q 'canon-mcp-server' "$OC_FILE" 2>/dev/null; then
    echo "[opencode.json]  canon-mcp-server already configured"
  else
    echo "[opencode.json]  found — adding canon-mcp-server entry"
    # Insert into existing mcp block
    python3 -c "
import json, sys
path = '$OC_FILE'
with open(path) as f:
    cfg = json.load(f)
mcp = cfg.setdefault('mcp', {})
mcp['canon-mcp-server'] = {
    'type': 'local',
    'command': ['python', '$REL/mcp-launcher.py'],
    'cwd': '$REL',
    'enabled': True
}
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
print('  added canon-mcp-server')
"
  fi
else
  echo "[opencode.json]  creating with canon-mcp-server"
  cat > "$OC_FILE" <<OCEOF
{
  "\$schema": "https://opencode.ai/config.json",
  "mcp": {
$OC_ENTRY
  },
  "instructions": ["$REL/AGENTS.md"]
}
OCEOF
  echo "  created $OC_FILE"
fi

# ── 2. .vscode/mcp.json ────────────────────────────────────────────────────
VSCODE_DIR="$PARENT/.vscode"
VSCODE_FILE="$VSCODE_DIR/mcp.json"

mkdir -p "$VSCODE_DIR"

if [ -f "$VSCODE_FILE" ]; then
  if grep -q 'canon-mcp-server' "$VSCODE_FILE" 2>/dev/null; then
    echo "[.vscode/mcp.json]  canon-mcp-server already configured"
  else
    echo "[.vscode/mcp.json]  found — adding canon-mcp-server entry"
    python3 -c "
import json, sys
path = '$VSCODE_FILE'
with open(path) as f:
    cfg = json.load(f)
servers = cfg.setdefault('servers', {})
servers['canon-mcp-server'] = {
    'command': 'python',
    'args': ['$REL/mcp-launcher.py']
}
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
print('  added canon-mcp-server')
"
  fi
else
  echo "[.vscode/mcp.json]  creating with canon-mcp-server"
  cat > "$VSCODE_FILE" <<VSEOF
{
  "servers": {
    "canon-mcp-server": {
      "command": "python",
      "args": ["$REL/mcp-launcher.py"]
    }
  }
}
VSEOF
  echo "  created $VSCODE_FILE"
fi

# ── 3. .claude/settings.json (hooks + MCP) ─────────────────────────────────
CLAUDE_DIR="$PARENT/.claude"
CLAUDE_FILE="$CLAUDE_DIR/settings.json"

mkdir -p "$CLAUDE_DIR"

if [ -f "$CLAUDE_FILE" ]; then
  echo "[.claude/settings.json]  found — merging canon hooks + MCP"
else
  echo "[.claude/settings.json]  creating"
  echo '{}' > "$CLAUDE_FILE"
fi

python3 -c "
import json, os, sys
path = '$CLAUDE_FILE'
scripts = '$CANON/scripts'
rel = '$REL'

with open(path) as f:
    cfg = json.load(f)

# MCP server
mcp = cfg.setdefault('mcpServers', {})
mcp['canon-mcp-server'] = {
    'command': 'python',
    'args': [rel + '/mcp-launcher.py'],
    'env': {}
}

# Hooks
hooks = cfg.setdefault('hooks', {})
desired = [
    ('Stop',            '',                      f'{scripts}/auto-handoff.sh'),
    ('UserPromptSubmit','',                      f'{scripts}/handoff-inject.sh'),
    ('UserPromptSubmit','',                      f'{scripts}/sprint-inject.sh'),
    ('PreToolUse',      'Bash',                  f'{scripts}/pre-commit-check.sh'),
]
for event, matcher, command in desired:
    event_list = hooks.setdefault(event, [])
    entry = next((e for e in event_list if e.get('matcher') == matcher), None)
    if entry is None:
        entry = {'matcher': matcher, 'hooks': []}
        event_list.append(entry)
    entry_hooks = entry.setdefault('hooks', [])
    if not any(os.path.expanduser(h.get('command', '')) == command for h in entry_hooks):
        entry_hooks.append({'type': 'command', 'command': command})

# Prune empty hooks/events
for event in list(hooks.keys()):
    hooks[event] = [e for e in hooks[event] if e.get('hooks')]
    if not hooks[event]:
        del hooks[event]

with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')

print('  merged canon hooks + MCP server')
"

echo ""
# ── 4. AGENTS.md — reference canon instructions ────────────────────────────
AGENTS_FILE="$PARENT/AGENTS.md"
if [ -f "$AGENTS_FILE" ]; then
  if grep -q 'canon-skills' "$AGENTS_FILE" 2>/dev/null; then
    echo "[AGENTS.md]  canon reference already present"
  else
    echo "[AGENTS.md]  adding canon reference"
    cat >> "$AGENTS_FILE" <<AGEOF

<!-- canon: see canon-skills/AGENTS.md for full instructions -->
> This project uses canon-skills. Load it with: \`@$REL/AGENTS.md\`
AGEOF
    echo "  appended note to $AGENTS_FILE"
  fi
else
  echo "[AGENTS.md]  creating with canon reference"
  cat > "$AGENTS_FILE" <<AGEOF
# AGENTS.md

<!-- canon: agent workflow harness -->
See \`$REL/AGENTS.md\` for canon agent instructions.

@$REL/AGENTS.md
AGEOF
  echo "  created $AGENTS_FILE"
fi

# ── 5. Create .tickets/ directory for sprint management ────────────────────
mkdir -p "$PARENT/.tickets"
if [ -d "$PARENT/.tickets" ]; then
  echo "[.tickets/]  ensured"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  canon-skills wired into parent project"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  Next steps:"
echo "    1. Register a skill (from parent root):"
echo "       bash $REL/tools/skills.sh add sprint"
echo ""
echo "    2. Start your first sprint:"
echo "       bash $REL/tools/sprint start 'My sprint title'"
echo ""
echo "    3. Add canon/tools to your PATH:"
echo "       export PATH=\"\$PATH:$REL/tools\""
echo ""
echo "    4. Start the kanban dashboard:"
echo "       bash $REL/tools/sprint-check"
echo ""
echo "  To unregister canon from this project:"
echo "       bash $REL/tools/skills.sh uninstall"
echo ""
