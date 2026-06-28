# canon-skills PR Review
_sunitghub/canon-skills — reviewed 2026-06-28_

| PR | Title | Area | Findings | Verdict | Opened |
|----|-------|------|----------|---------|--------|
| #4 | refactor(skills): extract sub-modules from monolithic skills.sh | Tooling | Current diff is a scoped `tools/skills.sh` split into `tools/skills/{lib,project,agents,display,commands}.sh`. I compared it against `public/main` and smoke-tested `bash -n`, `skills.sh list`, `add`, `refresh`, `remove`, `help`, and `status` in a detached worktree; sampled behavior held. `hidden: true` and `inject: true` are not new to this PR's current diff. `addall` is also carried forward from `public/main`, but product direction is now explicitly against `addall`, so the refactor branch should remove the command instead of preserving it in the split. | Recommend Fix Y with required edit — merge the module split only after dropping `addall` from usage, dispatch, and `commands.sh`; no ticket created until user confirms Y. | 06/28/2026 08:41 AM |
| #3 | feat: add submodule setup, IDE config, and sprint workflow polish | DX / Docs | Current diff is only `.vscode/tasks.json`, `AGENTS.md`, and `README.md`; the earlier setup script, hook settings, app copy button, sprint skill edits, and stale ticket deletions are no longer present. The docs now reference `scripts/submodule-setup.sh`, `cmd/mcp-server`, `.vscode/mcp.json`, `opencode.json`, and named MCP tools, but none of those files exist in this PR. `AGENTS.md` also tells agents to prefer MCP tools that are not available on this branch and do not match PR #2's current aggregate `ticket`/`sprint` tool surface. | Recommend Fix N — docs/tasks overstate unavailable MCP and submodule setup; land only after the referenced setup/MCP files exist or trim the claims to current functionality. | 06/28/2026 08:41 AM |
| #2 | feat: implement MCP server foundation with sprint management tools | MCP | Current diff is a Go MCP server with aggregate `ticket` and `sprint` tools, plus parser/command/sprint packages and tests; this is materially different from the older Python summary in the PR body. Direction is better than the earlier Python approach, but a clean `go test ./...` fails until `go mod tidy` rewrites `go.mod`, and the implementation creates `TKT-0001` style tickets instead of canon's existing `t-xxxx` IDs. It also duplicates ticket/sprint behavior instead of delegating to `tkt`/`sprint`, so it risks drifting from the CLIs and board semantics; after `go mod tidy`, tests pass in the detached worktree. | Recommend Fix N — keep the `tools/sprint-check <port>` change only; revisit MCP as an optional addon configuration, not default canon wiring, after aligning IDs, delegating to existing commands or shared code, tidying `go.mod`, and updating the declared tool surface. | 06/28/2026 08:40 AM |
| #1 | MCP Path | Meta | Kitchen-sink PR combining MCP server, skills.sh refactor, submodule setup, IDE configs, and sprint polish in one diff. Correctly closed by author and split into PRs #2, #3, #4. Current open PRs have since changed materially, so this row is retained only as historical context. | N/A — closed. Findings superseded by current PRs #2-4 above. | 06/28/2026 08:13 AM |

## Review Notes

- **PR #2 verification:** `go test ./...` failed from a clean detached worktree with `go: updates to go.mod needed`; after `go mod tidy`, it changed `go.mod` from `go 1.23.0` to `go 1.25.5`, and tests passed.
- **PR #3 verification:** `scripts/submodule-setup.sh`, `cmd/mcp-server/main.go`, `.vscode/mcp.json`, and `opencode.json` are absent from the PR worktree despite being referenced by the docs.
- **PR #4 verification:** `bash -n` passed for all split scripts; smoke checks for `list`, `add`, `refresh`, `remove`, `help`, and `status` passed in a detached worktree. `addall` was not smoke-tested because the direction is to remove it.

## Pending Decisions

The skill requires explicit Fix Y/N decisions before creating tickets or posting PR comments.

Recommended decisions:

- `#4`: Fix Y, but only after removing `addall`
- `#3`: Fix N
- `#2`: Fix N

No tickets were created and no PR comments were posted in this pass.

## What was already merged outside these PRs

- **`tools/sprint-check` port arg** (from PR #2 scope) — merged.
- **`tools/sprint-check-app/app.html` copy button** (from PR #3 scope) — merged with hover lift + clipboard error guard.
- **`tools/sprint-check-win.exe`** — rebuilt against updated `app.html`.
- **README + docs/setup.md** — Windows setup path documented.

## MCP Scope

The confirmed Windows workflow requires no WSL, no Python, and no MCP for human ticket management:

1. Install Git for Windows.
2. Clone/pull from Git Bash.
3. Run `install.ps1` from PowerShell.
4. Use `sprint-check-win` from PowerShell to manage tickets through the board.
5. Use `skills.sh`, `tkt`, and `sprint` from Git Bash for agent-driven workflows.

This keeps the real MCP use case narrow: agents inside IDEs that need programmatic sprint access. MCP should be an optional addon configuration for users who want it, not part of the default canon install or baseline project instructions. Validate that use case with the smallest useful tool surface before expanding implementation.
