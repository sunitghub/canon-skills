#!/usr/bin/env bash
# src-key (t-8020, t-bdb0): tools/src-key.sh names canon-go's release key and its two part keys from the paths each is built from. The
# board and the daemon are one program, so the release key (`canon-go`) moves with either part; the daemon part's key is stamped into
# the binary and must move only with the daemon's own sources and the shared ones: a board-only change must keep it (Admin would ask to
# restart an unchanged daemon). Prod path: tools/fetch-daemon.sh (install, canon update, canon start), scripts/release-daemon.sh,
# scripts/build-zip.sh and scripts/check-binaries-released.sh all read this one owner.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$WORK/xdg"
ident=(-c user.email=t@example.com -c user.name=test)

R="$WORK/repo"; M="$R/tools/canon-go"
mkdir -p "$M/cmd/canon-go" "$M/internal/board" "$M/internal/daemon" "$M/internal/common" "$M/internal/events" "$M/internal/term" "$M/internal/settings"
cp "$ROOT/tools/src-key.sh" "$R/tools/"
printf 'module canon\n' > "$M/go.mod"; : > "$M/go.sum"
for d in cmd/canon-go internal/board internal/daemon internal/common internal/events internal/term internal/settings; do echo "package x // $d" > "$M/$d/x.go"; done
git -C "$R" init -q -b main; git -C "$R" "${ident[@]}" add -A; git -C "$R" "${ident[@]}" commit -qm seed
key() { bash -c 'source "$1/tools/src-key.sh"; canon_src_key "$1" "$2" ${3:+"$3"}' _ "${R2:-$R}" "$@"; }
commit() { echo "// $1" >> "$M/$1/x.go" 2>/dev/null || echo "// $1" >> "$M/$1"; git -C "$R" "${ident[@]}" commit -qam "$1"; }

b0="$(key board)"; d0="$(key daemon)"; c0="$(key canon-go)"
[[ "$b0" =~ ^[0-9a-f]{40}$ && "$d0" =~ ^[0-9a-f]{40}$ && "$c0" =~ ^[0-9a-f]{40}$ ]] || fail "keys must be 40 hex: board '$b0' daemon '$d0' canon-go '$c0'"
[[ "$b0" != "$d0" && "$c0" != "$b0" && "$c0" != "$d0" ]] || fail "the three keys must differ"
# the release key is the hash of the two part keys, nothing else (release-daemon.sh and fetch-daemon.sh compute the same name)
assert_eq "$c0" "$(printf 'daemon %s\nboard %s\n' "$d0" "$b0" | git -C "$R" hash-object --stdin)"
# t-b62a, t-bdb0: retired names (the headless helper, the two programs canon-go replaced) have no key, so no script can fetch them
for gone in sprint-headless-json cockpit-daemon sprint-check; do
  rc=0; out="$(key "$gone")" || rc=$?; [[ "$rc" == 1 && -z "$out" ]] || fail "a retired component ($gone) must have no key: rc=$rc '$out'"
done
# canon_ldflags: the commit stamp is the release key's first 8, the daemon key is the daemon part's full key
assert_eq "-X main.commit=${c0:0:8} -X main.daemonKey=$d0" "$(bash -c 'source "$1/tools/src-key.sh"; canon_ldflags "$1"' _ "$R")"

# own sources move only their own part key, and always the release key: every path of each part, one commit at a time
b="$b0"; d="$d0"; c="$c0"
moved() { # <path> <board moves 0|1> <daemon moves 0|1>
  commit "$1"; local nb nd nc; nb="$(key board)"; nd="$(key daemon)"; nc="$(key canon-go)"
  if [[ "$2" == 1 ]]; then [[ "$nb" != "$b" ]] || fail "a change in $1 must re-key the board part"; else [[ "$nb" == "$b" ]] || fail "a change in $1 re-keyed the board part"; fi
  if [[ "$3" == 1 ]]; then [[ "$nd" != "$d" ]] || fail "a change in $1 must re-key the daemon part"; else [[ "$nd" == "$d" ]] || fail "a change in $1 re-keyed the daemon part (a board-only release would flag the daemon stale)"; fi
  [[ "$nc" != "$c" ]] || fail "a change in $1 must re-key canon-go (a new release)"
  b="$nb"; d="$nd"; c="$nc"
}
moved internal/board 1 0
moved internal/daemon 0 1
moved internal/term 0 1         # t-dba0: the Terminal is part of the daemon
moved cmd/canon-go 1 1          # the one main package holds both parts
moved internal/settings 1 1
moved internal/common 1 1
moved internal/events 1 1       # t-8854: the daemon emits events too
echo "go 1.26.5" >> "$M/go.mod"; git -C "$R" "${ident[@]}" commit -qam go.mod; [[ "$(key board)" != "$b" && "$(key daemon)" != "$d" && "$(key canon-go)" != "$c" ]] || fail "a go.mod change must re-key all"
# an unrelated file moves nothing
b4="$(key board)"; d4="$(key daemon)"; c4="$(key canon-go)"; echo x > "$R/README.md"; git -C "$R" add README.md; git -C "$R" "${ident[@]}" commit -qm readme
assert_eq "$b4" "$(key board)"; assert_eq "$d4" "$(key daemon)"; assert_eq "$c4" "$(key canon-go)"
# the same in a shallow clone, and for an older rev
git clone -q --depth 1 "file://$R" "$WORK/shallow"; R2="$WORK/shallow"; cp "$ROOT/tools/src-key.sh" "$R2/tools/"
assert_eq "$c4" "$(key canon-go)"; unset R2
assert_eq "$c0" "$(key canon-go HEAD~9)"   # the seed commit, before the 9 commits above
# unknown component, or a path missing from the commit: nothing printed, exit 1 (canon-go too: it needs both parts)
set +e; out="$(key nope)"; rc=$?; set -e; assert_eq 1 "$rc"; assert_eq "" "$out"
git -C "$R" rm -rq tools/canon-go/internal/term; git -C "$R" "${ident[@]}" commit -qm "drop term"
set +e; out="$(key canon-go)"; rc=$?; set -e; assert_eq 1 "$rc"; assert_eq "" "$out"
set +e; out="$(bash -c 'source "$1/tools/src-key.sh"; canon_ldflags "$1"' _ "$R")"; rc=$?; set -e; assert_eq 1 "$rc"; assert_eq "" "$out"
# t-dba0: each part key names every internal package that part is really built from. `go list -deps` is the truth; a package a part
# imports (the Terminal inside the daemon, once missing) but its key does not name would let a changed daemon keep its old key.
if command -v go >/dev/null 2>&1; then
  for comp in daemon board; do
    paths="$(bash -c 'source "$1/tools/src-key.sh"; canon_component_paths "$2"' _ "$ROOT" "$comp")"
    [[ " $paths " == *" tools/canon-go/cmd/canon-go "* ]] || fail "the $comp part key must name cmd/canon-go (the binary it ships in)"
    pkgs="$(cd "$ROOT/tools/canon-go" && go list -deps "./internal/$comp" 2>/dev/null | grep '^canon/internal/' || true)"
    [[ -n "$pkgs" ]] || fail "go list -deps found no internal package for $comp: the key check would pass without checking anything"
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      [[ " $paths " == *" tools/canon-go/${pkg#canon/} "* ]] || fail "$comp is built from $pkg but its source key does not name tools/canon-go/${pkg#canon/}"
    done <<< "$pkgs"
  done
  # the program itself: every package cmd/canon-go is built from is named by one of the parts (so by the release key)
  all="$(bash -c 'source "$1/tools/src-key.sh"; canon_component_paths daemon; canon_component_paths board' _ "$ROOT" | tr '\n' ' ')"
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    [[ " $all " == *" tools/canon-go/${pkg#canon/} "* ]] || fail "canon-go is built from $pkg but no part key names tools/canon-go/${pkg#canon/}"
  done < <(cd "$ROOT/tools/canon-go" && go list -deps ./cmd/canon-go | grep '^canon/')
fi
echo "src-key: ok (40-hex keys, canon-go = hash of both parts, a board-only change keeps the daemon key, shared ones move both, stable across clones, unknown/missing refuse)"
