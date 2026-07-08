#!/usr/bin/env bash
# tools/skills/cmd-init.sh — skills.sh init

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
