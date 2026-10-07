#!/usr/bin/env bash
# build-zip-go-package (t-b9a7, t-9383) — the Windows board must be built from the whole tools/sprint-check-go package:
# building main.go alone silently leaves skilleval.go (Skill Eval) out of sprint-check-win.exe. The exe is built by
# scripts/release-daemon.sh now (build_legacy: a staged module copy, so the bytes do not depend on the checkout path), and it
# must keep the version/commit stamping (t-5c20) and the reproducibility flags.
set -euo pipefail
export SPRINT_CHECK_NO_BROWSER=1   # no board starts here; tests/no-browser-in-tests.sh matches the tools/sprint-check-go source path
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
f="$ROOT/scripts/release-daemon.sh"
pkg="tools/sprint-check-go"
fn="$(sed -n '/^build_legacy()/,/^}/p' "$f" | grep -v '^[[:space:]]*#')"
[[ -n "$fn" ]] || fail "build-zip-go-package: no build_legacy in $f"
grep -qF "'*.go'" <<<"$fn" && grep -qF "! -name '*_test.go'" <<<"$fn" || fail "build-zip-go-package: build_legacy must stage every non-test .go file of the package (main.go alone would drop skilleval.go)"
grep -q -- '-trimpath' <<<"$fn" && grep -q -- '-buildvcs=false' <<<"$fn" || fail "build-zip-go-package: -trimpath/-buildvcs=false dropped (the bytes would depend on the checkout path)"
grep -q -- '-X main.version=' <<<"$fn" && grep -q -- '-X main.commit=' <<<"$fn" || fail "build-zip-go-package: version/commit stamping (t-5c20) dropped"
grep -qE 'build_legacy +tools/sprint-check-go +sprint-check ' "$f" || fail "build-zip-go-package: the board exe is not built from $pkg"
# the staging rule, run for real: both source files of the package would be in the exe
staged="$(find "$ROOT/$pkg" -maxdepth 1 -name '*.go' ! -name '*_test.go' -exec basename {} \; | sort | tr '\n' ' ')"
[[ "$staged" == *main.go* && "$staged" == *skilleval.go* ]] || fail "build-zip-go-package: staging would miss a source file ($staged)"
echo "build-zip-go-package: ok"
