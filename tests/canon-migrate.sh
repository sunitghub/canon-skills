#!/usr/bin/env bash
# canon-migrate (t-50f7): the first `canon update` of an install made before the versioned layout. Protects that update (tools/canon
# migrate_to_packages), the project re-pointing it ends with (skills.sh refresh: links, @-imports, the pre-commit hook, worktree links,
# install_path, the PATH rc line) and the <home>/tools compat link an existing PATH line goes through.
# The exact path of an install in the wild: a single-tree clone at CANON_HOME, on an older release whose (pre-t-50f7) updater checks out the
# new release in place, with data inside and projects registered against <home>/skills; then the NEW code's update moves it.
# Hermetic: HOME, CANON_HOME, TMPDIR, XDG_* and the Cockpit state dir are pinned to a temp folder for every command; canaries are checked.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/helpers.sh"
assert_not_contains() { case "$1" in *"$2"*) fail "expected the output NOT to contain '$2': $1" ;; esac; }
refute_contains() { [[ "$1" != *"$2"* ]] || fail "expected output NOT to contain '$2'; got: $1"; }
case "$(uname -s)" in Darwin|Linux) ;; *) echo "canon-migrate: SKIPPED on $(uname -s): the versioned layout is macOS/Linux only"; exit 0 ;; esac

W="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/canon-migrate.XXXXXX")" && pwd -P)"
PIDS=()
cleanup() { local p; for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done; chmod -R u+w "$W" 2>/dev/null || true; rm -rf "$W"; }
trap cleanup EXIT
H="$W/h"; mkdir -p "$H/.config/canon" "$W/tmp" "$W/xdg" "$W/cache" "$W/state"
echo canary > "$H/canary"; echo canary > "$W/tmp/canary"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE CANON_REF
ig=(-c user.email=t@e -c user.name=t)
run() {   # run <home> <command...>: everything pinned; CANON_HOME is that install's home
  local home="$1"; shift
  env -u XDG_RUNTIME_DIR HOME="$H" TMPDIR="$W/tmp" XDG_CONFIG_HOME="$W/xdg" XDG_CACHE_HOME="$W/cache" COCKPIT_STATE_DIR="$W/state" \
    CANON_COCKPIT_PORT=1 CANON_MANIFEST_URL="file://$W/releases.txt" CANON_RELEASE_BASE="file://$W/nowhere" CANON_DAEMON_RELEASE_BASE="file://$W/nowhere" \
    CANON_FETCH_NO_BUILD=1 SKILLS_SH_NO_TTY=1 SHELL=/bin/zsh CANON_HOME="$home" "$@" </dev/null
}
tree_sum() { ( cd "$1" && { find . | LC_ALL=C sort; find . -type f -exec cksum {} + | LC_ALL=C sort; } | cksum ); }
data_sum() { local d; for d in cockpit events themes settings.json integrity logs; do printf '%s ' "$d"; if [ -d "$1/$d" ]; then tree_sum "$1/$d"; else cksum < "$1/$d"; fi; done; }

# ── the releases: v0.9.0 carries the updater from before t-50f7 (git checkout in place), v1.0.0 this tree ───────────────────────────────────────
S="$W/src"; mkdir -p "$S"
( cd "$ROOT" && git ls-files tools skills standards agents scripts extensions .gitignore .claude/settings.json VERSION \
    | grep -v '^tools/canon-go/\|^tools/sprint-check-app/' ) > "$W/files"
while IFS= read -r f; do [ -e "$ROOT/$f" ] || continue; mkdir -p "$S/$(dirname "$f")"; cp -p "$ROOT/$f" "$S/$f"; done < "$W/files"
cp -p "$ROOT/tools/pkg-lib.sh" "$S/tools/"   # new in t-50f7: the copy above lists tracked files only
git -C "$S" init -q -b main
# the last release's updater, from history; a shallow checkout (a CI or cloud clone) may not have it, and the case below then does that
# updater's one step (git checkout of the tag) itself and says so
OLD_UPDATER=1; git -C "$ROOT" show 8bf36c67:tools/canon > "$W/canon.old" 2>/dev/null || OLD_UPDATER=0
mv "$S/tools/canon" "$W/canon.now"; if [ "$OLD_UPDATER" = 1 ]; then cp "$W/canon.old" "$S/tools/canon"; else cp "$W/canon.now" "$S/tools/canon"; fi
chmod +x "$S/tools/canon"; echo 0.9.0 > "$S/VERSION"
git -C "$S" add -A; git -C "$S" "${ig[@]}" commit -qm v0.9.0; git -C "$S" "${ig[@]}" tag -a v0.9.0 -m v0.9.0
cp -p "$W/canon.now" "$S/tools/canon"; echo 1.0.0 > "$S/VERSION"
git -C "$S" add -A; git -C "$S" "${ig[@]}" commit -qm v1.0.0; git -C "$S" "${ig[@]}" tag -a v1.0.0 -m v1.0.0
git clone -q --bare --no-local "$S" "$W/origin.git"   # --no-local: a hardlink copy raced git's background auto-gc of the fresh commits
Z="$(printf 'e%.0s' $(seq 1 64))"
printf 'v0.9.0 %s %s\nv1.0.0 %s %s\n' "$Z" "$(git -C "$S" rev-list -n1 v0.9.0)" "$Z" "$(git -C "$S" rev-list -n1 v1.0.0)" > "$W/releases.txt"

old_install() {   # <home> <ref>: a single-tree install as install.sh made it before t-50f7, with data inside
  local home="$1"
  git clone -q "$W/origin.git" "$home"
  git -C "$home" -c advice.detachedHead=false checkout -q --detach "$2"
  mkdir -p "$home/cockpit" "$home/events" "$home/themes" "$home/integrity" "$home/logs"
  echo '{"t":1}' > "$home/events/2026-10-28.jsonl"; echo dark > "$home/themes/t.css"; echo '{}' > "$home/settings.json"
  echo x > "$home/integrity/list"; echo l > "$home/logs/daemon.log"
}
register() {   # <home> <project...>: the Cockpit registry plus a skills.sh add from the old location
  local home="$1" p json="[" sep=""; shift
  for p in "$@"; do json="$json$sep{\"id\": \"$(basename "$p")\", \"path\": \"$p\", \"name\": \"x\"}"; sep=", "; done
  printf '%s]\n' "$json" > "$home/cockpit/projects.json"
}

# ── C8: the old updater moves the clone to v1.0.0 in place, then the new code's update moves it into the layout ─────────────────────────────────
A="$H/my canon çé"   # CANON_HOME: a space and non-ASCII letters
old_install "$A" v0.9.0
mkdir -p "$W/p1" "$W/p2/.claude/skills"; git -C "$W/p1" init -q -b main; git -C "$W/p2" init -q -b main
git -C "$W/p1" "${ig[@]}" commit -q --allow-empty -m init
run "$A" bash "$A/tools/skills.sh" add sprint "$W/p1" >/dev/null 2>&1 || fail "skills.sh add sprint (old layout) failed"
run "$A" bash "$A/tools/skills.sh" add efficiency "$W/p1" >/dev/null 2>&1 || fail "skills.sh add efficiency (old layout) failed"
run "$A" bash "$A/tools/skills.sh" add sprint "$W/p2" >/dev/null 2>&1 || fail "skills.sh add sprint into p2 failed"
git -C "$W/p1" worktree add -q "$W/p1-wt" 2>/dev/null; run "$A" bash "$A/tools/skills.sh" link-worktree "$W/p1-wt" >/dev/null
register "$A" "$W/p1" "$W/p2"
printf '%s\n' "$A" > "$H/.config/canon/install_path"
printf 'alias ll="ls -l"\n\n# canon tools\nexport PATH="$PATH:%s/tools"\n' "$A" > "$H/.zshrc"
assert_eq "$A/skills" "$(readlink "$W/p1/.claude/skills")"   # the fixture is what an old install stored
grep -qxF "@$A/standards/efficiency.md" "$W/p1/AGENTS.md" || fail "fixture: no old @-import in p1/AGENTS.md"
grep -qF "CANON_ROOT=\"$A\"" "$W/p1/.git/hooks/pre-commit" || fail "fixture: no old CANON_ROOT in the p1 hook"
[ -z "$(git -C "$A" status --porcelain)" ] || fail "fixture: the old install is dirty: $(git -C "$A" status --porcelain)"
if [ "$OLD_UPDATER" = 1 ]; then
  out="$(run "$A" bash "$A/tools/canon" update --to v1.0.0 2>&1)" || fail "the pre-t-50f7 updater could not move to v1.0.0: $out"
  assert_contains "$out" "canon is now on v1.0.0"; [ ! -e "$A/packages" ] || fail "the OLD updater must not know the layout"
else
  echo "canon-migrate: NOTE the pre-t-50f7 updater (8bf36c67) is not in this checkout's history; doing its git checkout of v1.0.0 directly"
  git -C "$A" -c advice.detachedHead=false checkout -q --detach v1.0.0
fi
DATA="$(data_sum "$A")"
out="$(run "$A" "$A/tools/canon" update 2>&1)" || fail "the new update did not move the install into the layout: $out"
assert_contains "$out" "canon is now in $A/packages/v1.0.0"
assert_eq "packages/v1.0.0" "$(readlink "$A/current")"; assert_eq "current/tools" "$(readlink "$A/tools")"
[ -d "$A/packages/v1.0.0/.git" ] && [ -f "$A/packages/v1.0.0/tools/canon" ] || fail "the package is not the clone"
assert_eq ".canon-track? cockpit current events integrity logs packages settings.json themes tools" \
  "$(cd "$A" && for e in * .[!.]*; do [ -e "$e" ] || [ -L "$e" ] || continue; echo "$e"; done | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//; s/^/.canon-track? /')"
assert_eq "$DATA" "$(data_sum "$A")"
assert_eq "canon 1.0.0" "$(run "$A" "$A/tools/canon" version)"   # an old PATH line (<home>/tools) still reaches canon
echo "canon-migrate: the old updater checks out v1.0.0 in place, then the new update moves the clone into packages/v1.0.0; data unchanged in place"

# ── C7: every stored install path names <home>/current, none a package (prod path: skills.sh refresh, run by the migration) ─────────────────────
C="$A/current"
assert_eq "$C/skills" "$(readlink "$W/p1/.claude/skills")"; assert_eq "$C/skills" "$(readlink "$W/p1/.agents/skills")"
assert_eq "$C/agents" "$(readlink "$W/p1/.claude/agents")"
assert_eq "$C/skills/sprint/SKILL.md" "$(readlink "$W/p2/.claude/skills/sprint/SKILL.md")"
assert_eq "$C/skills" "$(readlink "$W/p1-wt/.claude/skills")"
grep -qxF "@$C/standards/efficiency.md" "$W/p1/AGENTS.md" || fail "p1/AGENTS.md has no current @-import: $(grep '^@' "$W/p1/AGENTS.md")"
assert_eq 0 "$(grep -c "^@$A/standards" "$W/p1/AGENTS.md" || true)"
grep -qxF "CANON_ROOT=\"$C\"" "$W/p1/.git/hooks/pre-commit" || fail "the p1 hook does not name current: $(grep CANON_ROOT "$W/p1/.git/hooks/pre-commit")"
assert_eq "$C" "$(cat "$H/.config/canon/install_path")"
assert_eq "alias ll=\"ls -l\""$'\n\n'"# canon tools"$'\n'"export PATH=\"\$PATH:$C/tools\"" "$(cat "$H/.zshrc")"
stored="$(readlink "$W/p1/.claude/skills" "$W/p1/.agents/skills" "$W/p1/.claude/agents" "$W/p2/.claude/skills/sprint/SKILL.md" "$W/p1-wt/.claude/skills"; \
  grep -h '^@\|CANON_ROOT=' "$W/p1/AGENTS.md" "$W/p1/.git/hooks/pre-commit"; cat "$H/.config/canon/install_path" "$H/.zshrc")"
[[ "$stored" != *"/packages/"* ]] || fail "a stored path names a package: $stored"
echo "canon-migrate: links, worktree links, per-skill links, @-imports, the hook, install_path and the rc line all name current"

# ── C8: a second run changes nothing ────────────────────────────────────────────────────────────────────────────────────────────────────────
proj_sum() { cat "$W/p1/AGENTS.md" "$W/p1/CLAUDE.md" "$W/p1/.git/hooks/pre-commit" "$W/p2/AGENTS.md" "$H/.zshrc" "$H/.config/canon/install_path" 2>/dev/null | cksum
  readlink "$W/p1/.claude/skills" "$W/p1/.claude/agents" "$W/p2/.claude/skills/sprint/SKILL.md" "$W/p1-wt/.claude/skills"; }
P="$(proj_sum)"; PK="$(tree_sum "$A/packages")"
out="$(run "$A" "$A/tools/canon" update 2>&1)" || fail "the second update failed: $out"
assert_contains "$out" "canon is up to date (v1.0.0"; refute_contains "$out" "Moving canon"
assert_eq "$P" "$(proj_sum)"; assert_eq "$PK" "$(tree_sum "$A/packages")"; assert_eq "$DATA" "$(data_sum "$A")"; assert_eq "packages/v1.0.0" "$(readlink "$A/current")"
echo "canon-migrate: a second update changes nothing"

# ── C9, C12: canon uninstall in the layout recognises and removes the whole home, with today's --keep-data rule (prod path: canon uninstall) ──
U="$H/uninst me é"; old_install "$U" v1.0.0
run "$U" "$U/tools/canon" update >/dev/null 2>&1 || fail "could not migrate the uninstall fixture"
printf '%s\n' "$U/current" > "$H/.config/canon/install_path"; printf '[]\n' > "$U/cockpit/projects.json"
mkdir -p "$W/p3"; git -C "$W/p3" init -q -b main; : > "$H/.config/canon/projects"
run "$U" bash "$U/current/tools/skills.sh" add sprint "$W/p3" >/dev/null 2>&1 || fail "skills.sh add sprint (layout) failed"
assert_eq "$U/current/skills" "$(readlink "$W/p3/.claude/skills")"   # C7: a project registered in the layout stores current
bash -c 'exec -a "$0" sleep 300' "$U/packages/v1.0.0/tools/cockpit-daemon/cockpit-daemon" & DP=$!; PIDS+=("$DP")
printf '{"pid": %s}\n' "$DP" > "$W/state/daemon.json"; sleep 0.3
out="$(run "$U" bash "$U/tools/canon" uninstall --dry-run 2>&1)" || fail "uninstall --dry-run failed: $out"
assert_contains "$out" "Install folder: $U"; assert_contains "$out" "-> DELETE"; assert_contains "$out" "will stop: the Cockpit daemon (pid $DP)"
# every package that is a git clone is checked for work only it holds, not only packages/main: the release clone moved in from the
# single-tree install keeps its .git (prod path: canon-uninstall.sh install_verdict / clone_verdict)
echo wip > "$U/packages/v1.0.0/wip.txt"
out="$(run "$U" bash "$U/tools/canon" uninstall --dry-run 2>&1)" || fail "uninstall --dry-run failed: $out"
assert_contains "$out" "-> KEEP: the git clone packages/v1.0.0 has uncommitted or untracked changes"
assert_contains "$out" "rm -rf"   # other KEEP reasons still print the manual-remove hint
rm "$U/packages/v1.0.0/wip.txt"; git -C "$U/packages/v1.0.0" checkout -q -b local-work; git -C "$U/packages/v1.0.0" "${ig[@]}" commit -q --allow-empty -m mine
out="$(run "$U" bash "$U/tools/canon" uninstall --dry-run 2>&1)" || fail "uninstall --dry-run failed: $out"
assert_contains "$out" "-> KEEP: the git clone packages/v1.0.0 has"
git -C "$U/packages/v1.0.0" -c advice.detachedHead=false checkout -q --detach v1.0.0; git -C "$U/packages/v1.0.0" branch -q -D local-work
# anything in the home canon did not put there (a file, a folder) keeps the whole home, as an untracked file kept a single-tree clone; neither
# --yes, --force nor --keep-data deletes it (prod path: canon-uninstall.sh install_verdict, the layout's home check)
echo mine > "$U/notes.txt"; mkdir -p "$U/mydir"; echo f > "$U/mydir/f"
out="$(run "$U" bash "$U/tools/canon" uninstall --dry-run 2>&1)" || fail "uninstall --dry-run failed: $out"
assert_contains "$out" "-> KEEP: it holds 2 item(s) canon did not put there (mydir/, notes.txt); move them out of $U, then run this again"
assert_not_contains "$out" "rm -rf"   # the usual manual-remove hint would delete the user's own files
out="$(run "$U" bash "$U/tools/canon" uninstall --yes --keep-data --force 2>&1)" || true
assert_not_contains "$out" "rm -rf"; assert_contains "$out" "[kept]  $U"; assert_eq mine "$(cat "$U/notes.txt")"; assert_eq f "$(cat "$U/mydir/f")"
[ -d "$U/packages/v1.0.0" ] && [ -L "$U/current" ] && [ -L "$U/tools" ] || fail "a kept home lost part of the install"
rm -rf "$U/notes.txt" "$U/mydir"
mkdir -p "$W/p3/.claude"; ln -s "$U/current/skills" "$W/p3/.claude/skills"   # the run above cleaned p3; register it again for the real uninstall
printf '%s\n' "$U/current" > "$H/.config/canon/install_path"; printf '%s\n' "$W/p3" > "$H/.config/canon/projects"
out="$(run "$U" bash "$U/current/tools/canon" uninstall --yes --keep-data 2>&1)" || fail "uninstall --keep-data failed: $out"
pid_alive "$DP" && fail "uninstall did not stop the daemon it recognised by its package path"
wait "$DP" 2>/dev/null || true
assert_eq "cockpit" "$(ls -A "$U")"; assert_eq "[]" "$(cat "$U/cockpit/projects.json")"
[ ! -e "$W/p3/.claude/skills" ] && [ ! -L "$W/p3/.claude/skills" ] || fail "uninstall left p3's skills link"
grep -qF canon-managed-pre-commit-hook "$W/p3/.git/hooks/pre-commit" 2>/dev/null && fail "uninstall left p3's canon hook"
rm -f "$W/state/daemon.json"
echo "canon-migrate: uninstall in the layout stops the daemon run from a package and removes packages/, current and the tools link, keeping cockpit/"

# ── C8: a failed step moves everything back (prod path: the migration's rollback) ─────────────────────────────────────────────────────────────
if [ "$(id -u)" = 0 ]; then
  echo "canon-migrate: SKIPPED the rollback case: as root a read-only folder can still be moved, so the fault cannot be planted"
else
  B="$H/rollback"; old_install "$B" v1.0.0
  BEFORE="$(tree_sum "$B")"; chmod 555 "$B/scripts"   # a folder that cannot move to a new parent: the move fails part way
  set +e; out="$(run "$B" "$B/tools/canon" update 2>&1)"; code=$?; set -e
  chmod 755 "$B/scripts"
  assert_eq 1 "$code"; assert_contains "$out" "could not move scripts"; assert_contains "$out" "everything was moved back"
  assert_eq "$BEFORE" "$(tree_sum "$B")"; [ ! -e "$B/packages" ] && [ ! -L "$B/current" ] && [ ! -L "$B/tools" ] || fail "the rollback left layout pieces"
  [ -z "$(git -C "$B" status --porcelain)" ] || fail "the rollback left the clone dirty"
  echo "canon-migrate: a move that fails part way is rolled back, the clone byte-identical"
fi

# ── C8: an interrupt (TERM) part way through the move puts everything back (prod path: the migration's INT/TERM/HUP trap) ─────────────────────
# A stub mv on PATH holds the move of scripts/ for 2 s and drops a marker, so the TERM lands mid-move; it goes to the migrating process's own pid.
I="$H/interrupt"; old_install "$I" v1.0.0; BEFORE="$(tree_sum "$I")"
mkdir -p "$W/slowmv"; REAL_MV="$(command -v mv)"
printf '#!/bin/sh\ncase "$*" in *"/scripts "*) if [ ! -e "$MV_MARK" ]; then : > "$MV_MARK"; sleep 2; fi ;; esac\nexec "%s" "$@"\n' "$REAL_MV" > "$W/slowmv/mv"; chmod +x "$W/slowmv/mv"
env -u XDG_RUNTIME_DIR HOME="$H" TMPDIR="$W/tmp" XDG_CONFIG_HOME="$W/xdg" XDG_CACHE_HOME="$W/cache" COCKPIT_STATE_DIR="$W/state" CANON_COCKPIT_PORT=1 \
  CANON_MANIFEST_URL="file://$W/releases.txt" SKILLS_SH_NO_TTY=1 CANON_HOME="$I" MV_MARK="$W/mv.mark" PATH="$W/slowmv:$PATH" \
  "$I/tools/canon" update > "$W/int.out" 2>&1 </dev/null & IP=$!; PIDS+=("$IP")
for i in $(seq 1 50); do [ -e "$W/mv.mark" ] && break; sleep 0.2; done
[ -e "$W/mv.mark" ] || fail "the stub mv never ran (the move did not reach scripts/): $(cat "$W/int.out")"
kill -TERM "$IP"; set +e; wait "$IP"; code=$?; set -e
[ "$code" != 0 ] || fail "an interrupted move exited 0: $(cat "$W/int.out")"
assert_contains "$(cat "$W/int.out")" "could not move $I into the versioned layout (interrupted); everything was moved back"
assert_eq "$BEFORE" "$(tree_sum "$I")"; [ ! -e "$I/packages" ] && [ ! -L "$I/current" ] && [ ! -L "$I/tools" ] || fail "the interrupted move left layout pieces"
[ ! -e "$I/.update.lock" ] || fail "the interrupted move left its lock"
echo "canon-migrate: an interrupt mid-move puts everything back and releases the lock"

# ── C9: the move refuses while this install's Cockpit runs, changing nothing ─────────────────────────────────────────────────────────────────────
R="$H/running"; old_install "$R" v1.0.0; BEFORE="$(tree_sum "$R")"
bash -c 'exec -a "$0" sleep 300' "$R/tools/cockpit-daemon/cockpit-daemon" & DP=$!; PIDS+=("$DP")
printf '{"pid": %s}\n' "$DP" > "$W/state/daemon.json"; sleep 0.3
set +e; out="$(run "$R" "$R/tools/canon" update 2>&1)"; code=$?; set -e
assert_eq 1 "$code"; assert_contains "$out" "the Cockpit daemon (pid $DP)"; assert_contains "$out" "Run 'canon stop'"
assert_eq "$BEFORE" "$(tree_sum "$R")"; pid_alive "$DP" || fail "the refused move stopped the daemon"
kill "$DP"; wait "$DP" 2>/dev/null || true; rm -f "$W/state/daemon.json"
echo "canon-migrate: the move refuses while the Cockpit runs and stops nothing"

# ── C8: a developer clone stays a clone: local commits, or a clone outside CANON_HOME (prod path: canon update's old clone mode) ──────────────────
D="$H/dev"; old_install "$D" v1.0.0; git -C "$D" checkout -q main; printf 'main\n' > "$D/.canon-track"
echo mine > "$D/MINE"; git -C "$D" add MINE; git -C "$D" "${ig[@]}" commit -qm mine
run "$D" "$D/tools/canon" update >/dev/null 2>&1 || true
[ ! -e "$D/packages" ] && [ -f "$D/MINE" ] && [ -d "$D/.git" ] || fail "a clone with local commits was moved"
E="$H/elsewhere"; old_install "$E" v1.0.0
out="$(run "$H/not-this" "$E/tools/canon" update --to v1.0.0 2>&1)" || fail "a clone outside CANON_HOME failed its clone-mode update: $out"
[ ! -e "$E/packages" ] || fail "a clone outside CANON_HOME was moved"; assert_contains "$out" "canon is up to date (v1.0.0"
echo "canon-migrate: a clone with local commits, or outside CANON_HOME, keeps the clone mode"

# ── main track: a clone following main moves into packages/main ──────────────────────────────────────────────────────────────────────────────
M="$H/.canon"; old_install "$M" v1.0.0; git -C "$M" checkout -q main; printf 'main\n' > "$M/.canon-track"
out="$(run "$M" "$M/tools/canon" update 2>&1)" || fail "a main-track install did not move: $out"
assert_eq "packages/main" "$(readlink "$M/current")"; assert_eq main "$(git -C "$M/packages/main" rev-parse --abbrev-ref HEAD)"; assert_eq main "$(cat "$M/.canon-track")"
out="$(run "$M" "$M/tools/canon" update 2>&1)" || fail "the second main-track update failed: $out"; assert_contains "$out" "canon is up to date"
echo "canon-migrate: a main-track install moves into packages/main and keeps following main"

assert_eq canary "$(cat "$H/canary")"; assert_eq canary "$(cat "$W/tmp/canary")"
echo "canon-migrate: ok"
