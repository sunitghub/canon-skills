#!/usr/bin/env bash
# build-zip.sh — rebuilds the committed Windows binaries (tools/*-win.exe) and the local native cockpit-daemon
# Run directly or called by .git/hooks/post-commit via scripts/install-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Binary: sprint-check-win.exe (Windows board server) ─────────────────────
if command -v go >/dev/null 2>&1; then
  # t-99fa: stamp the build id = short SHA of the last commit touching the
  # binary's source dir. Deterministic given source → byte-identical when source
  # is unchanged → no per-commit .exe churn (respects t-b612's no-churn goal).
  # t-5c20: `main.version` now carries the semantic version (repo-root VERSION),
  # the human identifier; the SHA moves to `main.commit` (build provenance).
  SCV="$(git -C "$REPO_ROOT" log -1 --format=%h -- tools/sprint-check-go 2>/dev/null || echo dev)"
  SEMVER="$(tr -d ' \t\n\r' < "$REPO_ROOT/VERSION" 2>/dev/null || echo dev)"
  # t-b9a7: build the package, not main.go alone — skilleval.go (and any later file) must be in the
  # .exe. A package dir without go.mod needs GO111MODULE=off. tests/build-zip-go-package.sh locks this.
  ( cd "$REPO_ROOT" && GO111MODULE=off GOOS=windows GOARCH=amd64 go build \
    -ldflags "-X main.version=$SEMVER -X main.commit=$SCV" \
    -o "$REPO_ROOT/tools/sprint-check-win.exe" \
    ./tools/sprint-check-go )
  echo "dist: sprint-check-win.exe rebuilt ($(du -sh "$REPO_ROOT/tools/sprint-check-win.exe" | cut -f1)) [v$SEMVER ($SCV)]"
else
  echo "dist: sprint-check-win.exe skipped (go absent)"
fi

# ── Binary: sprint-headless-json-win.exe (Windows JSON-parse helper) ────────
if command -v go >/dev/null 2>&1; then
  GOOS=windows GOARCH=amd64 go build \
    -o "$REPO_ROOT/tools/sprint-headless-json-win.exe" \
    "$REPO_ROOT/tools/sprint-headless-json-go/main.go"
  echo "dist: sprint-headless-json-win.exe rebuilt ($(du -sh "$REPO_ROOT/tools/sprint-headless-json-win.exe" | cut -f1))"
else
  echo "dist: sprint-headless-json-win.exe skipped (go absent)"
fi

# ── Binary: cockpit-daemon-win.exe (Windows cockpit PTY backend) ────────────
# Own Go module (tools/cockpit-daemon/go.mod) → build from its dir, module mode.
# -buildvcs=false (t-b612): a module-mode build inside a git repo auto-stamps
# the current HEAD commit hash into the binary, so it differs on every single
# commit regardless of whether this module's own source changed — omit that
# metadata entirely rather than chase a "flaky" rebuild that was actually
# fully deterministic given its real (constantly-changing) input.
if command -v go >/dev/null 2>&1; then
  # t-99fa: build id = short SHA of the last commit touching tools/cockpit-daemon
  # (deterministic given source → no per-commit churn; complements -buildvcs=false).
  # t-5c20: `main.version` carries the semver (repo VERSION); SHA → `main.commit`.
  CDV="$(git -C "$REPO_ROOT" log -1 --format=%h -- tools/cockpit-daemon 2>/dev/null || echo dev)"
  SEMVER="$(tr -d ' \t\n\r' < "$REPO_ROOT/VERSION" 2>/dev/null || echo dev)"
  ( cd "$REPO_ROOT/tools/cockpit-daemon" && GOOS=windows GOARCH=amd64 go build \
      -buildvcs=false \
      -ldflags "-X main.version=$SEMVER -X main.commit=$CDV" \
      -o "$REPO_ROOT/tools/cockpit-daemon-win.exe" . )
  echo "dist: cockpit-daemon-win.exe rebuilt ($(du -sh "$REPO_ROOT/tools/cockpit-daemon-win.exe" | cut -f1)) [v$SEMVER ($CDV)]"
else
  echo "dist: cockpit-daemon-win.exe skipped (go absent)"
fi

# ── Binary: tools/cockpit-daemon/cockpit-daemon (native host build) ────────
# t-af51 follow-up: server.py's _resolve_cockpit_daemon() runs THIS binary
# directly on macOS/Linux (the Windows .exe above is only ever resolved on a
# Windows host) — without a stamped rebuild here, a plain `go build` leaves
# main.version/main.commit at their zero-value "dev" default, so the Admin
# Versions panel never shows a real build id for a non-Windows dev machine.
# Gitignored (tools/cockpit-daemon/.gitignore) — native binaries aren't
# portable across platforms/architectures, so this stays local-only, unlike
# the committed cross-compiled Windows exe above.
if command -v go >/dev/null 2>&1; then
  CDV="$(git -C "$REPO_ROOT" log -1 --format=%h -- tools/cockpit-daemon 2>/dev/null || echo dev)"
  SEMVER="$(tr -d ' \t\n\r' < "$REPO_ROOT/VERSION" 2>/dev/null || echo dev)"
  GOEXE="$(go env GOEXE)"
  ( cd "$REPO_ROOT/tools/cockpit-daemon" && go build \
      -buildvcs=false \
      -ldflags "-X main.version=$SEMVER -X main.commit=$CDV" \
      -o "$REPO_ROOT/tools/cockpit-daemon/cockpit-daemon$GOEXE" . )
  echo "dist: cockpit-daemon$GOEXE (native) rebuilt [v$SEMVER ($CDV)]"
else
  echo "dist: cockpit-daemon (native) skipped (go absent)"
fi
