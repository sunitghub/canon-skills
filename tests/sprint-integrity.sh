#!/usr/bin/env bash
# t-2af0: protects `sprint complete`'s integrity gate (tools/sprint _gate_integrity): in an install that came from a release, a
# changed or missing gate file refuses the close (exit 1, names the file and the restore command, emits gate.rejected
# reason=integrity); every other state (clean, no list, a corrupt saved list, a main install, canon's own checkout, a missing or older
# board) prints one line at most and does not refuse. The gate asks the install's own board, so no variable the caller sets moves it
# (SPRINT_CHECK_BIN and invented skip names are tried below); the limits left are in docs/setup.md.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export CANON_HOME="$work/home"; mkdir -p "$CANON_HOME"
export SPRINT_CHECK_NO_BROWSER=1
board_bin="$(build_board "$work/board")"   # copied into each install
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

GATE_FILES=(tools/sprint tools/gate-snapshot.sh tools/subagent-log.sh tools/evidence.sh tools/sprint-headless tools/sprint-headless-eval tools/gate-model.sh tools/sprint.cmd tools/sprint-headless.cmd tools/sprint-headless-eval.cmd)
GATE_PROMPTS=(agents/canon-reviewer.md agents/canon-evaluator.md skills/sprint/reference/review.md skills/sprint/reference/eval.md skills/sprint/reference/shared-gate-protocol.md skills/sprint/reference/visual-verify.md)

# An install copy whose list (saved under CANON_HOME/integrity, as a first online check would) matches the copy exactly.
new_install() {
  local inst="$1" ver=9.8.7 p sep
  rm -rf "$inst"; copy_canon_tree "$inst"
  mkdir -p "$inst/tools/canon-go-bin"; cp "$board_bin" "$inst/tools/canon-go-bin/canon-go"
  printf '%s\n' "$ver" > "$inst/VERSION"
  rm -f "$inst/.canon-track"; rm -rf "$CANON_HOME/integrity"; mkdir -p "$CANON_HOME/integrity"
  {
    printf '{"tag":"v%s","commit":"%s","gate_files":[' "$ver" "$(printf 'a%.0s' $(seq 40))"
    sep=""; for p in "${GATE_FILES[@]}"; do printf '%s"%s"' "$sep" "$p"; sep=,; done
    printf '],"gate_prompts":['
    sep=""; for p in "${GATE_PROMPTS[@]}"; do printf '%s"%s"' "$sep" "$p"; sep=,; done
    printf '],"exec_files":["tools/tkt.cmd","tools/canon.cmd"],"files":{'   # t-16f5: launchers that are not gate files (t-ee92: the three that start a gate file's program are gate files)
    sep=""; for p in "${GATE_FILES[@]}" "${GATE_PROMPTS[@]}" tools/cockpit-daemon.sha256 tools/tkt.cmd tools/canon.cmd; do printf '%s"%s":"%s"' "$sep" "$p" "$(sha "$inst/$p")"; sep=,; done
    printf '}}\n'
  } > "$CANON_HOME/integrity/v$ver.json"
  sha "$CANON_HOME/integrity/v$ver.json" > "$CANON_HOME/integrity/v$ver.pin"
}

project="$(make_project)"; trap 'rm -rf "$work" "$project"' EXIT
inst="$work/install"; new_install "$inst"
cd "$project"
git -C "$project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
id="$("$inst/tools/tkt" create "integrity gate" -t task -p 2)"
"$inst/tools/tkt" start "$id" >/dev/null

complete() { set +e; out="$("$inst/tools/sprint" complete 2>&1)"; rc=$?; set -e; }
# fail open means the close went ON to its next gate (the fixture has no sprint files, so that gate is the one that speaks)
not_refused() {
  [[ "$out" != *"cannot close: a gate file or gate prompt"* ]] || fail "$1: the integrity gate refused the close: $out"
  [[ "$out" == *"Missing required sprint file"* ]] || fail "$1: the close did not go on to its next gate: $out"
}

# Clean install: the gate passes with one line; the close stops later, at a gate that has nothing to do with integrity.
complete
not_refused "a clean install"
assert_contains "$out" "integrity: 19 of 19 files match release v9.8.7"

# One byte appended to a gate file: refused, with the file and the restore command, and an event.
printf '#' >> "$inst/tools/gate-model.sh"
complete
[[ "$rc" -eq 1 ]] || fail "a changed gate file must exit 1, got $rc: $out"
assert_contains "$out" "cannot close: a gate file or gate prompt in this canon install differs"
assert_contains "$out" "tools/gate-model.sh: changed"
assert_contains "$out" "Put it back: "   # t-a582: the command follows the install (a flat fixture: install.sh here, canon update on Windows)
assert_contains "$(event_line gate.rejected "$id")" '"reason":"integrity"'

# A deleted gate prompt: refused too.
new_install "$inst"; rm "$inst/agents/canon-evaluator.md"
complete
[[ "$rc" -eq 1 ]] && [[ "$out" == *"agents/canon-evaluator.md: missing"* ]] || fail "a missing gate prompt must refuse: rc=$rc $out"

# t-16f5: an edited launcher that starts no gate file (tools/tkt.cmd) and a changed programs manifest never refuse, but the
# close names the launcher on its one integrity line. Before this ticket the line said every file matched.
new_install "$inst"; printf '#' >> "$inst/tools/cockpit-daemon.sha256"
complete; not_refused "a changed programs manifest"
assert_contains "$out" "integrity: 18 of 19 files match release v9.8.7"
new_install "$inst"; printf '@echo Updated\n' >> "$inst/tools/tkt.cmd"
complete; not_refused "an edited launcher"
assert_contains "$out" "integrity: 18 of 19 files match release v9.8.7; tools/tkt.cmd differs"
# t-ee92: the launchers of the gate files ARE gate files. On Windows `sprint complete` runs through tools/sprint.cmd, so one that is edited (it could
# run a different script while tools/sprint still matched) refuses the close like its twin; so does a deleted one.
for l in tools/sprint.cmd tools/sprint-headless.cmd tools/sprint-headless-eval.cmd; do
  new_install "$inst"; printf '@echo Updated\n' >> "$inst/$l"
  complete; [[ "$rc" -eq 1 ]] || fail "an edited $l must refuse the close, got $rc: $out"
  assert_contains "$out" "cannot close: a gate file or gate prompt in this canon install differs"; assert_contains "$out" "$l: changed"
done
new_install "$inst"; rm "$inst/tools/sprint.cmd"
complete; [[ "$rc" -eq 1 && "$out" == *"tools/sprint.cmd: missing"* ]] || fail "a missing tools/sprint.cmd must refuse: rc=$rc $out"
assert_contains "$(event_line gate.rejected "$id")" '"reason":"integrity"'

# Fail open, even with a changed gate file in the install:
new_install "$inst"; printf '#' >> "$inst/tools/gate-model.sh"
echo main > "$inst/.canon-track"
complete; not_refused "a main install"; assert_contains "$out" "not-from-release"
rm -f "$inst/.canon-track"

# canon's own checkout: a git checkout whose HEAD is not the release tag.
git -C "$inst" init -q && git -C "$inst" add -A >/dev/null 2>&1 && git -C "$inst" -c gc.auto=0 -c maintenance.auto=false -c user.email=t@t -c user.name=t commit -q -m dev   # no background maintenance: it raced the rm -rf below ('.git: Directory not empty')
complete; not_refused "a checkout that is not at the tag"; assert_contains "$out" "not exactly at v9.8.7"
rm -rf "$inst/.git"

# t-cb66, the versioned layout (prod path: `sprint complete` run as <home>/current/tools/sprint, its board in the package). A release package
# with a changed gate file still refuses, even with `main` in CANON_HOME's .canon-track (never read); packages/main with `main` in
# <home>/.canon-track is the main track, read from the home, not "not exactly at" from the package.
L="$work/lhome"; mkdir -p "$L/packages"; new_install "$L/packages/v9.8.7"; ln -s packages/v9.8.7 "$L/current"
printf '#' >> "$L/packages/v9.8.7/tools/gate-model.sh"; echo main > "$CANON_HOME/.canon-track"
set +e; out="$("$L/current/tools/sprint" complete 2>&1)"; rc=$?; set -e
[[ "$rc" -eq 1 && "$out" == *"tools/gate-model.sh: changed"* ]] || fail "a changed gate file in a release package must refuse: rc=$rc $out"
rm -f "$CANON_HOME/.canon-track"
mv "$L/packages/v9.8.7" "$L/packages/main"; rm "$L/current"; ln -s packages/main "$L/current"; echo main > "$L/.canon-track"
git -C "$L/packages/main" init -q && git -C "$L/packages/main" add -A >/dev/null 2>&1 && git -C "$L/packages/main" -c gc.auto=0 -c maintenance.auto=false -c user.email=t@t -c user.name=t commit -q -m main
set +e; out="$("$L/current/tools/sprint" complete 2>&1)"; rc=$?; set -e
not_refused "packages/main with the home marker"; assert_contains "$out" "this install follows main"
rm -rf "$L"

# a corrupt saved list (it no longer equals its pin) and no saved list at all: never a refusal, whatever the network answers
printf '{"tag":"v9.8.7","files":{}}' > "$CANON_HOME/integrity/v9.8.7.json"
complete; not_refused "a corrupt saved list"
rm -rf "$CANON_HOME/integrity"
complete; not_refused "no saved list"

# no variable the caller sets skips the refusal: a swapped board, the root, the network address, a made-up skip name
new_install "$inst"; printf '#' >> "$inst/tools/gate-model.sh"
printf '#!/bin/sh\necho "integrity: stub says fine"\n' > "$work/stub-board"; chmod +x "$work/stub-board"
for kv in "SPRINT_CHECK_BIN=$work/stub-board" "SPRINT_CHECK_BIN=/bin/true" "CANON_SKIP_INTEGRITY=1" "CANON_INTEGRITY_ROOT=$work" "CANON_INTEGRITY_URL=https://127.0.0.1:9/x" "TKT_SPRINT_GATE_PASSED=1" "CI=true"; do
  env "$kv" "$inst/tools/sprint" complete >"$work/skip.out" 2>&1 && rc=0 || rc=$?
  [[ "$rc" -eq 1 ]] && grep -q "cannot close: a gate file or gate prompt" "$work/skip.out" || fail "$kv skipped the refusal (rc=$rc): $(cat "$work/skip.out")"
done

# a missing board binary and a board that predates the command: fail open
new_install "$inst"; printf '#' >> "$inst/tools/gate-model.sh"
mv "$inst/tools/canon-go-bin/canon-go" "$work/moved-board"
complete; not_refused "a missing board"
printf '#!/bin/sh\necho "old board"\n' > "$inst/tools/canon-go-bin/canon-go"; chmod +x "$inst/tools/canon-go-bin/canon-go"
complete; not_refused "a board without the command"

echo "sprint-integrity: ok"
