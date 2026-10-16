#!/usr/bin/env bash
# tkt compact (t-2fb6): which tickets it touches, what it deletes, packs and keeps, and that a failed compact never fails a close.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
outside="$(mktemp -d "${TMPDIR:-/tmp}/tkt-compact-outside.XXXXXX")"
trap 'chmod -R u+w "$project" 2>/dev/null; rm -rf "$project" "$outside"' EXIT
cd "$project"
git config user.email t@example.com && git config user.name t

days_ago() {   # days_ago <n> <file>: set <file>'s mtime to <n> days ago
  local s=$(( $(date +%s) - $1 * 86400 )) stamp
  stamp="$(date -u -d "@$s" +%Y%m%d%H%M.%S 2>/dev/null || date -u -r "$s" +%Y%m%d%H%M.%S)"
  TZ=UTC touch -t "$stamp" "$2"
}
mk() {   # mk <id> <status> <age-days>: a ticket with a log, a note, a board-spec JSON report and a nested board-spec log
  local d=".tickets/$1"
  mkdir -p "$d/evidence/sub"
  printf -- '---\nid: %s\nstatus: %s\n---\n# %s\n' "$1" "$2" "$1" > "$d/ticket.md"
  printf 'log of %s\n' "$1" > "$d/evidence/test-sh.log"
  printf 'note of %s\n' "$1" > "$d/evidence/sub/note.md"
  printf '{"suites":[]}\n' > "$d/evidence/sub/board-spec-chromium-run1.json"
  printf 'not a report\n' > "$d/evidence/sub/board-spec-chromium.log"
  days_ago "$3" "$d/ticket.md"
}
tree_sig() { (cd .tickets && find . -print | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort); }

mk t-c001 closed 15
mk t-c002 cancelled 15
mk t-c003 open 30
mk t-c004 in_progress 30
mk t-c005 archived 30
mk t-c006 closed 13
mk t-c007 closed 15
mk t-c008 closed 15
mk t-c009 closed 15
# Cited from each source: t-c001's own acceptance.md embeds a screenshot, the open t-c003 cites t-c007's file, and a
# tracked file cites t-c008's file. A symlink in t-c001 points outside .tickets/.
printf 'png' > .tickets/t-c001/evidence/shot.png
printf '# Acceptance\n![board](evidence/shot.png)\n' > .tickets/t-c001/acceptance.md
printf 'diag\n' > .tickets/t-c007/evidence/diag.md
printf '# Plan\nSee .tickets/t-c007/evidence/diag.md.\n' > .tickets/t-c003/plan.md
printf 'map\n' > .tickets/t-c008/evidence/map.md
mkdir -p tests && printf '# see .tickets/t-c008/evidence/map.md\n' > tests/x.sh
git add tests/x.sh && git commit -q -m fixture
# t-c009 cites a folder, a brace pattern and a glob in prose (shapes found in real tickets on the first run).
mkdir -p .tickets/t-c009/evidence/shots
printf 'a' > .tickets/t-c009/evidence/shots/a.png
printf 'x' > .tickets/t-c009/evidence/board-x-dark.png
printf 'y' > .tickets/t-c009/evidence/board-y-light.png
printf 'z' > .tickets/t-c009/evidence/board-z-dark.png
printf '# Acceptance\nShots in `evidence/shots/`, and evidence/board-{x,y}-{dark,light}.png, plus evidence/sub/*.md.\n' > .tickets/t-c009/acceptance.md
printf 'secret\n' > "$outside/secret.txt"
ln -s "$outside/secret.txt" .tickets/t-c001/evidence/link
cp -R .tickets/t-c001/evidence "$outside/c001-before"

# --dry-run changes nothing and reports the same figures the real run will.
before="$(tree_sig)"
dry="$("$TKT" compact --older-than 14 --dry-run)"
[[ "$(tree_sig)" == "$before" ]] || fail "--dry-run changed .tickets/"
assert_contains "$dry" "compact (dry run): total: 5 tickets older than 14 days, deleted 5 files, packed"
assert_contains "$dry" "restore one: tar -xzf .tickets/<id>/evidence.tgz -C .tickets/<id>"

out="$("$TKT" compact --older-than 14)"
assert_contains "$out" "compact: total: 5 tickets older than 14 days, deleted 5 files, packed"
norm() { sed -e 's/^compact (dry run)/compact/' -e 's/ → [0-9.]* MB//g' -e 's/ (saved [0-9.]* MB)//'; }
[[ "$(norm <<< "$dry")" == "$(norm <<< "$out")" ]] || fail "dry run and real run report different figures:
$dry
---
$out"

# Eligible: closed and cancelled, older than the cut-off. Everything else is untouched.
for id in t-c001 t-c002 t-c007 t-c008 t-c009; do
  assert_file_exists ".tickets/$id/evidence.tgz"
  [[ -e ".tickets/$id/evidence/sub/board-spec-chromium-run1.json" ]] && fail "$id: board-spec JSON report not deleted"
  [[ -e ".tickets/$id/evidence/test-sh.log" ]] && fail "$id: packed file left loose"
  [[ -e ".tickets/$id/evidence.tgz.tmp" ]] && fail "$id: temp archive left behind"
  grep -qx 'evidence/sub/board-spec-chromium.log' <<< "$(tar -tzf ".tickets/$id/evidence.tgz")" || fail "$id: a board-spec log is not a JSON report and must be packed"
  grep -q 'run1.json' <<< "$(tar -tzf ".tickets/$id/evidence.tgz")" && fail "$id: a deleted JSON report was packed"
done
for id in t-c003 t-c004 t-c005 t-c006; do
  [[ -e ".tickets/$id/evidence.tgz" ]] && fail "$id: compacted a ticket it must skip"
  assert_file_exists ".tickets/$id/evidence/sub/board-spec-chromium-run1.json"
  assert_file_exists ".tickets/$id/evidence/test-sh.log"
done

# Cited files stay loose, one per source; the symlink stays, unfollowed, and its target is untouched.
assert_file_exists .tickets/t-c001/evidence/shot.png
assert_file_exists .tickets/t-c007/evidence/diag.md
assert_file_exists .tickets/t-c008/evidence/map.md
for f in shots/a.png board-x-dark.png board-y-light.png sub/note.md; do assert_file_exists ".tickets/t-c009/evidence/$f"; done
grep -qx 'evidence/board-z-dark.png' <<< "$(tar -tzf .tickets/t-c009/evidence.tgz)" || fail "a file no pattern names must still be packed"
grep -q 'shots/\|board-x\|board-y\|note.md' <<< "$(tar -tzf .tickets/t-c009/evidence.tgz)" && fail "a folder-, brace- or glob-cited file was packed"
[[ -L .tickets/t-c001/evidence/link ]] || fail "the symlink in evidence/ was removed"
grep -q 'link\|shot.png' <<< "$(tar -tzf .tickets/t-c001/evidence.tgz)" && fail "a symlink or a cited file was packed"
[[ "$(cat "$outside/secret.txt")" == secret ]] || fail "the symlink's target outside .tickets/ changed"

# Extracting the archive restores the packed files byte for byte.
mkdir "$outside/restore" && tar -xzf .tickets/t-c001/evidence.tgz -C "$outside/restore"
for f in test-sh.log sub/note.md sub/board-spec-chromium.log; do
  cmp -s "$outside/restore/evidence/$f" "$outside/c001-before/$f" || fail "restored $f differs from the original"
done

# A second run is a no-op.
before="$(tree_sig)"
again="$("$TKT" compact --older-than 14)"
assert_contains "$again" "compact: total: 0 tickets"
[[ "$(tree_sig)" == "$before" ]] || fail "a second run changed .tickets/"

# An archive that does not list every packed file is never trusted: a tar stub writes an empty archive and exits 0.
mk t-c012 closed 15
stub="$outside/stub"; mkdir -p "$stub"; real_tar="$(command -v tar)"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [[ "$a" == evidence.tgz.tmp ]] && { printf "" | gzip > evidence.tgz.tmp; exit 0; }; done\nexec "%s" "$@"\n' "$real_tar" > "$stub/tar"
chmod +x "$stub/tar"
rc=0; bad="$(PATH="$stub:$PATH" "$TKT" compact --older-than 14 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "an unverified archive should make compact exit 1, got $rc: $bad"
assert_contains "$bad" "compact: WARNING: t-c012: packing failed, every file kept loose"
assert_file_exists .tickets/t-c012/evidence/test-sh.log
assert_file_exists .tickets/t-c012/evidence/sub/note.md
[[ -e .tickets/t-c012/evidence.tgz || -e .tickets/t-c012/evidence.tgz.tmp ]] && fail "t-c012: an unverified archive was kept"
"$TKT" compact --older-than 14 >/dev/null && assert_file_exists .tickets/t-c012/evidence.tgz

# A ticket folder it cannot write fails that ticket only: its files stay, others are compacted, exit 1.
if [[ "$(id -u)" == 0 ]]; then
  echo "tkt-compact: SKIP unwritable-folder cases: running as root ignores permissions" >&2
else
  mk t-c010 closed 15; mk t-c011 closed 15
  chmod a-w .tickets/t-c010 .tickets/t-c010/evidence/sub
  rc=0; ro="$("$TKT" compact --older-than 14 2>&1)" || rc=$?
  [[ "$rc" == 1 ]] || fail "an unwritable ticket should make compact exit 1, got $rc: $ro"
  assert_contains "$ro" "compact: WARNING: t-c010: packing failed, every file kept loose"
  assert_file_exists .tickets/t-c010/evidence/test-sh.log
  assert_file_exists .tickets/t-c010/evidence/sub/board-spec-chromium-run1.json
  [[ -e .tickets/t-c010/evidence.tgz || -e .tickets/t-c010/evidence.tgz.tmp ]] && fail "t-c010: an archive was left in an unwritable folder"
  assert_file_exists .tickets/t-c011/evidence.tgz

  # sprint complete still closes when compact fails, and says so (t-c004 gives up in_progress so a sprint can start).
  sed -i.bak 's/^status: in_progress$/status: open/' .tickets/t-c004/ticket.md && rm .tickets/t-c004/ticket.md.bak
  start_out="$("$SPRINT" start "close with a failing compact")"
  sid="$(awk '/Sprint started:/ { print $3 }' <<< "$start_out")"
  printf '# Summary\n| Item | Status |\n|---|---|\n| done | delivered |\n' > ".tickets/$sid/summary.md"
  printf '# Acceptance\n## Criteria\n- [x] item\n## Test Plan\n- [x] test\n## Wrapup Gates\n| Gate | Status | Reason |\n|------|--------|--------|\n| code-reviewer | ran | clean |\n' > ".tickets/$sid/acceptance.md"
  printf '# Plan\n## Sign-off\n- [x] Plan approved\nTier: trivial\n## Approach\ntest\n' > ".tickets/$sid/plan.md"
  rc=0; co="$("$SPRINT" complete 2>&1)" || rc=$?
  [[ "$rc" == 0 ]] || fail "sprint complete must succeed when compact fails, got $rc: $co"
  assert_contains "$co" "Sprint completed: $sid"
  assert_contains "$co" "compact: WARNING: t-c010"
  assert_contains "$co" "warning: tkt compact exited 1; the close stands."
  assert_grep "^status: closed$" ".tickets/$sid/ticket.md"
  chmod u+w .tickets/t-c010 .tickets/t-c010/evidence/sub
fi

echo "tkt-compact: ok"
