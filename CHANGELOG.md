# Changelog

All notable changes to canon are listed here, newest first, in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) form.

**Versioning.** The number in `VERSION` is [SemVer](https://semver.org): a patch for fixes, a minor for new features that keep working as before, a major for a change that breaks a tool's command line or the install layout. A release is a `VERSION` bump, a dated section below, and an annotated tag `vX.Y.Z` on the public repo, made by `scripts/release.sh` (see `docs/releasing.md`). Commits between releases are listed under Unreleased. To stay on a release, or go back to one: `canon update --to vX.Y.Z`.

## [Unreleased]

### Added
- Releases are verified: `canon update --to vX.Y.Z` (git installs) and the Windows installer check the release against the published manifest at getcanon.dev/releases.txt, and refuse, changing nothing, if it is unreachable, missing, malformed or disagrees. The Windows zip is checked against its SHA-256 before extraction. `main` stays unverified and says so (`t-34f1`).
- `scripts/release-zip.sh` builds the release zip; `scripts/release.sh` attaches it to the GitHub release and prints the manifest line.
- Gate runtime: `tools/evidence.sh stamp` writes builder evidence that names the commit it tested, `check` says whether a log is still fresh, and the evaluator reuses a fresh log for repeats of the same command while still running its own floor (changed suites, mutants, a spot-check) under a 25-minute budget; the evaluator's minutes are now recorded in the Wrapup Gates `eval` row (`t-e3cd`).
- Skill evals on change: `sprint complete` runs the evals of any skill whose instructions (or a gate agent) the sprint edited, advisory only, and records the pass rate in `skills/<name>/evals/history.jsonl` (`tools/skill-eval-scope.sh`, `tools/skill-eval-history.sh`); a defect traced to a skill's own instructions can become an `evals.json` case (`t-8d28`).

### Changed
- `canon update` and the installers follow the latest verified release by default, like most software; `main` is the opt-in development track (`canon update --to main`, `CANON_REF=main`). The newest release is read from the same published manifest as `--to vX.Y.Z` (`tools/release-manifest.sh --latest`, numeric order, same checks, no fallback). An install made before this moves to the latest release on its next plain update, once, with a message (local commits or uncommitted changes refuse, changing nothing). A rollback with `--to vX.Y.Z` is not sticky (from v0.4.0: v0.3.0's older updater still refuses a plain update as pinned; run `canon update --to main` once). `canon version` says when the install follows main. A new install that cannot verify a release installs nothing (`t-65c9`).

### Security
- The prebuilt binaries are built with a pinned Go 1.27.2, not whatever Go is installed: `toolchain go1.27.2` in `tools/cockpit-daemon/go.mod`, and a `GO_TOOLCHAIN` file in `tools/sprint-check-go` and `tools/sprint-headless-json-go` that `scripts/release-daemon.sh` builds with. Go 1.27.1 had 6 net/http and HTTP/2 vulnerabilities the daemon's loopback server could reach and 9 in the Windows board exe; `govulncheck` now reports no reachable vulnerability in any of the three (the one advisory still listed at module level for the daemon, GO-2026-5932, is the unmaintained `x/crypto/openpgp` package, which has no fix and which the daemon does not link). `scripts/release-daemon.sh` sets each build's toolchain explicitly and checks every built binary with `go version -m` before publishing. `golang.org/x/crypto` is v0.58.0, which clears the 13 Dependabot alerts (the daemon never called that code). Because a pin lives in the source folder, the fix ships as new releases; v0.3.0's manifest keeps pointing at its own assets (`t-7efe`).

## [0.3.0] - 2026-10-08

The first tagged release. The highlights since canon became installable on Windows; earlier history is not itemised.

### Added
- `canon update --to <vX.Y.Z|main>` pins an install to a release, or returns it to main (`t-30fc`).
- `--json` on `tkt ls`, `tkt show` and `sprint status`, with the shapes in `tools/ticket.md` (`t-262a`).
- One-line Windows install and the same `canon` command in PowerShell, cmd and Git Bash (`t-8716`, `t-03a8`).
- `canon wait`, to block until a session needs you or is done (`t-d9e6`), and `canon uninstall` (`t-3897`).
- Cockpit: two projects side by side or stacked (`t-416c`), and a keyboard prefix (`ctrl+.` by default) with a `?` cheat sheet (`t-a198`).
- Projects that are not git repositories can be registered; canon keeps its own record of what the agent changed (`t-d538`).
- The cockpit daemon, the Windows board and the headless helper are checksum-verified release assets fetched on install and update, not committed binaries (`t-9383`).

### Changed
- `sprint complete` refuses a close when tracked files changed after the evaluator graded (`t-1b74`), and rejects a reviewer report that lists no per-concern line (`t-de16`).

### Fixed
- Windows: a worktree's tickets landed under the worktree instead of the project's `.tickets/`, and the stale-evaluation check never matched there (`t-7301`).
