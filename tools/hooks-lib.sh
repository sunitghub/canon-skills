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

  local _canon_scripts=(auto-handoff.sh handoff-inject.sh sprint-inject.sh pre-commit-check.sh subagent-log.sh auto-polish-trigger.sh guard-managed-files.sh)
  local removed=0
  for _n in "${_canon_scripts[@]}"; do
    local c
    c=$(grep -cF "$_n" "$settings" 2>/dev/null) || c=0
    removed=$(( removed + c ))
  done

  if [ "$removed" -eq 0 ]; then
    echo "  [ok]     no canon Claude hooks found"
    return 0
  fi

  local compact_tmp="${settings}.canon-compact"
  cp "$settings" "$compact_tmp"
  for _n in "${_canon_scripts[@]}"; do
    sed -E "s/\\{[^{}]*\\\"type\\\"[[:space:]]*:[[:space:]]*\\\"command\\\"[^{}]*\\\"command\\\"[[:space:]]*:[[:space:]]*\\\"[^\\\"]*${_n}\\\"[^{}]*\\}[[:space:]]*,?//g" "$compact_tmp" > "${compact_tmp}.next"
    mv "${compact_tmp}.next" "$compact_tmp"
  done
  sed -E 's/,[[:space:]]*([]}])/\1/g; s/([[\{])[[:space:]]*,/\1/g' "$compact_tmp" > "${compact_tmp}.next"
  mv "${compact_tmp}.next" "$compact_tmp"

  local tmp="${settings}.canon-tmp"
  awk '
    function push(line) { out[++n] = line }
    function flush_buffer(   i) {
      if (!drop) {
        for (i = 1; i <= blen; i++) push(buf[i])
      }
      blen = 0
      drop = 0
      capture = 0
    }
    function canon_line(line) {
      return line ~ /(auto-handoff|handoff-inject|sprint-inject|pre-commit-check|subagent-log|auto-polish-trigger|guard-managed-files)\.sh/
    }
    {
      if ($0 ~ /"type"[[:space:]]*:[[:space:]]*"command"/ && $0 ~ /"command"[[:space:]]*:/) {
        if (!canon_line($0)) push($0)
        next
      }
      if (capture) {
        buf[++blen] = $0
        if (canon_line($0)) drop = 1
        if ($0 ~ /^[[:space:]]*}[,]?[[:space:]]*$/) flush_buffer()
        next
      }
      if ($0 ~ /"type"[[:space:]]*:[[:space:]]*"command"/ && n > 0) {
        capture = 1
        blen = 0
        buf[++blen] = out[n]
        n--
        buf[++blen] = $0
        next
      }
      push($0)
    }
    END {
      if (capture) flush_buffer()
      for (i = 1; i <= n; i++) {
        if (out[i] ~ /^[[:space:]]*[]}][][,]?[[:space:]]*$/ && i > 1) {
          sub(/,[[:space:]]*$/, "", out[i - 1])
        }
      }
      for (i = 1; i <= n; i++) print out[i]
    }
  ' "$compact_tmp" > "$tmp"
  sed -E 's/,[[:space:]]*([]}])/\1/g; s/([[\{])[[:space:]]*,/\1/g' "$tmp" > "${tmp}.next"
  mv "${tmp}.next" "$tmp"
  mv "$tmp" "$settings"
  rm -f "$compact_tmp"

  # Prune leftover empty structures the text-based removal above can create
  # (empty matcher["hooks"] arrays, empty event-type arrays, an empty "hooks"
  # object) — JSON-aware so it can't corrupt unrelated keys. python3 is
  # already a hard dependency elsewhere in this codebase (tools/sprint's
  # eval-gate timestamp matching), not a new one introduced here.
  python3 - "$settings" << 'PYEOF'
import json, sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

hooks = data.get("hooks")
if isinstance(hooks, dict):
    for event, entries in list(hooks.items()):
        if not isinstance(entries, list):
            continue
        kept = [e for e in entries if not (isinstance(e, dict) and isinstance(e.get("hooks"), list) and len(e["hooks"]) == 0)]
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if not hooks:
        del data["hooks"]

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF

  echo "  [removed]  $removed Claude hook(s)"
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
