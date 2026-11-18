#!/usr/bin/env bash
# gate-base (t-99d2) — the close gates' diff base follows the repository's default branch, not a hard-coded origin/main. Protects every
# close's gates in a project whose default branch is master (the user's ToDo-Demo): `sprint base-ref` (owner: gate_base in
# tools/ticket-root.sh), pre-gate-check, skill-eval-scope, mutant-sweep's base (through sprint, and its own lookup without it) and the
# headless tools' default base ref (default_base_ref). A main repository is unchanged; no default branch gives the reason, exit 1.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
W="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home" CANON_HOME="$W/canon-home" XDG_CONFIG_HOME="$W/xdg" TMPDIR="$W/tmp"; mkdir -p "$HOME" "$TMPDIR"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset CANON_TICKETS_DIR PRE_GATE_BASE

# repo <dir> <branch>: a bare origin whose HEAD is <branch>, a clone, one commit on a work branch past the base
repo() {
  git init -q --bare -b "$2" "$W/$1.git"
  git clone -q "$W/$1.git" "$W/$1" 2>/dev/null; cd "$W/$1"; git checkout -q -b "$2" 2>/dev/null || true
  echo base > README.md; git add README.md; git commit -qm base; git push -q origin "$2"; git remote set-head origin -a >/dev/null 2>&1 || true
  BASE="$(git rev-parse HEAD)"; git checkout -q -b work; echo change > notes.md; git add notes.md; git commit -qm work
}
sb() { "$SPRINT" base-ref 2>&1; }

# 1. a master repository (origin/HEAD -> origin/master, no origin/main)
repo m master
git rev-parse -q --verify refs/remotes/origin/main >/dev/null && fail "fixture: origin/main exists"
assert_eq "$BASE" "$(sb)"
out="$(bash "$ROOT/tools/pre-gate-check.sh" --run 2>&1)" || fail "pre-gate-check failed in a master repo: $out"
assert_contains "$out" "pre-gate |"
bash "$ROOT/tools/skill-eval-scope.sh" >/dev/null 2>"$W/err" || fail "skill-eval-scope failed in a master repo: $(cat "$W/err")"
( source "$ROOT/tools/platform-lib.sh"; source "$ROOT/tools/ticket-root.sh"; assert_eq origin/master "$(default_base_ref .)" )
# mutant-sweep's base: through `sprint base-ref` (sprint on PATH), and its own lookup when sprint is not installed
ms() { PATH="$1" python3 - "$ROOT/tools/mutant-sweep.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ms", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
r, what = m.gate_base(); print((r.stdout or '').strip() if r.returncode == 0 else 'FAIL ' + what)
PY
}
mkdir -p "$W/bin"; ln -sf "$SPRINT" "$W/bin/sprint"
assert_eq "$BASE" "$(ms "$W/bin:/usr/bin:/bin")"
assert_eq "$BASE" "$(ms "/usr/bin:/bin")"   # no sprint on PATH: mutant-sweep's own origin/HEAD lookup
mkdir -p "$W/old"; printf '#!/bin/sh\necho "Unknown command: $1" >&2; exit 1\n' > "$W/old/sprint"; chmod +x "$W/old/sprint"
assert_eq "$BASE" "$(ms "$W/old:/usr/bin:/bin")"   # an older sprint without base-ref: mutant-sweep falls back to its own lookup
echo "gate-base: a master repository's gates find their base (sprint base-ref, pre-gate, skill-eval-scope, mutant-sweep, headless default)"

# 2. a main repository: unchanged
repo n main
assert_eq "$BASE" "$(sb)"
( source "$ROOT/tools/platform-lib.sh"; source "$ROOT/tools/ticket-root.sh"; assert_eq origin/main "$(default_base_ref .)" )

# 3. no remote default branch: the reason, exit 1, and the callers say it
mkdir -p "$W/lone"; cd "$W/lone"; git init -q -b trunk; echo x > a; git add a; git commit -qm x
rc=0; out="$(sb)" || rc=$?; assert_eq 1 "$rc"; assert_contains "$out" "no default branch"
rc=0; out="$(bash "$ROOT/tools/pre-gate-check.sh" --run 2>&1)" || rc=$?
[[ "$rc" == 2 ]] || fail "pre-gate-check without a base: rc $rc ($out)"; assert_contains "$out" "pre-gate: no git baseline (no default branch"
git checkout -q -b main; rc=0; out="$(sb)" || rc=$?; assert_eq 1 "$rc"; assert_contains "$out" "no origin/main to compare with"

# 4. one owner: no tool or skill doc computes the gates' base from a literal origin/main
hits="$(grep -rnI --exclude-dir=evals "merge-base HEAD origin/main" "$ROOT/tools" "$ROOT/skills" 2>/dev/null || true)"   # evals/: scored scenario prompts, not instructions
[[ -z "$hits" ]] || fail "a tool or skill still derives the base from origin/main: $hits"
echo "gate-base: ok"
