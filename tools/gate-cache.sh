#!/usr/bin/env bash
# gate-cache.sh — opt-in verdict cache for the headless graders
# (`sprint-headless`, `sprint-headless-eval`). Sourced, not executed.
#
# WHY opt-in, never on by default: caching is a cost optimization, and canon
# never *silently* reduces gate assurance. A cache HIT reuses a prior verdict
# without re-running the fresh-context grader, so it must be an explicit,
# auditable choice (same class as demo / eval_override / Gate model:) and it
# must be LOUD when it happens. Enable with the tool's `--cache` flag or
# `CANON_GATE_CACHE=1`; `--no-cache` always wins.
#
# WHAT makes a cached verdict safe to reuse: the entry is keyed on the exact
# `git diff <base> HEAD` CONTENT plus the criteria text, model, and gate-set.
# Any change to any of those changes the key, so an edited diff/criteria/model
# can never hit a stale entry. This mirrors eval.md's "cached evidence counts
# only when source, timestamp, freshness window, and why-acceptable are stated"
# rule — a cached verdict records exactly those and is reused only while the
# diff it was graded against is byte-identical.
#
# Entry format (`<root>/.canon-cache/gates/<key>.txt`):
#   verdict: PASS|FAIL          <- convenience; authoritative verdict is in the body
#   session: <source session>
#   timestamp: <ISO-8601 UTC>
#   diffhash: <key>
#   model: <model or "default">
#   gateset: <e.g. eval-only | reviewer+eval+security>
#   ===REPORT===
#   <full relayed grader output, verbatim>

CANON_GATE_CACHE_VERSION="1"

# gate_cache_dir <root> — cache directory (not created here).
gate_cache_dir() { printf '%s/.canon-cache/gates' "$1"; }

# gate_cache_path <root> <key> — full path to one entry file.
gate_cache_path() { printf '%s/%s.txt' "$(gate_cache_dir "$1")" "$2"; }

# _gate_cache_sha — sha256 hex of stdin (portable: sha256sum or shasum).
_gate_cache_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  else
    echo "gate-cache: no sha256sum or shasum found — cannot compute cache key" >&2
    return 1
  fi
}

# gate_cache_key <root> <base_ref> <criteria_text> <model> <gateset>
# Prints the sha256 cache key. Hashes the diff CONTENT (not just names) so a
# same-filename content edit invalidates; plus criteria, model, gateset, and a
# format version. Deliberately excludes the base-ref NAME: two bases that yield
# a byte-identical diff grade identically, so they should share an entry.
gate_cache_key() {
  local root="$1" base="$2" criteria="$3" model="$4" gateset="$5"
  local diff
  diff="$(cd "$root" && git diff "$base" HEAD 2>/dev/null)" || diff=""
  {
    printf 'v=%s\n' "$CANON_GATE_CACHE_VERSION"
    printf 'model=%s\n' "${model:-default}"
    printf 'gateset=%s\n' "$gateset"
    printf '===CRITERIA===\n%s\n' "$criteria"
    printf '===DIFF===\n%s\n' "$diff"
  } | _gate_cache_sha
}

# gate_cache_has <root> <key> — exit 0 if a cache entry exists (HIT), 1 if MISS.
gate_cache_has() { [[ -f "$(gate_cache_path "$1" "$2")" ]]; }

# gate_cache_header <root> <key> <field> — print one header field's value.
gate_cache_header() {
  local f; f="$(gate_cache_path "$1" "$2")"
  [[ -f "$f" ]] || return 1
  awk -v field="$3:" '
    $0 == "===REPORT===" { exit }
    index($0, field) == 1 { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
  ' "$f"
}

# gate_cache_get <root> <key> — print the stored report body (after ===REPORT===).
gate_cache_get() {
  local f; f="$(gate_cache_path "$1" "$2")"
  [[ -f "$f" ]] || return 1
  awk 'started { print } $0 == "===REPORT===" { started = 1 }' "$f"
}

# gate_cache_put <root> <key> <verdict> <session> <model> <gateset>
# Report body is read from stdin. Creates the cache dir on demand.
gate_cache_put() {
  local root="$1" key="$2" verdict="$3" session="$4" model="$5" gateset="$6"
  local dir; dir="$(gate_cache_dir "$root")"
  mkdir -p "$dir" || return 1
  local f; f="$(gate_cache_path "$root" "$key")"
  {
    printf 'verdict: %s\n' "$verdict"
    printf 'session: %s\n' "${session:-unknown}"
    printf 'timestamp: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'diffhash: %s\n' "$key"
    printf 'model: %s\n' "${model:-default}"
    printf 'gateset: %s\n' "$gateset"
    printf '===REPORT===\n'
    cat
  } > "$f"
}

# gate_cache_banner <root> <key> — print a loud, greppable HIT banner to stderr,
# so a cached verdict can never be mistaken for a fresh grade.
gate_cache_banner() {
  local root="$1" key="$2" ts src
  ts="$(gate_cache_header "$root" "$key" timestamp)"
  src="$(gate_cache_header "$root" "$key" session)"
  {
    echo "=== CACHED VERDICT — reused, grader NOT re-run ==="
    echo "    diff unchanged since $ts (source session: ${src:-unknown}; key ${key:0:12})"
    echo "    Re-run with --no-cache to force a fresh grade."
  } >&2
}
