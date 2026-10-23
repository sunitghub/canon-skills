#!/usr/bin/env bash
# t-2785: every canon entry point that loads a sibling (ticket-root.sh, gate-cache.sh, mutant-sweep.py…) finds it however
# it is run: directly, or through an absolute, relative or chained symlink in another directory (a cloud environment's
# /usr/local/bin, a user's ~/bin). Each link run must behave exactly as the direct run.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/tool-symlinks.XXXXXX")"
trap 'rm -rf "$W"' EXIT
export HOME="$W/home" CANON_HOME="$W/home/.canon" TMPDIR="$W/tmp" XDG_CONFIG_HOME="$W/home/.config"
mkdir -p "$HOME" "$TMPDIR" "$W/abs" "$W/rel" "$W/chain"
project="$(make_project)"; cd "$project"

# tool, then its harmless arguments (each reaches the sibling it loads; tkt ls needs ticket-root.sh and a project).
cases=(
  "sprint --help"
  "tkt ls"
  "evidence.sh"
  "gate-snapshot.sh"
  "subagent-log.sh --help"
  "sprint-headless"
  "sprint-headless-eval"
  "mutant-sweep --help"
)
# The relative link climbs out of rel/: rel/<t> -> ../canon-tools/<t>, and canon-tools -> the real tools/.
ln -s "$TOOLS_DIR" "$W/canon-tools"
run() { local rc=0; "$@" > "$W/out" 2> "$W/err" || rc=$?; printf '%s\n' "$rc"; }
for c in "${cases[@]}"; do
  read -r t args <<<"$c"
  ln -s "$TOOLS_DIR/$t" "$W/abs/$t"
  ln -s "../canon-tools/$t" "$W/rel/$t"
  ln -s "$W/abs/$t" "$W/chain/$t.1" && ln -s "$t.1" "$W/chain/$t"      # chain: chain/t -> chain/t.1 -> abs/t -> tools/t
  # shellcheck disable=SC2086  # args split on purpose
  want_rc="$(run "$TOOLS_DIR/$t" $args)"; want="$(cat "$W/out" "$W/err")"
  for shape in abs rel chain; do
    # shellcheck disable=SC2086
    got_rc="$(run "$W/$shape/$t" $args)"; got="$(cat "$W/out" "$W/err")"
    grep -q "No such file or directory" "$W/err" && fail "$t via $shape link: $(head -3 "$W/err")"
    [[ "$got_rc" == "$want_rc" ]] || fail "$t via $shape link exited $got_rc, directly $want_rc: $(head -3 "$W/err")"
    [[ "$got" == "${want//$TOOLS_DIR\/$t/$W\/$shape\/$t}" || "$got" == "$want" ]] || fail "$t via $shape link printed something else:
--- direct
$want
--- $shape
$got"
  done
done
echo "tool-symlinks: ok (${#cases[@]} tools x absolute, relative and chained links)"
