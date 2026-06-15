#!/usr/bin/env bash
# hooks-lib.sh — hook management helpers for skills.sh
# Sourced by skills.sh after SKILLS_ROOT is set. Not a standalone script.

_init_claude() {
  local settings="$1"
  local scripts="$SKILLS_ROOT/scripts"

  if ! command -v claude &>/dev/null; then
    echo "  [skip]  claude not installed"
    return 0
  fi
  if ! command -v python3 &>/dev/null; then
    echo "  [fail]  python3 required for settings.json merge"
    return 1
  fi

  local py_script
  py_script=$(cat << 'PYEOF'
import json, sys, os
settings_path = sys.argv[1]
scripts_path  = sys.argv[2]
try:
    with open(settings_path) as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}
hooks = config.setdefault("hooks", {})
desired = [
    ("Stop",            "",     f"{scripts_path}/auto-handoff.sh"),
    ("UserPromptSubmit","",     f"{scripts_path}/handoff-inject.sh"),
    ("UserPromptSubmit","",     f"{scripts_path}/sprint-inject.sh"),
    ("PreToolUse",      "Bash", f"{scripts_path}/pre-commit-check.sh"),
]
stale = {
    f"{scripts_path}/auto-polish-trigger.sh",
    f"{scripts_path}/guard-managed-files.sh",
}
for event, entries in list(hooks.items()):
    for entry in entries:
        entry["hooks"] = [
            h for h in entry.get("hooks", [])
            if os.path.expanduser(h.get("command", "")) not in stale
        ]
for event, matcher, command in desired:
    event_list = hooks.setdefault(event, [])
    entry = next((e for e in event_list if e.get("matcher") == matcher), None)
    if entry is None:
        entry = {"matcher": matcher, "hooks": []}
        event_list.append(entry)
    entry_hooks = entry.setdefault("hooks", [])
    if any(os.path.expanduser(h.get("command", "")) == command for h in entry_hooks):
        print(f"exists\t{event}\t{os.path.basename(command)}")
    else:
        entry_hooks.append({"type": "command", "command": command})
        print(f"added\t{event}\t{os.path.basename(command)}")
# Prune entries left with no hooks and empty events so dead matchers don't linger.
for event in list(hooks.keys()):
    hooks[event] = [e for e in hooks[event] if e.get("hooks")]
    if not hooks[event]:
        del hooks[event]
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF
)

  local hook_output added=0
  hook_output=$(python3 - "$settings" "$scripts" <<< "$py_script")
  while IFS=$'\t' read -r status event script; do
    if [ "$status" = "added" ]; then
      echo "  [added]  $event → $script"
      (( added++ )) || true
    else
      echo "  [ok]     $event → $script"
    fi
  done <<< "$hook_output"
}

_init_pi() {
  local ext_src="$SKILLS_ROOT/extensions/pi/handoff.ts"
  local ext_dst="$HOME/.pi/agent/extensions/handoff.ts"
  if [ ! -d "$HOME/.pi" ]; then
    echo "  [skip]  pi not installed"
    return 0
  fi
  if [ ! -f "$ext_src" ]; then
    echo "  [fail]  extension not found: $ext_src"
    return 1
  fi
  mkdir -p "$(dirname "$ext_dst")"
  if [ -f "$ext_dst" ] && cmp -s "$ext_src" "$ext_dst"; then
    echo "  [ok]     handoff extension already installed"
  else
    cp "$ext_src" "$ext_dst"
    echo "  [added]  handoff.ts → $ext_dst"
    echo "           Run /reload in Pi to activate"
  fi
}

_uninstall_claude() {
  local settings="$1"

  if [ ! -f "$settings" ]; then
    echo "  [skip]  $settings not found"
    return 0
  fi
  if ! command -v python3 &>/dev/null; then
    echo "  [fail]  python3 required for settings.json cleanup"
    return 1
  fi

  local py_script
  py_script=$(cat << 'PYEOF'
import json, os, sys
settings_path = sys.argv[1]
skills_root = os.path.realpath(sys.argv[2])
scripts_path = os.path.join(skills_root, "scripts")
commands = {
    os.path.realpath(os.path.join(scripts_path, name))
    for name in (
        "auto-handoff.sh",
        "handoff-inject.sh",
        "sprint-inject.sh",
        "pre-commit-check.sh",
        "auto-polish-trigger.sh",
        "guard-managed-files.sh",
    )
}
try:
    with open(settings_path) as f:
        config = json.load(f)
except json.JSONDecodeError:
    print("invalid")
    sys.exit(0)
hooks = config.get("hooks")
if not isinstance(hooks, dict):
    print("removed\t0")
    sys.exit(0)
removed = 0
for event in list(hooks.keys()):
    entries = hooks.get(event)
    if not isinstance(entries, list):
        continue
    kept_entries = []
    for entry in entries:
        entry_hooks = entry.get("hooks", []) if isinstance(entry, dict) else []
        kept_hooks = []
        for hook in entry_hooks:
            command = os.path.realpath(os.path.expanduser(hook.get("command", "")))
            if command in commands:
                removed += 1
            else:
                kept_hooks.append(hook)
        if kept_hooks:
            entry["hooks"] = kept_hooks
            kept_entries.append(entry)
    if kept_entries:
        hooks[event] = kept_entries
    else:
        del hooks[event]
if not hooks:
    config.pop("hooks", None)
with open(settings_path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
print(f"removed\t{removed}")
PYEOF
)

  local result status count
  result=$(python3 - "$settings" "$SKILLS_ROOT" <<< "$py_script")
  status="${result%%$'\t'*}"
  count="${result#*$'\t'}"
  if [ "$status" = "invalid" ]; then
    echo "  [warn]  $settings is invalid JSON; skipped"
  elif [ "${count:-0}" -gt 0 ]; then
    echo "  [removed]  $count Claude hook(s)"
  else
    echo "  [ok]     no canon Claude hooks found"
  fi
}

_uninstall_pi() {
  local ext_dst="$HOME/.pi/agent/extensions/handoff.ts"
  if [ ! -f "$ext_dst" ]; then
    echo "  [skip]  Pi handoff extension not found"
    return 0
  fi
  if grep -q 'install_path' "$ext_dst" && grep -q 'auto-handoff.sh' "$ext_dst"; then
    rm -f "$ext_dst"
    echo "  [removed]  Pi handoff extension"
  else
    echo "  [warn]  Pi handoff extension did not look canon-managed; skipped"
  fi
}

_uninstall_install_path() {
  local config="$HOME/.config/canon/install_path"
  local projects="$HOME/.config/canon/projects"
  if [ ! -f "$config" ]; then
    echo "  [skip]  ~/.config/canon/install_path not found"
  else
    local installed
    installed="$(cat "$config")"
    if [ "$installed" = "$SKILLS_ROOT" ]; then
      rm -f "$config"
      echo "  [removed]  install_path"
    else
      echo "  [warn]  install_path points at $installed; expected $SKILLS_ROOT"
    fi
  fi
  if [ -f "$projects" ]; then
    rm -f "$projects"
    echo "  [removed]  projects"
  fi
  rmdir "$HOME/.config/canon" 2>/dev/null || true
}
