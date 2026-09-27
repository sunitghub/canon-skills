#!/usr/bin/env bash
# build-zip-go-package (t-b9a7) — the Windows board must be built from the whole
# tools/sprint-check-go package: building main.go alone silently leaves skilleval.go (Skill Eval)
# out of sprint-check-win.exe. Also keeps GO111MODULE=off (a package dir without go.mod needs it)
# and the t-5c20 version/commit stamping.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
f="$ROOT/scripts/build-zip.sh"
pkg="tools/sprint-check-go"
line="$(grep -n 'tools/sprint-check-win.exe"' "$f" | head -1 | cut -d: -f1)" || true
[[ -n "$line" ]] || fail "build-zip-go-package: no sprint-check-win.exe build in $f"
seg="$(sed -n "$((line - 4)),$((line + 2))p" "$f" | grep -v '^[[:space:]]*#')"   # comments don't count
grep -q 'go build' <<<"$seg" || fail "build-zip-go-package: no go build next to the sprint-check-win.exe output"
grep -qF "./$pkg" <<<"$seg" || fail "build-zip-go-package: sprint-check-win.exe must build the whole Go board package"
if grep -qF "$pkg/main.go" <<<"$seg"; then fail "build-zip-go-package: sprint-check-win.exe builds main.go alone (skilleval.go would be missing)"; fi
grep -q 'GO111MODULE=off' <<<"$seg" || fail "build-zip-go-package: the package build needs GO111MODULE=off"
grep -q -- '-X main.version=' <<<"$seg" && grep -q -- '-X main.commit=' <<<"$seg" || fail "build-zip-go-package: version/commit stamping (t-5c20) dropped"
echo "build-zip-go-package: ok"
