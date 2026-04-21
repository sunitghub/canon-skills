#!/usr/bin/env bash
# init-agent.sh — One-time setup for AI agent integration.
# Wires RTK, handoff, and quality hooks for Claude Code, Codex, and/or Pi.
# Idempotent — safe to run multiple times.
#
# Usage:
#   ./init-agent.sh              # interactive prompt
#   ./init-agent.sh claude       # Claude Code only
#   ./init-agent.sh codex        # Codex only
#   ./init-agent.sh pi           # Pi only
#   ./init-agent.sh all          # all three

set -euo pipefail

SCRIPT="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT" ]; do SCRIPT="$(readlink "$SCRIPT")"; done
SKILLS_ROOT="$(cd "$(dirname "$SCRIPT")" && pwd)"
SCRIPTS="$SKILLS_ROOT/scripts"
STANDARD_PATH="$HOME/Developer/AI-Skills"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[ok]${NC}   $*"; }
added(){ echo -e "  ${GREEN}[added]${NC} $*"; }
skip() { echo -e "  ${YELLOW}[skip]${NC}  $*"; }
fail() { echo -e "  ${RED}[fail]${NC}  $*"; }
step() { echo -e "\n${BOLD}$*${NC}"; }

# ── prerequisite checks ──────────────────────────────────────────────────────

check_path() {
  if [ "$SKILLS_ROOT" != "$STANDARD_PATH" ]; then
    echo -e "${YELLOW}Warning:${NC} This repo is at $SKILLS_ROOT"
    echo    "         Expected: $STANDARD_PATH"
    echo    "         Hook scripts in settings.json are hardcoded to the standard path."
    echo    "         Either move the repo or symlink: ln -s $SKILLS_ROOT $STANDARD_PATH"
    echo
    read -r -p "Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
  fi
}

check_rtk() {
  if ! command -v rtk &>/dev/null; then
    fail "rtk not found. Install with: brew install rtk"
    return 1
  fi
  ok "rtk $(rtk --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
}

check_python() {
  if ! command -v python3 &>/dev/null; then
    fail "python3 not found — required for settings.json merging"
    return 1
  fi
  ok "python3 available"
}

# ── pre-flight checks (is agent already configured?) ────────────────────────

is_claude_configured() {
  local settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || return 1
  python3 - "$settings" "$SCRIPTS" << 'PYEOF'
import json, sys, os
try:
    config = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
hooks = config.get("hooks", {})
required = [
    ("Stop",             "", f"{sys.argv[2]}/auto-handoff.sh"),
    ("UserPromptSubmit", "", f"{sys.argv[2]}/handoff-inject.sh"),
    ("PostToolUse", "Bash",  f"{sys.argv[2]}/auto-polish-trigger.sh"),
    ("PreToolUse",  "Bash",  f"{sys.argv[2]}/pre-commit-check.sh"),
]
for event, matcher, command in required:
    entries = hooks.get(event, [])
    entry = next((e for e in entries if e.get("matcher") == matcher), None)
    if not entry:
        sys.exit(1)
    # Expand ~ on both sides so ~/... and /Users/... forms match
    configured = [os.path.expanduser(h.get("command", "")) for h in entry.get("hooks", [])]
    if os.path.expanduser(command) not in configured:
        sys.exit(1)
# Also verify RTK's native hook is present in PreToolUse
rtk_present = any(
    "rtk" in h.get("command", "")
    for entry in hooks.get("PreToolUse", [])
    for h in entry.get("hooks", [])
)
if not rtk_present:
    sys.exit(1)
sys.exit(0)
PYEOF
}

is_codex_configured() {
  local agents="$HOME/.codex/AGENTS.md"
  [ -f "$agents" ] && grep -qF "RTK" "$agents" 2>/dev/null
}

is_pi_configured() {
  [ -f "$HOME/.pi/agent/extensions/handoff.ts" ]
}

# ── Claude Code ──────────────────────────────────────────────────────────────

merge_claude_hooks() {
  local settings="$HOME/.claude/settings.json"

  # Backup before modifying
  if [ -f "$settings" ]; then
    cp "$settings" "${settings}.bak"
    ok "Backed up → ${settings}.bak"
  fi

  python3 - "$settings" "$SCRIPTS" << 'PYEOF'
import json, sys, os

settings_path = sys.argv[1]
scripts_path  = sys.argv[2]

try:
    with open(settings_path) as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}

hooks = config.setdefault("hooks", {})

# Hooks to ensure are present (event → matcher → command)
desired = [
    ("Stop",             "", f"{scripts_path}/auto-handoff.sh"),
    ("UserPromptSubmit", "", f"{scripts_path}/handoff-inject.sh"),
    ("PostToolUse",   "Bash", f"{scripts_path}/auto-polish-trigger.sh"),
    ("PreToolUse",    "Bash", f"{scripts_path}/pre-commit-check.sh"),
]

for event, matcher, command in desired:
    event_list = hooks.setdefault(event, [])
    entry = next((e for e in event_list if e.get("matcher") == matcher), None)
    if entry is None:
        entry = {"matcher": matcher, "hooks": []}
        event_list.append(entry)
    entry_hooks = entry.setdefault("hooks", [])
    if any(h.get("command") == command for h in entry_hooks):
        print(f"exists\t{event}\t{os.path.basename(command)}")
    else:
        entry_hooks.append({"type": "command", "command": command})
        print(f"added\t{event}\t{os.path.basename(command)}")

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF
}

setup_claude() {
  step "Claude Code"

  if is_claude_configured; then
    ok "Already fully configured — nothing to do."
    return 0
  fi

  if ! command -v claude &>/dev/null; then
    fail "claude not found — install from https://claude.ai/code"
    return 1
  fi
  ok "claude installed"

  check_rtk || return 1
  check_python || return 1

  echo "  → Wiring RTK hook..."
  if rtk init -g --auto-patch > /dev/null 2>&1; then
    ok "RTK hook wired (rtk hook claude)"
  else
    skip "RTK hook already present"
  fi

  echo "  → Merging handoff + quality hooks into ~/.claude/settings.json..."
  while IFS=$'\t' read -r status event script; do
    if [ "$status" = "added" ]; then
      added "$event → $script"
    else
      skip "$event → $script (already present)"
    fi
  done < <(merge_claude_hooks)

  ok "Claude Code setup complete"
}

# ── Codex ─────────────────────────────────────────────────────────────────────

setup_codex() {
  step "Codex"

  if is_codex_configured; then
    ok "Already fully configured — nothing to do."
    return 0
  fi

  if ! command -v codex &>/dev/null; then
    fail "codex not found — install from https://github.com/openai/codex"
    return 1
  fi
  ok "codex installed"

  check_rtk || return 1

  echo "  → Wiring RTK for Codex..."
  if rtk init -g --codex --auto-patch > /dev/null 2>&1; then
    ok "RTK wired into ~/.codex/AGENTS.md"
  else
    skip "Already configured"
  fi

  ok "Codex setup complete"
}

# ── Pi ────────────────────────────────────────────────────────────────────────

setup_pi() {
  step "Pi"

  if is_pi_configured; then
    ok "Already fully configured — nothing to do."
    return 0
  fi

  local ext_src="$SKILLS_ROOT/extensions/pi/handoff.ts"
  local ext_dst_global="$HOME/.pi/agent/extensions/handoff.ts"

  if [ ! -f "$ext_src" ]; then
    fail "Extension not found: $ext_src"
    return 1
  fi

  echo "  Install scope:"
  echo "    [1] Global — applies to all Pi projects (~/.pi/agent/extensions/)"
  echo "    [2] Skip"
  read -r -p "  Choice [1]: " choice
  choice="${choice:-1}"

  case "$choice" in
    1)
      mkdir -p "$(dirname "$ext_dst_global")"
      cp "$ext_src" "$ext_dst_global"
      added "handoff.ts → $ext_dst_global"
      echo "  Run /reload in Pi to activate without restarting."
      ;;
    *)
      skip "Pi extension install skipped"
      ;;
  esac

  ok "Pi setup complete"
}

# ── dispatch ──────────────────────────────────────────────────────────────────

main() {
  echo -e "\n${BOLD}AI-Skills Agent Setup${NC}"
  echo    "━━━━━━━━━━━━━━━━━━━━━"

  check_path

  local agent="${1:-}"

  if [ -z "$agent" ]; then
    echo "Which agent(s) to set up?"
    echo "  [1] Claude Code"
    echo "  [2] Codex"
    echo "  [3] Pi"
    echo "  [4] All"
    echo
    read -r -p "Choice (no / <ENTER> to exit): " choice
    case "$choice" in
      1) agent="claude" ;;
      2) agent="codex"  ;;
      3) agent="pi"     ;;
      4) agent="all"    ;;
      "") echo "Exiting."; exit 0 ;;
      [nN]|[nN][oO]) echo "Exiting."; exit 0 ;;
      *) echo "Invalid choice."; exit 1 ;;
    esac
  fi

  case "$agent" in
    claude) setup_claude ;;
    codex)  setup_codex  ;;
    pi)     setup_pi     ;;
    all)    setup_claude; setup_codex; setup_pi ;;
    *)
      echo "Usage: $0 [claude|codex|pi|all]"
      exit 1
      ;;
  esac

  echo -e "\n${GREEN}${BOLD}Done.${NC} Next: register skills in your project:"
  echo    "  ~/Developer/AI-Skills/skills.sh add <skill> /path/to/your-project"
  echo    "  See guides/AI-Agents-Setup.md for the full per-project checklist."
  echo
}

main "$@"
