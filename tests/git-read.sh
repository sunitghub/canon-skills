#!/usr/bin/env bash
# git-read.sh — the headless close gates' read-only git wrapper (t-5ff5): only diff/log/show/status, first; no global
# option before them; no --out*, --ext-diff or --no-index. Prod path: tools/sprint-headless and -eval grant only it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/tools/git-read"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "git-read: FAIL — $*" >&2; exit 1; }
R="$WORK/r"; git init -q "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
echo a > "$R/f"; git -C "$R" add f; git -C "$R" commit -qm one; echo b > "$R/f"
echo outside > "$WORK/outside.txt"
snapshot() { (cd "$WORK" && find . -path ./r/.git -prune -o -print | LC_ALL=C sort); }
before="$(snapshot)"

# each refused form exits non-zero, names the refusal, and git never runs (no file appears anywhere)
refuse() {
  local why="$1"; shift
  local out rc
  set +e; out="$(cd "$R" && bash "$TOOL" "$@" 2>&1)"; rc=$?; set -e
  [[ "$rc" -ne 0 ]] || fail "$why: '$*' was not refused"
  grep -q "^git-read: " <<<"$out" || fail "$why: '$*' gave no git-read refusal: $out"
  [[ "$(snapshot)" == "$before" ]] || fail "$why: '$*' wrote a file"
}
# git's global options can change what git runs or where; the subcommand must come first
refuse "global -c"         -c core.pager=touch\ pwned diff
refuse "global -C"         -C "$WORK" diff
refuse "global --git-dir"  --git-dir="$R/.git" diff
refuse "global --work-tree" --work-tree="$WORK" diff
refuse "global --exec-path" --exec-path="$WORK" diff
refuse "other subcommand"  commit -qam x
refuse "other subcommand"  config core.pager cat
refuse "no subcommand"
# flags that write a file, run another program or read outside the repository
refuse "--output="         diff --output="$WORK/o1"
refuse "--output <path>"   diff --output "$WORK/o2"
refuse "show --output"     show --output="$WORK/o3"
refuse "log --output"      log -p --output="$WORK/o4"
refuse "abbreviated"       diff --outp="$WORK/o5"
refuse "late --output"     diff HEAD -- f --output="$WORK/o6"
refuse "--ext-diff"        diff --ext-diff
refuse "--no-index"        diff --no-index "$WORK/outside.txt" f

# the four read subcommands work, and status leaves .git/index alone
idx="$(cksum < "$R/.git/index")"; touch "$R/f"
grep -q '^+b$' <<<"$(cd "$R" && bash "$TOOL" diff)" || fail "diff did not show the change"
[[ "$(cd "$R" && bash "$TOOL" diff --name-only HEAD)" == f ]] || fail "diff --name-only"
grep -q 'one' <<<"$(cd "$R" && bash "$TOOL" log --oneline -1)" || fail "log"
[[ "$(cd "$R" && bash "$TOOL" show HEAD:f)" == a ]] || fail "show HEAD:f"
grep -q 'f' <<<"$(cd "$R" && bash "$TOOL" status --porcelain)" || fail "status"
[[ "$(cksum < "$R/.git/index")" == "$idx" ]] || fail "status rewrote .git/index"
[[ "$(snapshot)" == "$before" ]] || fail "a read subcommand wrote a file"

echo "git-read: ok (5 global options, other/no subcommand, 6 --output forms, --ext-diff and --no-index refused with nothing written; diff/log/show/status work; status leaves the index)"
