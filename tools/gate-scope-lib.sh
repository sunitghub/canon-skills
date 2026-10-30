#!/usr/bin/env bash
# gate-scope-lib.sh (t-b7df) — a gate's scratch scope, made by the dispatcher instead of asked for in every gate prompt.
# A reviewer's `canon update` in a scratch clone once re-linked the user's registered projects (2026-10-09). The Claude Code Agent
# tool cannot set a subagent's environment, so the scope is enforced where the damage happens: gate-snapshot.sh `pre` creates a
# scratch dir and registers it; while one is live, the commands that act on registered projects (canon update, skills.sh
# add/refresh/remove/init/uninstall, canon uninstall, install.sh) refuse unless HOME and CANON_HOME point inside it.
# Stale scopes (a gate that crashed before `post`) expire: older than CANON_GATE_SCOPE_TTL seconds (default 7200) or with the
# scratch dir gone. No scope registered = no change in behaviour. Sourced; defines functions only.

gate_scope_registry() { printf '%s/canon-gate-scope-%s' "${TMPDIR:-/tmp}" "$(id -u)"; }

_gate_scope_key() {  # <snapshot path> -> a file name
  local abs; abs="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)/$(basename "$1")"
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$abs" | sha256sum | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then printf '%s' "$abs" | shasum -a 256 | cut -c1-16
  else printf '%s' "$abs" | cksum | cut -d' ' -f1; fi
}

# gate_scope_create <snapshot>: make and register the scratch scope; prints its directory.
gate_scope_create() {
  local reg dir; reg="$(gate_scope_registry)"
  mkdir -p "$reg" || return 1
  gate_scope_remove "$1"   # a second `pre` for the same snapshot replaces the first
  dir="$(mktemp -d)" || return 1
  mkdir -p "$dir/home" "$dir/canon" "$dir/tmp" "$dir/xdg"
  printf 'dir=%s\ncreated=%s\n' "$dir" "$(date +%s)" > "$reg/$(_gate_scope_key "$1")"
  printf '%s' "$dir"
}

# gate_scope_remove <snapshot>: delete its scratch dir and registration (what `post` does).
gate_scope_remove() {
  local f dir; f="$(gate_scope_registry)/$(_gate_scope_key "$1")"
  [[ -f "$f" ]] || return 0
  dir="$(sed -n 's/^dir=//p;T;q' "$f")"
  [[ -n "$dir" && -d "$dir" && "$(basename "$dir")" != / ]] && rm -rf "$dir"
  rm -f "$f"
}

_gate_scope_under() {  # <path> <dir>: the path is the dir or inside it (raw or physical spelling)
  local p="$1" d="$2" pp dp
  pp="$(cd -P "$p" 2>/dev/null && pwd -P)" || pp="$p"
  dp="$(cd -P "$d" 2>/dev/null && pwd -P)" || dp="$d"
  case "$p/" in "$d"/*) return 0 ;; esac
  case "$pp/" in "$dp"/*) return 0 ;; esac
  return 1
}

# gate_scope_guard <what>: 0 to go ahead; 1 (with a message) while a live gate scope exists and HOME/CANON_HOME are outside it.
gate_scope_guard() {
  local reg f dir created now ttl home="${HOME:-}" chome="${CANON_HOME:-${HOME:-}/.canon}"
  reg="$(gate_scope_registry)"; [[ -d "$reg" ]] || return 0
  now="$(date +%s)"; ttl="${CANON_GATE_SCOPE_TTL:-7200}"
  for f in "$reg"/*; do
    [[ -f "$f" ]] || continue
    dir="$(sed -n 's/^dir=//p;T;q' "$f")"; created="$(sed -n 's/^created=//p;T;q' "$f")"
    # stale: scratch dir gone, unreadable record, or older than the TTL (a gate that crashed before `post`)
    if [[ -z "$dir" || ! -d "$dir" || ! "$created" =~ ^[0-9]+$ ]] || (( now - created > ttl )); then
      [[ -n "$dir" && -d "$dir" && "$created" =~ ^[0-9]+$ ]] && rm -rf "$dir"
      rm -f "$f"; continue
    fi
    if _gate_scope_under "$home" "$dir" && _gate_scope_under "$chome" "$dir"; then continue; fi
    {
      echo "$1: refused. A canon close gate (reviewer/evaluator) is running and its scope is active ($dir)."
      echo "  While it runs, commands that act on your registered projects are blocked unless HOME and CANON_HOME point inside that scope,"
      echo "  so a gate's probe cannot re-link or rewrite your projects (t-b7df). This is not a fault in your install."
      echo "  It clears when the gate ends (gate-snapshot.sh post), or on its own after ${ttl}s if the gate crashed."
      echo "  Run it again once the gate has finished."
    } >&2
    return 1
  done
  return 0
}
