#!/usr/bin/env bash
# pkg-lib.sh — the versioned install layout (t-50f7). Source, don't execute. macOS and Linux (Windows keeps its single-tree install).
#   <home>/packages/<vX.Y.Z>/   a release, unpacked from its manifest-verified zip (no .git), its two binaries already inside
#   <home>/packages/main/       the development track: a git clone, updated in place
#   <home>/current              a RELATIVE symlink to packages/<name>, replaced by a rename so it is never missing or half-written
#   <home>/tools                a link to current/tools (pkg_compat_tools): the path every doc and older PATH line names
#   <home>/.update.lock/        one update at a time (mkdir is atomic; the pid file inside says who holds it)
# Data (cockpit/, events/, themes/, settings.json, integrity/, .canon-track) lives in <home> beside these, never inside a package.
# <home> is the folder the installer was given (CANON_HOME or ~/.canon). tools/canon's update_packages is the only caller.

PKG_RELEASE_BASE="${CANON_RELEASE_BASE:-https://github.com/sunitghub/canon-skills/releases/download}"   # the override is a test seam
PKG_ERR=""; PKG_NOTE=""; PKG_LOCK=""; _PKG_BLIND_SAID=0
_PKG_LIB_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=platform-lib.sh
declare -F ps_utf8 >/dev/null || source "$_PKG_LIB_DIR/platform-lib.sh"   # ps_utf8, has_non_ascii

# pkg_is_data <name>: an entry of the home that is user data, never part of a package (moving a single-tree install into the layout leaves it).
pkg_is_data() {
  case "$1" in cockpit|events|themes|settings.json|integrity|logs|.canon-track|.canon-cache) return 0 ;; esac
  return 1
}

# pkg_dirty <repo>: the repo's `git status --porcelain` without its untracked runtime entries (t-c724). A single-tree install is its own CANON_HOME,
# so the board, event log and themes write pkg_is_data folders into the clone; those never count as the user's edits. A tracked-file edit or any
# other untracked file still shows, so the update still refuses on it.
pkg_dirty() {
  local l n
  git -C "$1" status --porcelain | while IFS= read -r l; do
    if [ "${l:0:3}" = '?? ' ]; then n="${l:3}"; n="${n%/}"; pkg_is_data "$n" && continue; fi
    printf '%s\n' "$l"
  done
}

_pkg_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1; fi
}

# A pid is alive when ps lists it and it is not a zombie (an unreaped child still answers kill -0).
_pkg_alive() {
  local st; st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" || st=""
  case "$st" in ''|Z*) return 1 ;; esac
  return 0
}

# pkg_home_ok <home>: the folder is a canon home in the versioned layout: current is a link, or a fresh install's bootstrap clone
# (packages/.boot.*) is building it. pkg_flip, pkg_sweep and pkg_prune act on nothing else, so a folder that merely holds a packages/ (a
# monorepo) is never changed by them.
pkg_home_ok() {
  local b
  [ -L "$1/current" ] && return 0
  for b in "$1"/packages/.boot.*; do [ -d "$b" ] && return 0; done
  return 1
}

# pkg_current <home>: the package `current` points at (its folder name), or nothing and 1.
pkg_current() {
  local t; t="$(readlink "$1/current" 2>/dev/null)" || return 1
  [ -n "$t" ] || return 1
  basename "$t"
}

# pkg_lock <home>: take the update lock or set PKG_ERR and return 1. A lock whose pid is gone is a crashed update: it is taken over
# (PKG_NOTE says so). The takeover renames the dead lock to a name of its own first: a rename is atomic, so of two updates that both saw it
# dead only one moves it; the winner then checks it moved the dead one (not a lock taken meanwhile, which it puts back) before mkdir.
pkg_lock() {
  local lock="$1/.update.lock" pid
  PKG_NOTE=""
  if mkdir "$lock" 2>/dev/null; then printf '%s\n' "$$" > "$lock/pid"; PKG_LOCK="$lock"; return 0; fi
  pid="$(cat "$lock/pid" 2>/dev/null)" || pid=""
  # mkdir and the pid write are two steps: give a lock that was just made a moment to name its owner
  if [ -z "$pid" ]; then sleep 1; pid="$(cat "$lock/pid" 2>/dev/null)" || pid=""; fi
  if [ -n "$pid" ] && _pkg_alive "$pid"; then PKG_ERR="another canon update is running (pid $pid; its lock is $lock)"; return 1; fi
  local grave="$lock.dead.$$"
  mv -- "$lock" "$grave" 2>/dev/null || { PKG_ERR="another canon update just took the lock ($lock)"; return 1; }
  if [ "$(cat "$grave/pid" 2>/dev/null)" != "$pid" ]; then
    [ -e "$lock" ] || mv -- "$grave" "$lock" 2>/dev/null || true
    PKG_ERR="another canon update just took the lock ($lock)"; return 1
  fi
  rm -rf -- "$grave"
  mkdir "$lock" 2>/dev/null || { PKG_ERR="another canon update just took the lock ($lock)"; return 1; }
  printf '%s\n' "$$" > "$lock/pid"; PKG_LOCK="$lock"
  PKG_NOTE="took over the update lock of an update that is no longer running (pid ${pid:-unknown})"
}

pkg_unlock() {
  [ -n "$PKG_LOCK" ] || return 0
  if [ "$(cat "$PKG_LOCK/pid" 2>/dev/null)" = "$$" ]; then rm -rf -- "$PKG_LOCK"; fi
  PKG_LOCK=""
}

# pkg_flip <home> <name> [first]: point current at packages/<name>. first=1 only from the move of a single-tree install, which creates the
# layout in a home it has checked itself; otherwise the home must already be one (pkg_home_ok). A new link under a temp name, then a rename over current: a reader sees the old
# target or the new one, never none. mv must not follow current into the folder it points at (that would move the link inside the package):
# GNU mv says so with -T, BSD mv (macOS) with -h.
pkg_flip() {
  local home="$1" name="$2" tmp="$1/.current.tmp.$$" t
  PKG_ERR=""
  [ "${3:-0}" = 1 ] || pkg_home_ok "$home" || { PKG_ERR="$home is not a canon home (no current link, no install in progress)"; return 1; }
  [ -d "$home/packages/$name" ] || { PKG_ERR="$home/packages/$name does not exist"; return 1; }
  rm -f -- "$tmp"
  ln -s "packages/$name" "$tmp" || { PKG_ERR="could not create a link in $home"; return 1; }
  if mv --version >/dev/null 2>&1; then mv -fT -- "$tmp" "$home/current"; else mv -fh "$tmp" "$home/current"; fi \
    || { rm -f -- "$tmp"; PKG_ERR="could not replace $home/current"; return 1; }
  t="$(readlink "$home/current" 2>/dev/null)" || t=""
  [ "$t" = "packages/$name" ] || { PKG_ERR="$home/current points at '$t', not packages/$name"; return 1; }
}

# pkg_compat_tools <home>: <home>/tools, a relative link to current/tools, so `~/.canon/tools/...` (the docs, a PATH line written before the
# layout, the cloud setup) keeps reaching the current version. Never replaces anything already there.
pkg_compat_tools() {
  [ -e "$1/tools" ] || [ -L "$1/tools" ] || ln -s current/tools "$1/tools"
}

_pkg_unzip() { # <zip> <dir>
  if command -v unzip >/dev/null 2>&1; then unzip -q "$1" -d "$2"
  elif command -v bsdtar >/dev/null 2>&1; then bsdtar -xf "$1" -C "$2"
  else echo "neither unzip nor bsdtar is installed" >&2; return 1; fi
}

# pkg_install <home> <tag> <zip sha256>: build packages/<tag> from the release zip. Everything happens in a temp folder inside packages/ (the same
# file system, so the last step is a rename); only a complete, verified package is renamed into place. On any failure nothing but that temp
# folder was written, it is removed, and PKG_ERR says why. The caller holds the lock and has read the sha from the published manifest.
pkg_install() {
  local home="$1" tag="$2" want="$3" pk="$1/packages" tmp="" zip url got top v
  PKG_ERR=""
  _pkg_fail() { PKG_ERR="$1"; [ -z "$tmp" ] || rm -rf -- "$tmp"; return 1; }
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { PKG_ERR="not a release tag: $tag"; return 1; }  # the tag becomes a folder name and a download path
  [ ! -e "$pk/$tag" ] || { PKG_ERR="$pk/$tag already exists"; return 1; }
  mkdir -p "$pk" || { PKG_ERR="could not create $pk"; return 1; }
  tmp="$(mktemp -d "$pk/.tmp-$tag.XXXXXX")" || { tmp=""; PKG_ERR="could not create a temp folder in $pk"; return 1; }
  zip="$tmp/canon.zip"; url="$PKG_RELEASE_BASE/$tag/canon-${tag#v}.zip"
  command -v curl >/dev/null 2>&1 || { _pkg_fail "curl is required to download $tag"; return 1; }
  # https only; file:// only when the URL comes from the test seam itself (CANON_RELEASE_BASE set to a file:// folder)
  local proto='=https'
  case "${CANON_RELEASE_BASE:-}" in file://*) [ "$PKG_RELEASE_BASE" = "$CANON_RELEASE_BASE" ] && proto='=file' ;; esac
  curl -fsSL --proto "$proto" --proto-redir '=https' --connect-timeout 10 --max-time 300 -o "$zip" "$url" 2>/dev/null \
    || { _pkg_fail "the download of $tag failed ($url)"; return 1; }
  got="$(_pkg_sha256 "$zip")" || { _pkg_fail "no sha256sum or shasum to verify the download"; return 1; }
  [ "$got" = "$want" ] || { _pkg_fail "the downloaded $tag zip does not match the published checksum (got $got, the manifest says $want); it was discarded"; return 1; }
  mkdir "$tmp/x" && _pkg_unzip "$zip" "$tmp/x" >/dev/null || { _pkg_fail "could not unpack the $tag zip"; return 1; }
  rm -f -- "$zip"
  top="$tmp/x/canon-${tag#v}"
  [ -f "$top/tools/canon" ] && [ -f "$top/tools/fetch-daemon.sh" ] || { _pkg_fail "the $tag zip does not hold canon-${tag#v}/tools"; return 1; }
  v="$(tr -d '[:space:]' < "$top/VERSION" 2>/dev/null)" || v=""
  [ "$v" = "${tag#v}" ] || { _pkg_fail "the $tag zip says it is version '${v:-none}'"; return 1; }
  # the board and the daemon, checked against the package's own tools/cockpit-daemon.sha256, land inside the temp package
  bash "$top/tools/fetch-daemon.sh" --quiet >&2 || { _pkg_fail "the board and daemon for $tag could not be fetched (see above)"; return 1; }
  [ ! -e "$pk/$tag" ] || { _pkg_fail "$pk/$tag appeared while it was being built"; return 1; }
  mv -- "$top" "$pk/$tag" || { _pkg_fail "could not move the new package into $pk/$tag"; return 1; }
  rm -rf -- "$tmp"
}

# pkg_in_use <dir> [also]: some process's command line runs a file under <dir>, or, when <also> is 1, under <home>/current/ or <home>/tools/ (a
# program started through the link while it named <dir>). When ps cannot answer, the answer is yes: never delete blind. That includes a path
# with non-ASCII letters on a machine with no UTF-8 locale, where ps cannot print it as it is (said once).
pkg_in_use() {
  local d="$1" home all; home="$(dirname "$(dirname "$1")")"
  if has_non_ascii "$d" && ! utf8_locale >/dev/null; then
    if [ "$_PKG_BLIND_SAID" = 0 ]; then
      echo "canon update: $home has non-ASCII letters and this machine has no UTF-8 locale, so ps cannot show which programs run from it; old versions and leftovers there are kept." >&2
      _PKG_BLIND_SAID=1
    fi
    return 0
  fi
  all="$(ps_utf8 -A -ww -o command= 2>/dev/null)" || return 0
  [ -n "$all" ] || return 0
  case "$all" in *"$d/"*) return 0 ;; esac
  if [ "${2:-0}" = 1 ]; then case "$all" in *"$home/current/"*|*"$home/tools/"*) return 0 ;; esac; fi
  return 1
}

# pkg_prune <home> [<was current>]: keep the current package, packages/main (a clone may hold work) and the 2 newest other releases; remove
# older ones that no process runs from. <was current> is the package current named before this update's flip: a program started through
# <home>/current or <home>/tools may still run from it. Prints one line per package it removes or keeps for that reason.
pkg_prune() {
  local home="$1" was="${2:-}" pk="$1/packages" cur n i=0 re='^v[0-9]+\.[0-9]+\.[0-9]+$'
  pkg_home_ok "$home" || return 0
  cur="$(pkg_current "$home")" || cur=""
  for n in $(for d in "$pk"/v*; do n="$(basename "$d")"; [[ -d "$d" && "$n" =~ $re && "$n" != "$cur" ]] && echo "${n#v}"; done \
      | sort -t. -k1,1nr -k2,2nr -k3,3nr); do
    i=$((i + 1)); [ "$i" -gt 2 ] || continue
    if pkg_in_use "$pk/v$n" "$([ "v$n" = "$was" ] && echo 1 || echo 0)"; then echo "  kept old package v$n (a running program uses it)"
    elif rm -rf -- "$pk/v$n"; then echo "  removed old package v$n"
    else echo "  could not remove old package v$n" >&2; fi
  done
  return 0
}

# pkg_running <home>: what of this install's Cockpit runs (the daemon, the board), as one line; empty when nothing does. The verified probes of
# cockpit-stop-lib.sh, which count the home, current and every package as this install, so another install's daemon or an unrelated listener on
# the port never counts. Also used before a single-tree install moves into the layout (the home is then the clone).
pkg_running() (
  # shellcheck source=platform-lib.sh
  source "$_PKG_LIB_DIR/platform-lib.sh"
  # shellcheck source=cockpit-stop-lib.sh
  source "$_PKG_LIB_DIR/cockpit-stop-lib.sh"
  INSTALL="$1"; PORT="${CANON_COCKPIT_PORT:-8899}"
  board_up() { curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PORT/api/version" 2>/dev/null; }
  local out=""
  probe_daemon; [ "$DAEMON_STATUS" != ours ] || out="the Cockpit daemon (pid $DAEMON_PID)"
  probe_board; [ "$BOARD_STATUS" != ours ] || out="${out:+$out, }the board (pid $BOARD_PID)"
  printf '%s' "$out"
)

# pkg_sweep <home>: folders an interrupted update or install left in packages/: a temp release package (.tmp-v*), a temp main clone
# (.tmp-main.*), a bootstrap clone (.boot.*). The caller holds the lock; a bootstrap clone still in use (its installer runs `canon update` from
# it) is skipped by its command line. Never .tmp-migrate.*: an interrupted move into the layout may have left the user's files there.
pkg_sweep() {
  local d
  pkg_home_ok "$1" || return 0
  for d in "$1"/packages/.tmp-v* "$1"/packages/.tmp-main.* "$1"/packages/.boot.*; do
    [ -d "$d" ] || continue
    pkg_in_use "$d" || rm -rf -- "$d"
  done
  return 0
}
