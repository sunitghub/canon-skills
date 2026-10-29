#!/usr/bin/env bash
# build-zip.sh — rebuilds the local native canon-go (the board and the daemon, t-bdb0; a gitignored dev convenience) for the Admin Versions panel.
# t-9383: the Windows exe is no longer built or committed here; scripts/release-daemon.sh publishes it as a checksum-verified release
# asset and tools/fetch-daemon.sh puts it in place.
# Run directly or called by .git/hooks/post-commit via scripts/install-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Binary: tools/canon-go-bin/canon-go (native host build) ────────
# t-af51 follow-up: the board runs THIS binary on macOS/Linux, and starts it again as `canon-go daemon` (the Windows exe is a fetched
# release asset, not built here) — without a stamped rebuild here, a plain `go build` leaves main.commit at "dev" and main.daemonKey empty,
# so the Admin Versions panel never shows a real build id and the board cannot tell a stale daemon. The stamps are the release's
# (tools/src-key.sh canon_ldflags); the semantic version is not stamped: canon-go reads the repo's VERSION (t-0859).
# Gitignored (/tools/canon-go-bin/) — native binaries aren't portable across platforms/architectures, so this stays local-only.
if command -v go >/dev/null 2>&1; then
  # shellcheck source=tools/src-key.sh
  source "$REPO_ROOT/tools/src-key.sh"
  STAMPS="$(canon_ldflags "$REPO_ROOT" 2>/dev/null)" || STAMPS=""
  CDV="$(sed -n 's/.*main\.commit=\([^ ]*\).*/\1/p' <<<"$STAMPS")"; CDV="${CDV:-dev}"   # for the message only
  SEMVER="$(tr -d ' \t\n\r' < "$REPO_ROOT/VERSION" 2>/dev/null || echo dev)"   # for the message only
  GOEXE="$(go env GOEXE)"
  mkdir -p "$REPO_ROOT/tools/canon-go-bin"
  ( cd "$REPO_ROOT/tools/canon-go" && go build \
      -buildvcs=false \
      -ldflags "$STAMPS" \
      -o "$REPO_ROOT/tools/canon-go-bin/canon-go$GOEXE" ./cmd/canon-go )
  echo "dist: canon-go$GOEXE (native) rebuilt [v$SEMVER ($CDV)]"
else
  echo "dist: canon-go (native) skipped (go absent)"
fi
