# canon-skills PR Review
_sunitghub/canon-skills — reviewed 29/06/2026_

| PR | Title | Area | Findings | Verdict | Opened | Reviewed |
|----|-------|------|----------|---------|--------|----------|
| #4 | refactor(skills): extract sub-modules from monolithic skills.sh | Tooling | The intended module split has already landed on `main` outside this PR, with `addall` removed. The open PR branch is now stale: its diff still includes `cmd_addall`, usage text for `addall`, and the older per-skill removal behavior that can delete shared skill symlinks too early. Merging it now would reintroduce behavior canon deliberately removed. | Recommend Fix N — superseded by `main`; close this PR rather than merging a stale refactor branch. | 28/06/2026 | 29/06/2026 |
| #3 | feat: add submodule setup, IDE config, and sprint workflow polish | DX / Docs | Current diff is `.vscode/tasks.json`, `AGENTS.md`, and `README.md`. The docs still reference `scripts/submodule-setup.sh`, `.vscode/mcp.json`, `opencode.json`, and named MCP tools that are not in this PR; `AGENTS.md` also makes MCP a baseline project instruction instead of an optional addon. The VS Code tasks are harmless on their own, but they are bundled with docs that overstate unlanded setup and MCP wiring. | Recommend Fix N — split out any useful IDE tasks; keep MCP/submodule instructions out until the addon config actually exists. | 28/06/2026 | 29/06/2026 |
| #2 | feat: implement MCP server foundation with sprint management tools | MCP | Current diff is now a Go MCP server with two aggregate tools, `ticket` and `sprint`, plus parser/command/sprint packages and tests; it no longer matches the older Python-heavy PR body. The implementation is much more focused than the original branch, but it still lands MCP as first-class repo surface by adding `cmd/mcp-server`, Go module files, `.gitignore` entries, and baseline `AGENTS.md` instructions. It also recreates ticket/sprint behavior separately from `tkt`, `sprint`, and the existing `t-xxxx` ticket convention, so the risk is semantic drift unless MCP is deliberately packaged as an addon with a narrower contract. | Recommend Fix N — keep MCP as an optional addon configuration, not default canon wiring; reopen as a smaller addon PR that either delegates to existing CLIs or proves parity with them. | 28/06/2026 | 29/06/2026 |
| #1 | MCP Path | Meta | Kitchen-sink PR combining MCP server, skills.sh refactor, submodule setup, IDE configs, and sprint polish in one diff. Correctly closed by author and split into PRs #2, #3, #4. Current open PRs have since changed materially, so this row is retained only as historical context. | N/A — closed. Findings superseded by current PRs #2-4 above. | 28/06/2026 | 29/06/2026 |

## Review Notes

- **PR #4 verification:** Desired split already exists on `main`; the PR branch still contains `cmd_addall` and `addall` usage text, so it is now a regression candidate rather than an implementation candidate.
- **PR #3 verification:** `scripts/submodule-setup.sh`, `.vscode/mcp.json`, and `opencode.json` are absent from the PR diff despite being referenced by the docs.
- **PR #2 verification:** Current PR metadata shows a Go-only server with `cmd/mcp-server`, `go.mod`, `go.sum`, internal packages, and tests. No test run was performed in this pass; review focused on architecture and diff scope.

## Pending Decisions

The skill requires explicit Fix Y/N decisions before creating tickets or posting PR comments.

Recommended decisions:

- `#4`: Fix N
- `#3`: Fix N
- `#2`: Fix N

No tickets were created and no PR comments were posted in this pass.

## What was already merged outside these PRs

- **`tools/sprint-check` port arg** (from PR #2 scope) — merged.
- **`tools/sprint-check-app/app.html` copy button** (from PR #3 scope) — merged with hover lift + clipboard error guard.
- **`tools/sprint-check-win.exe`** — rebuilt against updated `app.html`.
- **README + docs/setup.md** — Windows setup path documented.
- **`tools/skills.sh` module split without `addall`** (from PR #4 scope) — merged via `t-1c4b`.

## MCP Scope

The confirmed Windows workflow requires no WSL, no Python, and no MCP for human ticket management:

1. Install Git for Windows.
2. Clone/pull from Git Bash.
3. Run `install.ps1` from PowerShell.
4. Use `sprint-check-win` from PowerShell to manage tickets through the board.
5. Use `skills.sh`, `tkt`, and `sprint` from Git Bash for agent-driven workflows.

This keeps the real MCP use case narrow: agents inside IDEs that need programmatic sprint access. MCP should be an optional addon configuration for users who want it, not part of the default canon install or baseline project instructions. Validate that use case with the smallest useful tool surface before expanding implementation.
