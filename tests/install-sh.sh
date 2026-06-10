#!/usr/bin/env bash
# install-sh — install.sh _resolve_target precedence + tilde expansion (parity with install-target.sh)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

# Source install.sh to load helper functions without running main
source "$ROOT/install.sh"

resolve() {
  local home_val="$1" canon_home_val="$2" arg_val="$3"
  HOME="$home_val" CANON_HOME="$canon_home_val" _resolve_target "$arg_val"
}

# default → <home>/.canon
assert_eq "/home/u/.canon" "$(resolve /home/u '' '')"

# CANON_HOME respected when no arg
assert_eq "/opt/canon" "$(resolve /home/u /opt/canon '')"

# positional arg overrides CANON_HOME
assert_eq "/tmp/c" "$(resolve /home/u /opt/canon /tmp/c)"

# leading ~/ in CANON_HOME expands to home
assert_eq "/home/u/foo" "$(resolve /home/u '~/foo' '')"

# leading ~/ in positional arg expands to home
assert_eq "/home/u/bar" "$(resolve /home/u '' '~/bar')"

# relative arg resolves to absolute (against cwd)
assert_eq "$PWD/rel" "$(resolve /home/u '' rel)"

printf 'install-sh: ok\n'
