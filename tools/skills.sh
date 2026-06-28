#!/usr/bin/env bash
# skills.sh — skill registration and install lifecycle for canon projects
# Dispatcher: sources all sub-scripts, then dispatches to cmd_* functions.
set -euo pipefail

SCRIPT="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT" ]; do SCRIPT="$(readlink "$SCRIPT")"; done
SKILLS_ROOT="$(cd "$(dirname "$SCRIPT")/.." && pwd)"

# shellcheck source=tools/skills/lib.sh
source "$(dirname "$SCRIPT")/skills/lib.sh"
# shellcheck source=tools/skills/project.sh
source "$(dirname "$SCRIPT")/skills/project.sh"
# shellcheck source=tools/skills/agents.sh
source "$(dirname "$SCRIPT")/skills/agents.sh"
# shellcheck source=tools/skills/display.sh
source "$(dirname "$SCRIPT")/skills/display.sh"
# shellcheck source=tools/skills/commands.sh
source "$(dirname "$SCRIPT")/skills/commands.sh"

# Handle: skills.sh --scan [dir]  or  skills.sh [dir] --scan
_scan_dir=""
_remaining_args=()
for _arg in "$@"; do
  if [ "$_arg" = "--scan" ]; then
    _scan_dir="${_scan_dir:-__pending__}"
  elif [ -z "$_scan_dir" ] || [ "$_scan_dir" = "__pending__" ]; then
    if [ "$_scan_dir" = "__pending__" ] && [ -d "$_arg" ]; then
      _scan_dir="$_arg"
    else
      _remaining_args+=("$_arg")
    fi
  else
    _remaining_args+=("$_arg")
  fi
done

if [ -n "$_scan_dir" ]; then
  _scan_dir="${_scan_dir/__pending__/$(pwd)}"
  set -- "${_remaining_args[@]+"${_remaining_args[@]}"}"
  cmd_status "$_scan_dir"
  exit $?
fi

cmd="${1:-list}"
shift || true

# Handle: skills <skill-name> --h / -h / --help
case "${1:-}" in
  --h|--help|-h) cmd_help "$cmd"; exit 0 ;;
esac

case "$cmd" in
  list)    cmd_list    "$@" ;;
  add)     cmd_add     "$@" ;;
  refresh) cmd_refresh "$@" ;;
  status)  cmd_status  "$@" ;;
  remove)  cmd_remove  "$@" ;;
  help)    cmd_help    "$@" ;;
  init)    cmd_init    "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  catalog|lint|delete)
    echo "Error: '$cmd' is a contributor command — use canon-dev.sh instead."
    echo "  canon-dev.sh $cmd $*"
    exit 1
    ;;
  *)
    _print_usage
    exit 1
    ;;
esac
