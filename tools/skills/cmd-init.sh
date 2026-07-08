#!/usr/bin/env bash
# tools/skills/cmd-init.sh — skills.sh init and uninstall

cmd_init() {
  echo "canon init — wiring agent hooks from: $SKILLS_ROOT"
  echo ""

  mkdir -p "$HOME/.config/canon"
  echo "$SKILLS_ROOT" > "$HOME/.config/canon/install_path"

  local any_fail=0

  echo "Claude Code (canon project hooks):"
  _init_claude "$SKILLS_ROOT/.claude/settings.json" || any_fail=1

  echo ""
  echo "Claude Code (migrate stale global hooks):"
  _uninstall_claude "$HOME/.claude/settings.json" || any_fail=1

  echo ""
  echo "Pi:"
  _init_pi || any_fail=1

  echo ""
  if [ "$any_fail" -eq 0 ]; then
    echo "Setup complete."
  else
    echo "Setup finished with errors — check items marked [fail] above."
  fi

  echo ""
  echo "Git hooks:"
  bash "$SKILLS_ROOT/scripts/install-hooks.sh" || any_fail=1
  _init_git_precommit "$SKILLS_ROOT" || any_fail=1

  offer_tkt_path

  echo ""
  echo "Before deleting this install, remove canon hooks with:"
  echo "  skills.sh uninstall"
}

cmd_uninstall() {
  echo "canon uninstall — removing agent hooks for: $SKILLS_ROOT"
  echo ""

  local any_fail=0

  echo "Registered projects:"
  if [ ! -f "$PROJECTS_FILE" ] || [ ! -s "$PROJECTS_FILE" ]; then
    echo "  [skip]  no registered projects"
  else
    local proj
    while IFS= read -r proj; do
      printf '  %s\n' "$proj"
    done < "$PROJECTS_FILE"
    echo ""
    while IFS= read -r proj; do
      if [ ! -d "$proj" ]; then
        echo "  [skip]  not found: $proj"
        continue
      fi
      for f in "$proj/CLAUDE.md" "$proj/AGENTS.md"; do
        strip_canon_project_imports "$f"
      done
      if [ -f "$proj/AGENTS.md" ] && grep -qF "AI-SKILLS:BEGIN" "$proj/AGENTS.md" 2>/dev/null; then
        awk '
          /<!-- AI-SKILLS:BEGIN -->/ { skip=1; next }
          /<!-- AI-SKILLS:END -->/   { skip=0; next }
          !skip                       { print }
        ' "$proj/AGENTS.md" > "$proj/AGENTS.md.tmp" && mv "$proj/AGENTS.md.tmp" "$proj/AGENTS.md"
      fi
      remove_skills_symlinks "$proj"
      _uninstall_claude "$proj/.claude/settings.json" 2>&1 | sed 's/^/  /' || true
      _uninstall_git_precommit "$proj" 2>&1 | sed 's/^/  /' || true
      echo "  [cleaned]  $proj"
    done < "$PROJECTS_FILE"
  fi

  echo ""
  echo "Claude Code (canon project hooks):"
  _uninstall_claude "$SKILLS_ROOT/.claude/settings.json" || any_fail=1
  _uninstall_git_precommit "$SKILLS_ROOT" || any_fail=1

  echo ""
  echo "Claude Code (stale global hooks):"
  _uninstall_claude "$HOME/.claude/settings.json" || any_fail=1

  echo ""
  echo "Pi:"
  _uninstall_pi || any_fail=1

  echo ""
  echo "Install path:"
  _uninstall_install_path || any_fail=1

  echo ""
  if [ "$any_fail" -eq 0 ]; then
    echo "Uninstall cleanup complete."
  else
    echo "Uninstall cleanup finished with errors — check items marked [fail] above."
  fi
  echo "You can now delete this install directory if desired:"
  echo "  rm -rf \"$SKILLS_ROOT\""
}
