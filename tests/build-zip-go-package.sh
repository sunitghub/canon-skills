#!/usr/bin/env bash
# build-zip-go-package (t-b9a7, t-9383, t-8020) — the released board must be built from its whole package: building main.go alone
# once silently left skilleval.go (Skill Eval) out of sprint-check-win.exe. Since t-8020 the board is cmd/sprint-check in the
# tools/canon-go module, which imports all of internal/board; scripts/release-daemon.sh builds it with build_module. Both
# release builds must keep the commit stamping (t-5c20) and the reproducibility flags, and must not stamp VERSION (t-0859: a
# release's bytes may not depend on it; the binaries read it from the install). build_legacy (the headless helper) must stage every
# non-test file of its package.
set -euo pipefail
export SPRINT_CHECK_NO_BROWSER=1   # no board starts here; tests/no-browser-in-tests.sh matches a board binary spelling
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
f="$ROOT/scripts/release-daemon.sh"
for name in build_module build_legacy; do
  fn="$(sed -n "/^$name()/,/^}/p" "$f" | grep -v '^[[:space:]]*#')"
  [[ -n "$fn" ]] || fail "build-zip-go-package: no $name in $f"
  grep -q -- '-trimpath' <<<"$fn" && grep -q -- '-buildvcs=false' <<<"$fn" || fail "build-zip-go-package: $name dropped -trimpath/-buildvcs=false (the bytes would depend on the checkout path)"
  grep -q -- '-X main.commit=' <<<"$fn" || fail "build-zip-go-package: $name dropped commit stamping (t-5c20)"
done
legacy="$(sed -n '/^build_legacy()/,/^}/p' "$f" | grep -v '^[[:space:]]*#')"
grep -qF "'*.go'" <<<"$legacy" && grep -qF "! -name '*_test.go'" <<<"$legacy" || fail "build-zip-go-package: build_legacy must stage every non-test .go file of the package"
[ "$(grep -c -- 'main.version' "$f")" -eq 0 ] || fail "build-zip-go-package: release-daemon.sh stamps main.version again (t-0859: VERSION must stay out of the release bytes)"
grep -qE '^ *build_module sprint-check ' "$f" || fail "build-zip-go-package: the board is not built with build_module from cmd/sprint-check"
# the board's command compiles the whole board package, Skill Eval included
grep -q '"canon/internal/board"' "$ROOT/tools/canon-go/cmd/sprint-check/main.go" || fail "build-zip-go-package: cmd/sprint-check does not import internal/board"
[[ -f "$ROOT/tools/canon-go/internal/board/skilleval.go" ]] || fail "build-zip-go-package: skilleval.go is not in internal/board"
echo "build-zip-go-package: ok"
