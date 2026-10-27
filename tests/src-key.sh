#!/usr/bin/env bash
# src-key (t-8020): tools/src-key.sh names each prebuilt binary's release key from the paths it is built from. The board and the daemon
# share one module, so a key must move with its own sources and the shared ones only: a board-only change must not re-key the daemon
# (installs would re-fetch it and Admin would ask to restart it). Prod path: tools/fetch-daemon.sh (install, canon update, canon
# start), scripts/release-daemon.sh and scripts/check-binaries-released.sh all read this one owner.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg"
ident=(-c user.email=t@example.com -c user.name=test)

R="$WORK/repo"; M="$R/tools/canon-go"
mkdir -p "$M/cmd/sprint-check" "$M/cmd/cockpit-daemon" "$M/internal/board" "$M/internal/daemon" "$M/internal/common" "$M/internal/events" "$M/internal/term" "$M/internal/settings"
cp "$ROOT/tools/src-key.sh" "$R/tools/"
printf 'module canon\n' > "$M/go.mod"; : > "$M/go.sum"
for d in cmd/sprint-check cmd/cockpit-daemon internal/board internal/daemon internal/common internal/events internal/term internal/settings; do echo "package x // $d" > "$M/$d/x.go"; done
git -C "$R" init -q -b main; git -C "$R" "${ident[@]}" add -A; git -C "$R" "${ident[@]}" commit -qm seed
key() { bash -c 'source "$1/tools/src-key.sh"; canon_src_key "$1" "$2" ${3:+"$3"}' _ "${R2:-$R}" "$@"; }
commit() { echo "// $1" >> "$M/$1/x.go" 2>/dev/null || echo "// $1" >> "$M/$1"; git -C "$R" "${ident[@]}" commit -qam "$1"; }

b0="$(key sprint-check)"; d0="$(key cockpit-daemon)"
[[ "$b0" =~ ^[0-9a-f]{40}$ && "$d0" =~ ^[0-9a-f]{40}$ ]] || fail "keys must be 40 hex: board '$b0' daemon '$d0'"
[[ "$b0" != "$d0" ]] || fail "the board and the daemon must not share a key"
# t-b62a: the headless helper is retired (the board binary does its job), so no script can name a key for it
rc=0; out="$(key sprint-headless-json)" || rc=$?; [[ "$rc" == 1 && -z "$out" ]] || fail "a retired component must have no key: rc=$rc '$out'"

# own sources move only their own key: every path of each binary, one commit at a time
b="$b0"; d="$d0"
for p in internal/board cmd/sprint-check; do
  commit "$p"; nb="$(key sprint-check)"; nd="$(key cockpit-daemon)"
  [[ "$nb" != "$b" ]] || fail "a change in $p must re-key the board"; [[ "$nd" == "$d" ]] || fail "a change in $p re-keyed the daemon"; b="$nb"
done
for p in internal/daemon cmd/cockpit-daemon; do
  commit "$p"; nb="$(key sprint-check)"; nd="$(key cockpit-daemon)"
  [[ "$nd" != "$d" ]] || fail "a change in $p must re-key the daemon"; [[ "$nb" == "$b" ]] || fail "a change in $p re-keyed the board"; d="$nd"
done
# t-dba0: the Terminal (internal/term) is part of the daemon binary and the settings package of both: a change there must re-key them
commit internal/term; nb="$(key sprint-check)"; nd="$(key cockpit-daemon)"
[[ "$nd" != "$d" ]] || fail "a change in internal/term must re-key the daemon"; [[ "$nb" == "$b" ]] || fail "a change in internal/term re-keyed the board"; d="$nd"
commit internal/settings; nb="$(key sprint-check)"; nd="$(key cockpit-daemon)"
[[ "$nb" != "$b" && "$nd" != "$d" ]] || fail "a change in internal/settings must re-key both"; b="$nb"; d="$nd"
b2="$b"; d2="$d"
# shared sources move both
commit internal/common; b3="$(key sprint-check)"; d3="$(key cockpit-daemon)"
[[ "$b3" != "$b2" && "$d3" != "$d2" ]] || fail "a change in internal/common must re-key both"
commit internal/events; b3e="$(key sprint-check)"; d3e="$(key cockpit-daemon)"   # t-8854: the daemon emits events too
[[ "$b3e" != "$b3" && "$d3e" != "$d3" ]] || fail "a change in internal/events must re-key both"; b3="$b3e"; d3="$d3e"
echo "go 1.26.5" >> "$M/go.mod"; git -C "$R" "${ident[@]}" commit -qam go.mod; [[ "$(key sprint-check)" != "$b3" && "$(key cockpit-daemon)" != "$d3" ]] || fail "a go.mod change must re-key both"
# an unrelated file moves nothing
b4="$(key sprint-check)"; d4="$(key cockpit-daemon)"; echo x > "$R/README.md"; git -C "$R" add README.md; git -C "$R" "${ident[@]}" commit -qm readme
assert_eq "$b4" "$(key sprint-check)"; assert_eq "$d4" "$(key cockpit-daemon)"
# the same in a shallow clone, and for an older rev
git clone -q --depth 1 "file://$R" "$WORK/shallow"; R2="$WORK/shallow"; cp "$ROOT/tools/src-key.sh" "$R2/tools/"
assert_eq "$b4" "$(key sprint-check)"; unset R2
assert_eq "$b0" "$(key sprint-check HEAD~10)"   # the seed commit, before the 10 commits above
# unknown component, or a path missing from the commit: nothing printed, exit 1
set +e; out="$(key nope)"; rc=$?; set -e; assert_eq 1 "$rc"; assert_eq "" "$out"
git -C "$R" rm -rq tools/canon-go/internal/common; git -C "$R" "${ident[@]}" commit -qm "drop common"
set +e; out="$(key sprint-check)"; rc=$?; set -e; assert_eq 1 "$rc"; assert_eq "" "$out"
# t-dba0: each key names every internal package its binary is really built from. `go list -deps` is the truth; a package a binary
# imports (the Terminal inside the daemon, once missing) but its key does not name would let a changed binary keep its old key.
if command -v go >/dev/null 2>&1; then
  for comp in cockpit-daemon sprint-check; do
    paths="$(bash -c 'source "$1/tools/src-key.sh"; canon_component_paths "$2"' _ "$ROOT" "$comp")"
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      [[ " $paths " == *" tools/canon-go/${pkg#canon/} "* ]] || fail "$comp is built from $pkg but its source key does not name tools/canon-go/${pkg#canon/}"
    done < <(cd "$ROOT/tools/canon-go" && go list -deps "./cmd/$comp" 2>/dev/null | grep '^canon/internal/' || true)
  done
fi
echo "src-key: ok (40-hex per component, own changes re-key only their binary, shared ones both, stable across clones, unknown/missing refuse)"
