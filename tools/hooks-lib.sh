#!/usr/bin/env bash
# hooks-lib.sh — hook management helpers for skills.sh
# Sourced by skills.sh after SKILLS_ROOT is set. Not a standalone script.

_init_claude() {
  local settings="$1"
  # canon no longer installs any Claude Code hooks (Stop/UserPromptSubmit/PreToolUse/
  # SubagentStop) — those guardrails moved to a git-native pre-commit hook
  # (_init_git_precommit) and an explicit CLI step (tools/subagent-log.sh), so this
  # settings.json is never written destructively. This call is migration-only: it
  # removes any of the 5 legacy hook entries left by an older canon install, via
  # _uninstall_claude's existing surgical-removal logic, and touches nothing else
  # in the file.
  if [[ ! -f "$settings" ]]; then
    echo "  [ok]     no Claude Code hooks needed"
    return 0
  fi
  _uninstall_claude "$settings"
}

_init_git_precommit() {
  local project_dir="$1"
  local hooks_dir="$project_dir/.git/hooks"
  local hook="$hooks_dir/pre-commit"
  local marker="# canon-managed-pre-commit-hook"
  local template="$SKILLS_ROOT/scripts/pre-commit-hook-template.sh"

  if [[ ! -d "$hooks_dir" ]]; then
    echo "  [skip]  $hook not found (not a git repo?)"
    return 0
  fi

  if [[ ! -f "$template" ]]; then
    echo "  [fail]  template not found: $template"
    return 1
  fi

  if [[ -f "$hook" ]] && ! grep -qF "$marker" "$hook" 2>/dev/null; then
    echo "  [fail]  $hook already exists and is not canon-managed."
    echo "          Refusing to overwrite an existing pre-commit hook. To get canon's"
    echo "          checks (ticket-close guard, high-risk sign-off gate, test suite,"
    echo "          wrapup reminder), merge the contents of $template into your hook"
    echo "          by hand, or move your existing hook aside and re-run."
    return 1
  fi

  {
    echo "#!/usr/bin/env bash"
    echo "$marker"
    echo "# Installed by skills.sh add/init — re-run to update, do not hand-edit."
    echo "CANON_ROOT=\"$SKILLS_ROOT\""
    cat "$template"
  } > "$hook"
  chmod +x "$hook"
  echo "  [ok]     .git/hooks/pre-commit installed"
}

_uninstall_git_precommit() {
  local project_dir="$1"
  local hook="$project_dir/.git/hooks/pre-commit"
  local marker="# canon-managed-pre-commit-hook"

  if [[ ! -f "$hook" ]]; then
    echo "  [skip]  $hook not found"
    return 0
  fi
  if ! grep -qF "$marker" "$hook" 2>/dev/null; then
    echo "  [warn]  $hook did not look canon-managed; skipped"
    return 0
  fi
  rm -f "$hook"
  echo "  [removed]  .git/hooks/pre-commit"
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

  # Single Python pass: remove all canon hook entries by matching their
  # "command" field against known script names, then prune any leftover
  # empty structures (empty hooks arrays, empty event-type arrays, empty
  # "hooks" object). Replaces the former sed→awk→sed chain with proper
  # json.load/dump — correct by construction, no regex-based JSON editing.
  local result
  result="$(python3 - "$settings" << 'PYEOF'
import json, sys

CANON_SCRIPTS = [
    "auto-handoff.sh", "handoff-inject.sh", "sprint-inject.sh",
    "pre-commit-check.sh", "subagent-log.sh", "auto-polish-trigger.sh",
    "guard-managed-files.sh"
]

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

removed = 0
pruned = False
hooks = data.get("hooks")
if isinstance(hooks, dict):
    for event, entries in list(hooks.items()):
        if not isinstance(entries, list):
            continue
        kept = []
        for entry in entries:
            if not isinstance(entry, dict):
                kept.append(entry)
                continue
            # Check top-level command entries (single-line hook format)
            cmd = entry.get("command", "")
            if entry.get("type") == "command" and any(s in cmd for s in CANON_SCRIPTS):
                removed += 1
                continue
            # Check nested hooks arrays (matcher format)
            inner_hooks = entry.get("hooks")
            if isinstance(inner_hooks, list):
                inner_kept = []
                for h in inner_hooks:
                    if isinstance(h, dict) and h.get("type") == "command":
                        hcmd = h.get("command", "")
                        if any(s in hcmd for s in CANON_SCRIPTS):
                            removed += 1
                            continue
                    inner_kept.append(h)
                if inner_kept:
                    entry["hooks"] = inner_kept
                    kept.append(entry)
                else:
                    # Empty hooks array — prune this matcher entry
                    pruned = True
            else:
                kept.append(entry)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
            if removed == 0:
                pruned = True
    if not hooks:
        del data["hooks"]
        if removed == 0:
            pruned = True

changed = removed > 0 or pruned
if changed:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

# Output: "removed:<count>" or "pruned" or "none"
if removed > 0:
    print(f"removed:{removed}")
elif pruned:
    print("pruned")
else:
    print("none")
PYEOF
)"

  case "$result" in
    removed:*) echo "  [removed]  ${result#removed:} Claude hook(s)" ;;
    pruned)    echo "  [cleaned]  removed leftover empty hook skeleton" ;;
    *)         echo "  [ok]     no canon Claude hooks found" ;;
  esac
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
