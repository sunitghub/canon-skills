#!/usr/bin/env bash
# gate-scope-lib.sh (t-b7df) — a gate's scratch scope, made by the dispatcher instead of asked for in every gate prompt.
# A reviewer's `canon update` in a scratch clone once re-linked the user's registered projects (2026-10-09). The Claude Code Agent
# tool cannot set a subagent's environment, so the scope is enforced where the damage happens: gate-snapshot.sh `pre` creates a
# scratch dir and registers it; while one is live, the commands that act on registered projects (canon update, skills.sh
# add/refresh/remove/init/uninstall, canon uninstall, install.sh) refuse the user's REAL home and canon home, which `pre` recorded (t-9fb1); a scratch
# HOME/CANON_HOME (a test's, the gate's own scope) is allowed. A record made before t-9fb1 keeps the old rule (refuse unless both are inside the scope).
# Stale scopes (a gate that crashed before `post`) expire: older than CANON_GATE_SCOPE_TTL seconds (default 7200) or with the
# scratch dir gone. No scope registered = no change in behaviour. Sourced; defines functions only.

# Fixed under /tmp, not TMPDIR: a gate launched with its own TMPDIR (the pi recipe) must still find the registry. CANON_GATE_SCOPE_DIR relocates it (tests).
gate_scope_registry() { printf '%s' "${CANON_GATE_SCOPE_DIR:-/tmp/canon-gate-scope-$(id -u)}"; }

# _gate_scope_reg_ok <registry>: ours alone (a shared /tmp folder someone else pre-made, or a symlink, is never trusted: its records name what we delete)
_gate_scope_reg_ok() { [[ -d "$1" && ! -L "$1" && -O "$1" ]]; }

_gate_scope_key() {  # <snapshot path> -> a file name
  local abs; abs="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)/$(basename "$1")"
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$abs" | sha256sum | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then printf '%s' "$abs" | shasum -a 256 | cut -c1-16
  else printf '%s' "$abs" | cksum | cut -d' ' -f1; fi
}

# gate_scope_create <snapshot>: make and register the scratch scope; prints its directory.
gate_scope_create() {
  local reg dir; reg="$(gate_scope_registry)"
  mkdir -p "$reg" && chmod 700 "$reg" && _gate_scope_reg_ok "$reg" || return 1
  gate_scope_remove "$1"   # a second `pre` for the same snapshot replaces the first
  dir="$(mktemp -d)" || return 1
  mkdir -p "$dir/home" "$dir/canon" "$dir/tmp" "$dir/xdg"
  # t-9fb1: the dispatcher runs in the user's REAL environment, so it records the home and canon home the guard must keep a gate away from
  local rhome rcanon; _gate_scope_resolve "${HOME:-}"; rhome="$_GS_R"; _gate_scope_resolve "${CANON_HOME:-${HOME:-}/.canon}"; rcanon="$_GS_R"
  if [[ "$rhome$rcanon" == *$'\n'* ]]; then   # a newline cannot live in a line-based record: no home=/canon= lines, so the old rule applies (fail closed)
    printf 'dir=%s\ncreated=%s\n' "$dir" "$(date +%s)" > "$reg/$(_gate_scope_key "$1")"
  else
    printf 'dir=%s\ncreated=%s\nhome=%s\ncanon=%s\n' "$dir" "$(date +%s)" "$rhome" "$rcanon" > "$reg/$(_gate_scope_key "$1")"
  fi
  printf '%s' "$dir"
}

# gate_scope_remove <snapshot>: delete its scratch dir and registration (what `post` does).
gate_scope_remove() {
  local f dir; f="$(gate_scope_registry)/$(_gate_scope_key "$1")"
  _gate_scope_reg_ok "$(gate_scope_registry)" && [[ -f "$f" ]] || return 0
  dir="$(sed -n '/^dir=/{s/^dir=//p;q;}' "$f")"
  [[ -n "$dir" && -d "$dir" && "$(basename "$dir")" != / ]] && rm -rf "$dir"
  rm -f "$f"
}


# _gate_scope_resolve <path> — t-9fb1: result in $_GS_R, not printed ($(...) drops a trailing newline, which turns "h<NL>/inner" into "h/inner"; the cd step below keeps it with a sentinel). Where the path leads once every missing folder exists as a plain folder (what a later mkdir -p makes), nothing looked up that is
# not there: walks the components left to right, follows each existing one physically (a symlink to a folder inside the real home included) and pops `..` from the
# physical path so far. So "$link/nx/../.." with $link -> <real home>/sub resolves to the real home, though nx does not exist yet.
_gate_scope_resolve() {
  local p="$1" part cur="/" next rest
  [[ "$p" == /* ]] || p="$PWD/$p"
  # Split with parameter expansion, not `read` (read stops at a newline, and a newline can be in any component, in $PWD too).
  rest="${p#/}"
  while [[ -n "$rest" ]]; do
    part="${rest%%/*}"; if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    case "$part" in
      ''|.) ;;
      ..) cur="${cur%/*}"; [[ -n "$cur" ]] || cur="/" ;;
      *)  next="${cur%/}/$part"
          if [[ -d "$next" ]]; then cur="$(cd -P "$next" 2>/dev/null && { pwd -P; echo x; })" && cur="${cur%$'\n'x}" || cur="$next"; else cur="$next"; fi ;;
    esac
  done
  _GS_R="$cur"
}

_gate_scope_under() {  # <path> <dir>: the path is the dir or inside it (raw or physical spelling)
  local p="$1" d="$2" pp dp
  pp="$(cd -P "$p" 2>/dev/null && pwd -P)" || pp="$p"
  dp="$(cd -P "$d" 2>/dev/null && pwd -P)" || dp="$d"
  case "$p/" in "$d"/*) return 0 ;; esac
  case "$pp/" in "$dp"/*) return 0 ;; esac
  return 1
}

# gate_scope_guard <what>: 0 to go ahead; 1 (with a message) while a live gate scope exists and HOME or CANON_HOME is the real one it recorded.
gate_scope_guard() {
  local reg f dir created now ttl rhome rcanon rh rc home="${HOME:-}" chome="${CANON_HOME:-${HOME:-}/.canon}"
  reg="$(gate_scope_registry)"; _gate_scope_reg_ok "$reg" || return 0
  now="$(date +%s)"; ttl="${CANON_GATE_SCOPE_TTL:-7200}"
  for f in "$reg"/*; do
    [[ -f "$f" ]] || continue
    dir="$(sed -n '/^dir=/{s/^dir=//p;q;}' "$f")"; created="$(sed -n '/^created=/{s/^created=//p;q;}' "$f")"
    # stale: scratch dir gone, unreadable record, or older than the TTL (a gate that crashed before `post`)
    if [[ -z "$dir" || ! -d "$dir" || ! "$created" =~ ^[0-9]+$ ]] || (( now - created > ttl )); then
      [[ -n "$dir" && -d "$dir" && "$created" =~ ^[0-9]+$ ]] && rm -rf "$dir"
      rm -f "$f"; continue
    fi
    # t-9fb1: a record that names the real home and canon home refuses only those; any other HOME/CANON_HOME (a test's scratch dirs, the gate's own scope)
    # cannot touch the user's projects. A record without them (an older version) keeps the old rule: refuse unless both are inside the scope.
    rhome="$(sed -n '/^home=/{s/^home=//p;q;}' "$f")"; rcanon="$(sed -n '/^canon=/{s/^canon=//p;q;}' "$f")"
    if [[ -n "$rhome" && -n "$rcanon" ]]; then
      # Two checks, so a spelling cannot pass for another folder: -ef (the same device and inode: Unicode form and other case rules on some disks), and the
      # resolved path (a path that does not exist yet and leads to the real home through .. or a symlink: a later mkdir -p makes it, "$HOME/x/..").
      # The resolved path is compared by identity too (a Unicode-form spelling plus a missing folder: the text differs, the folder is the same).
      _gate_scope_resolve "$home"; rh="$_GS_R"; _gate_scope_resolve "$chome"; rc="$_GS_R"
      if [[ -n "$home" && ! "$home" -ef "$rhome" && ! "$chome" -ef "$rcanon" \
            && "$rh" != "$rhome" && "$rc" != "$rcanon" && ! "$rh" -ef "$rhome" && ! "$rc" -ef "$rcanon" ]]; then continue; fi
    elif _gate_scope_under "$home" "$dir" && _gate_scope_under "$chome" "$dir"; then continue; fi
    {
      echo "$1: refused. A canon close gate (reviewer/evaluator) is running and its scope is active ($dir)."
      if [[ -n "$rhome" && -n "$rcanon" ]]; then
        echo "  While it runs, commands that act on your REAL home and canon home are blocked, so a gate's probe cannot re-link or rewrite your projects (t-b7df);"
        echo "  a scratch HOME and CANON_HOME (a test, a gate's own scope) are fine. This is not a fault in your install."
      else
        echo "  This scope was made by an older canon: until it clears, commands that act on your registered projects are blocked unless HOME and CANON_HOME point inside it (t-b7df)."
        echo "  This is not a fault in your install."
      fi
      echo "  It clears when the gate ends (gate-snapshot.sh post), or on its own after ${ttl}s if the gate crashed."
      echo "  Run it again once the gate has finished."
    } >&2
    return 1
  done
  return 0
}
