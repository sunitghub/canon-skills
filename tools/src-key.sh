#!/usr/bin/env bash
# src-key.sh — the release key of canon's prebuilt program, canon-go (t-8020, t-bdb0). Source, don't execute. The one owner of what it
# is built from: tools/fetch-daemon.sh, scripts/release-daemon.sh, scripts/build-zip.sh and scripts/check-binaries-released.sh all ask here.
#
# canon-go is one Go program (tools/canon-go/cmd/canon-go) holding the board and the daemon. Each part keeps its own key (the paths that
# part is built from: cmd/canon-go, its internal/ package, internal/common and the module files): the daemon part's key is stamped into
# the binary (-X main.daemonKey), so a board-only change keeps it and Admin does not flag an unchanged running daemon as stale. The
# release key, `canon-go`, is the hash of both part keys: any change to either releases a new binary.

# canon_component_paths <part>: the source paths of `daemon` or `board`, relative to the repo root.
canon_component_paths() {
  local m=tools/canon-go
  case "$1" in
    daemon) echo "$m/go.mod $m/go.sum $m/cmd/canon-go $m/internal/daemon $m/internal/common $m/internal/events $m/internal/term $m/internal/settings" ;;
    board) echo "$m/go.mod $m/go.sum $m/cmd/canon-go $m/internal/board $m/internal/common $m/internal/events $m/internal/settings" ;;
    *) return 1 ;;
  esac
}

# canon_src_key <repo> <daemon|board|canon-go> [<rev>]: the full key (40 hex) at rev (default HEAD). Prints nothing and returns 1
# when the name is unknown or one of its paths is not in that commit.
canon_src_key() {
  local repo="$1" comp="$2" rev="${3:-HEAD}" paths p id list="" d b
  if [ "$comp" = canon-go ]; then
    d="$(canon_src_key "$repo" daemon "$rev")" && b="$(canon_src_key "$repo" board "$rev")" || return 1
    printf 'daemon %s\nboard %s\n' "$d" "$b" | git -C "$repo" hash-object --stdin
    return
  fi
  paths="$(canon_component_paths "$comp")" || return 1
  for p in $paths; do
    id="$(git -C "$repo" rev-parse -q --verify "$rev:$p" 2>/dev/null)" || return 1
    list="$list$p $id"$'\n'
  done
  printf '%s' "$list" | git -C "$repo" hash-object --stdin
}

# canon_ldflags <repo> [<rev>]: the -X stamps every canon-go build carries: the commit stamp (the release key's first 8, which
# `canon-go --version` prints and fetch-daemon's up-to-date check reads) and the daemon part's full key. Returns 1 if a key cannot be named.
canon_ldflags() {
  local full dk
  full="$(canon_src_key "$1" canon-go "${2:-HEAD}")" && dk="$(canon_src_key "$1" daemon "${2:-HEAD}")" || return 1
  printf '%s\n' "-X main.commit=${full:0:8} -X main.daemonKey=$dk"
}
