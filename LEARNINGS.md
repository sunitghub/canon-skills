# Learnings

learnings-sweep last run: 09-12-2026 10:08

<!-- canon:learnings:BEGIN -->
| Date | Ticket | Finding | Status |
|---|---|---|---|
| 2026-09-12 | [t-145c](.tickets/t-145c/learnings.md) | Windows Git Bash verification of `wc -l`/subagent dispatch was deferred — no Windows machine available this session; treat as unverified until tested live, not assumed identical to macOS. | UNPROMOTED |
| 2026-08-24 | [t-96a8](.tickets/t-96a8/learnings.md) | Read-only eval-gate instances can't execute Playwright/shell tests or capture screenshots, forcing `partial` grades even when source-level evidence is strong — re-dispatch with full tool access to close the gap. | UNPROMOTED |
| 2026-08-24 | [t-ddc8](.tickets/t-ddc8/learnings.md) | Re-evaluating against a live daemon (not stubs) directly verifies the security-relevant claim that it spawns the real, unmodified CLI — stronger evidence than a user-report-only verification. | UNPROMOTED |
| 2026-08-24 | [t-4d26](.tickets/t-4d26/learnings.md) | A rebuilt Windows binary committed alongside every prior `main.go`-touching commit is a pre-existing convention, not out-of-scope creep — disclose it, don't fail the criterion on it. | UNPROMOTED |
<!-- canon:learnings:END -->
