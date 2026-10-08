# Changelog

All notable changes to canon are listed here, newest first, in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) form.

**Versioning.** The number in `VERSION` is [SemVer](https://semver.org): a patch for fixes, a minor for new features that keep working as before, a major for a change that breaks a tool's command line or the install layout. A release is a `VERSION` bump, a dated section below, and an annotated tag `vX.Y.Z` on the public repo, made by `scripts/release.sh` (see `docs/releasing.md`). Commits between releases are listed under Unreleased. To stay on a release, or go back to one: `canon update --to vX.Y.Z`.

## [Unreleased]

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
