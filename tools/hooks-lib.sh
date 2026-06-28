#!/usr/bin/env bash
# hooks-lib.sh — hook management helpers for skills.sh
# Sourced by skills.sh after SKILLS_ROOT is set. Not a standalone script.

_init_claude() {
  local settings="$1"
  local scripts="$SKILLS_ROOT/scripts"
  local tools="$SKILLS_ROOT/tools"

  mkdir -p "$(dirname "$settings")"

  # Capture current state before overwriting (for [added] vs [ok] reporting)
  local _had_handoff=0 _had_inject=0 _had_sprint=0 _had_precommit=0 _had_subagent=0
  if [[ -f "$settings" ]]; then
    grep -qF "auto-handoff.sh"     "$settings" 2>/dev/null && _had_handoff=1   || true
    grep -qF "handoff-inject.sh"   "$settings" 2>/dev/null && _had_inject=1    || true
    grep -qF "sprint-inject.sh"    "$settings" 2>/dev/null && _had_sprint=1    || true
    grep -qF "pre-commit-check.sh" "$settings" 2>/dev/null && _had_precommit=1 || true
    grep -qF "subagent-log.sh"     "$settings" 2>/dev/null && _had_subagent=1  || true
  fi

  # Write the complete hooks file (project settings.json is canon-owned — hooks only)
  cat > "$settings" << EOF
{
  "hooks": {
    "Stop": [
      {"matcher": "", "hooks": [{"type": "command", "command": "$scripts/auto-handoff.sh"}]}
    ],
    "UserPromptSubmit": [
      {"matcher": "", "hooks": [
        {"type": "command", "command": "$scripts/handoff-inject.sh"},
        {"type": "command", "command": "$scripts/sprint-inject.sh"}
      ]}
    ],
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "$scripts/pre-commit-check.sh"}]}
    ],
    "SubagentStop": [
      {"matcher": "", "hooks": [{"type": "command", "command": "$tools/subagent-log.sh"}]}
    ]
  }
}
EOF

  (( _had_handoff ))  && echo "  [ok]     Stop → auto-handoff.sh"           || echo "  [added]  Stop → auto-handoff.sh"
  (( _had_inject ))   && echo "  [ok]     UserPromptSubmit → handoff-inject.sh" || echo "  [added]  UserPromptSubmit → handoff-inject.sh"
  (( _had_sprint ))   && echo "  [ok]     UserPromptSubmit → sprint-inject.sh"  || echo "  [added]  UserPromptSubmit → sprint-inject.sh"
  (( _had_precommit )) && echo "  [ok]     PreToolUse → pre-commit-check.sh"    || echo "  [added]  PreToolUse → pre-commit-check.sh"
  (( _had_subagent )) && echo "  [ok]     SubagentStop → subagent-log.sh"       || echo "  [added]  SubagentStop → subagent-log.sh"
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
