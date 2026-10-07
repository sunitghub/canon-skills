#!/usr/bin/env bash
# build-zip.sh — rebuilds the local native cockpit-daemon (a gitignored dev convenience) for the Admin Versions panel.
# t-9383: the Windows exes (tools/*-win.exe) are no longer built or committed here; scripts/release-daemon.sh publishes them as
# checksum-verified release assets and tools/fetch-daemon.sh puts them in place.
# Run directly or called by .git/hooks/post-commit via scripts/install-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Binary: tools/cockpit-daemon/cockpit-daemon (native host build) ────────
# t-af51 follow-up: server.py's _resolve_cockpit_daemon() runs THIS binary
# directly on macOS/Linux (the Windows exes are fetched release assets, not built
# here) — without a stamped rebuild here, a plain `go build` leaves
# main.version/main.commit at their zero-value "dev" default, so the Admin
# Versions panel never shows a real build id for a non-Windows dev machine.
# Gitignored (tools/cockpit-daemon/.gitignore) — native binaries aren't
# portable across platforms/architectures, so this stays local-only.
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
