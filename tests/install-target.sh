#!/usr/bin/env bash
# install-target — bin/install.js resolveTarget precedence + tilde expansion

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

export INSTALL="$ROOT/bin/install.js"

# resolve <home> <CANON_HOME or ''> <positional arg or ''>
resolve() {
  HOME_VAL="$1" CANON_HOME_VAL="$2" ARG_VAL="$3" node -e '
    const { resolveTarget } = require(process.env.INSTALL);
    const argv = ["node", "install.js"];
    if (process.env.ARG_VAL) argv.push(process.env.ARG_VAL);
    const env = {};
    if (process.env.CANON_HOME_VAL) env.CANON_HOME = process.env.CANON_HOME_VAL;
    process.stdout.write(resolveTarget({ argv, env, home: process.env.HOME_VAL }));
  '
}

# default → <home>/.canon
assert_eq "/home/u/.canon" "$(resolve /home/u '' '')"

# CANON_HOME respected when no arg
assert_eq "/opt/canon" "$(resolve /home/u /opt/canon '')"

# positional arg overrides CANON_HOME
assert_eq "/tmp/c" "$(resolve /home/u /opt/canon /tmp/c)"

# leading ~/ expands to home
assert_eq "/home/u/foo" "$(resolve /home/u '~/foo' '')"

# relative arg resolves to absolute (against cwd)
assert_eq "$PWD/rel" "$(resolve /home/u '' rel)"

printf 'install-target: ok\n'
