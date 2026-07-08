#!/usr/bin/env bash
# tools/skills/cmd-help.sh — skills.sh help and usage text

cmd_help() {
  local skill="${1:-}"
  [ -z "$skill" ] && { echo "Usage: skills.sh help <skill-name>"; exit 1; }

  local skill_file
  skill_file=$(find_skill "$skill") || {
    echo "Error: skill '$skill' not found. Run 'skills.sh list' to see available skills."
    exit 1
  }

  local name desc summary category tags depends
  name=$(fm_field "$skill_file" name)
  desc=$(fm_field "$skill_file" description)
  summary=$(fm_field "$skill_file" summary)
  category=$(fm_field "$skill_file" category)
  tags=$(fm_field "$skill_file" tags | tr -d '[]' | sed 's/, */  /g')
  depends=$(fm_field "$skill_file" depends | tr -d '[]' | sed 's/, */  /g')

  local W=60
  local divider; divider=$(printf '\x1b[2m%*s\x1b[0m\n' "$W" '' | tr ' ' '─')

  printf '\n\x1b[1;96m%s\x1b[0m' "$name"
  [ -n "$category" ] && printf '  \x1b[2m[%s]\x1b[0m' "$category"
  printf '\n%s\n' "$divider"

  [ -n "$desc"    ] && printf '\x1b[1m%s\x1b[0m\n'    "$desc"
  [ -n "$summary" ] && printf '\n\x1b[2m%s\x1b[0m\n'  "$summary"
  [ -n "$tags"    ] && printf '\n\x1b[2mTags:\x1b[0m    %s\n' "$tags"
  [ -n "$depends" ] && printf '\n\x1b[2mDepends:\x1b[0m %s\n'   "$depends"

  printf '\n%s\n\n' "$divider"
}

_print_usage() {
  echo "Usage: skills.sh <command> [skill] [project-dir]"
  echo ""
  echo "  list                    Show all available skills"
  echo "  add <skill> [dir]       Register a skill into a project (default: cwd)"
  echo "  refresh [dir]           Prune stale @-imports and sync standards (default: cwd)"
  echo "  status [dir]            Show registered skills and detect issues (default: cwd)"
  echo "  remove <skill> [dir]    Unregister a skill from a project (default: cwd)"
  echo "  help <skill>            Show full documentation for a skill (alias: <skill> --h)"
  echo "  init                    Set up this canon install: wire project hooks,"
  echo "                          migrate stale global hooks, install Pi extension,"
  echo "                          record install path"
  echo "  uninstall               Remove canon hooks/config for this install"
  echo ""
  echo "Contributor commands (canon repo only): canon-dev.sh catalog|lint|delete"
}
