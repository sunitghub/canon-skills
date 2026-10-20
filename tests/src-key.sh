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
mkdir -p "$M/cmd/sprint-check" "$M/cmd/cockpit-daemon" "$M/internal/board" "$M/internal/daemon" "$M/internal/common"
cp "$ROOT/tools/src-key.sh" "$R/tools/"
printf 'module canon\n' > "$M/go.mod"; : > "$M/go.sum"
for d in cmd/sprint-check cmd/cockpit-daemon internal/board internal/daemon internal/common; do echo "package x // $d" > "$M/$d/x.go"; done
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
b2="$b"; d2="$d"
# shared sources move both
commit internal/common; b3="$(key sprint-check)"; d3="$(key cockpit-daemon)"
[[ "$b3" != "$b2" && "$d3" != "$d2" ]] || fail "a change in internal/common must re-key both"
echo "go 1.26.5" >> "$M/go.mod"; git -C "$R" "${ident[@]}" commit -qam go.mod; [[ "$(key sprint-check)" != "$b3" && "$(key cockpit-daemon)" != "$d3" ]] || fail "a go.mod change must re-key both"
# an unrelated file moves nothing
b4="$(key sprint-check)"; d4="$(key cockpit-daemon)"; echo x > "$R/README.md"; git -C "$R" add README.md; git -C "$R" "${ident[@]}" commit -qm readme
assert_eq "$b4" "$(key sprint-check)"; assert_eq "$d4" "$(key cockpit-daemon)"
# the same in a shallow clone, and for an older rev
git clone -q --depth 1 "file://$R" "$WORK/shallow"; R2="$WORK/shallow"; cp "$ROOT/tools/src-key.sh" "$R2/tools/"
assert_eq "$b4" "$(key sprint-check)"; unset R2
assert_eq "$b0" "$(key sprint-check HEAD~7)"
# unknown component, or a path missing from the commit: nothing printed, exit 1
set +e; out="$(key nope)"; rc=$?; set -e; assert_eq 1 "$rc"; assert_eq "" "$out"
git -C "$R" rm -rq tools/canon-go/internal/common; git -C "$R" "${ident[@]}" commit -qm "drop common"
set +e; out="$(key sprint-check)"; rc=$?; set -e; assert_eq 1 "$rc"; assert_eq "" "$out"
echo "src-key: ok (40-hex per component, own changes re-key only their binary, shared ones both, stable across clones, unknown/missing refuse)"
