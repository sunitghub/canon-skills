#!/usr/bin/env bash
# src-key.sh — the release key of each prebuilt canon binary (t-8020). Source, don't execute. The one owner of what each binary
# is built from: tools/fetch-daemon.sh, scripts/release-daemon.sh and scripts/check-binaries-released.sh all ask here.
#
# The board and the daemon share one Go module (tools/canon-go), so a key is the paths ONE binary is built from (its cmd/, its
# internal/ package, internal/common and the module files), not the module folder: a board-only change keeps the daemon's key,
# so installs do not re-fetch, and Admin does not flag, an unchanged daemon.

# canon_component_paths <component>: its source paths, relative to the repo root.
canon_component_paths() {
  local m=tools/canon-go
  case "$1" in
    cockpit-daemon) echo "$m/go.mod $m/go.sum $m/cmd/cockpit-daemon $m/internal/daemon $m/internal/common $m/internal/events" ;;
    sprint-check) echo "$m/go.mod $m/go.sum $m/cmd/sprint-check $m/internal/board $m/internal/common $m/internal/events" ;;
    *) return 1 ;;
  esac
}

# canon_src_key <repo> <component> [<rev>]: the component's full key (40 hex) at rev (default HEAD). Prints nothing and returns 1
# when the component is unknown or one of its paths is not in that commit.
canon_src_key() {
  local repo="$1" comp="$2" rev="${3:-HEAD}" paths p id list=""
  paths="$(canon_component_paths "$comp")" || return 1
  for p in $paths; do
    id="$(git -C "$repo" rev-parse -q --verify "$rev:$p" 2>/dev/null)" || return 1
    list="$list$p $id"$'\n'
  done
  printf '%s' "$list" | git -C "$repo" hash-object --stdin
}
