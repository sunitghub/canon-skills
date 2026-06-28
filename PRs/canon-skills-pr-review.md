# canon-skills PR Review
_sunitghub/canon-skills — reviewed 2026-06-28_

| PR | Title | Area | Findings | Verdict | Opened |
|----|-------|------|----------|---------|--------|
| #4 | refactor(skills): extract sub-modules from monolithic skills.sh | Tooling | Billed as a refactor but introduces new features alongside the module split. The split itself (`lib.sh`, `agents.sh`, `display.sh`, `project.sh`, `commands.sh`) is structurally clean — guard pattern prevents re-sourcing, `BASH_SOURCE[0]` paths are correct. However: (1) `inject: true` flag is already implemented in canon's `skills.sh` (lines 364–373) and used by `standards/efficiency.md` — not new; (2) `hidden: true` flag blocks direct skill registration and is coupled to PR #3 marking `sprint/SKILL.md` as hidden — purpose unclear since sprint is a top-level user-facing skill; (3) `addall` bulk-registers every skill — against canon's deliberate, scoped registration model; (4) `cmd_status` hook display checks for `auto-handoff.sh`, `handoff-inject.sh`, `sprint-inject.sh`, `pre-commit-check.sh`, `subagent-log.sh` — all five exist in canon's `scripts/` directory and confirmed [ok] on a real Windows machine (PowerShell + Git Bash). PRs #3 and #4 are coupled: `hidden: true` in #4 only makes sense alongside the sprint SKILL.md change in #3. No tests. | Partially worth merging. Module split + hook status display are proven working including on Windows. Drop `addall`. Clarify purpose of `hidden: true` on sprint SKILL.md before merging #3. `inject: true` needs no work — already shipped in canon. | 2026-06-28T13:41:20Z |
| #3 | feat: add submodule setup, IDE config, and sprint workflow polish | DX / Setup / Sprint | Nine distinct changes bundled. **Good:** `app.html` copy-ticket-ID button is clean and self-contained; `README.md` submodule docs are useful; absolute path in `AGENTS.md` AI-SKILLS table fixed to relative. **Bad:** `.tickets/t-7f1d/` stale files deleted — local working state that should never be committed to canon-skills. `.claude/settings.json` adds MCP server config + three new hooks (`auto-handoff.sh`, `handoff-inject.sh`, `sprint-inject.sh`, `pre-commit-check.sh`) — scripts exist in canon's `scripts/` directory, but wiring them into canon-skills' own `.claude/settings.json` affects all users of the repo, not just the project using canon as a submodule. `skills/sprint/SKILL.md` and `complete.md` changes add MCP delegation notes that are premature pending PR #2. `submodule-setup.sh` (275 lines) is a significant standalone feature bundled into a polish PR. | No as-is. Split: (1) merge `app.html` copy button alone; (2) `submodule-setup.sh` as its own scoped PR; (3) hold MCP-dependent changes until PR #2 decision; (4) drop `.tickets/` deletions entirely. | 2026-06-28T13:41:07Z |
| #2 | feat: implement MCP server foundation with sprint management tools | Cross-IDE / Accessibility | Python FastMCP server exposing 13+ sprint management tools. Motivation is legitimate: accessibility for small/local models and non-Claude-Code IDEs (opencode, VS Code). But the implementation conflicts with canon's existing Go direction (`tools/sprint-check-go` exists specifically to drop Python). Duplicates bash script logic with no delegation. Ticket ID format likely wrong (`TICKET-NNNN` vs canon's `t-<letters><digits>` — digit-leading IDs silently ignored by `tkt`). Plans files (`plans/`) committed as deliverables. No tests. 13 tools vs the 7 actually needed for the stated use case. The sprint-check port arg change (8 lines) is the only clean piece. | No as-is. Merge port arg only (`tools/sprint-check`). If MCP access is pursued, correct path is a Node.js layer on existing `sprint-check-app` (already Node, cross-platform, no new language) exposing 7 tools: `get_sprint_board`, `list_skills`, `get_ticket`, `create_sprint_ticket`, `update_ticket_status`, `add_acceptance_criterion`, `open_dashboard`. Validate with MLX local model before building. | 2026-06-28T13:40:50Z |
| #1 | MCP Path | Meta | Kitchen-sink PR combining MCP server, skills.sh refactor, submodule setup, IDE configs, and sprint polish in one diff. Correctly closed by author and split into PRs #2, #3, #4. Notable: included the skills.sh refactor that became PR #4, and the same stale `.tickets/` deletions now in PR #3. | N/A — closed. Findings absorbed into PRs #2–4 above. | 2026-06-28T13:13:28Z |

## What was merged (2026-06-28)

- **`tools/sprint-check` port arg** (from PR #2) — merged. ✓
- **`tools/sprint-check-app/app.html` copy button** (from PR #3) — merged with hover lift + clipboard error guard. ✓
- **`tools/sprint-check-win.exe`** — rebuilt against updated `app.html`. ✓
- **README + docs/setup.md** — Windows setup path documented. ✓

Everything else needs scoping, splitting, or a direction decision on MCP.

## Windows users and the MCP scope

The confirmed Windows workflow requires no WSL, no Python, no extra runtimes:

1. Install [Git for Windows](https://git-scm.com/download/win)
2. `git clone` from Git Bash — clone/pull stays in Git Bash
3. Run `install.ps1` from PowerShell — adds `tools/` to user PATH
4. `sprint-check-win` from any PowerShell prompt opens the board; create and manage tickets via the UI
5. `skills.sh`, `tkt`, `sprint` run from Git Bash for agent-driven workflows

`sprint-check-win.exe` is a pre-built Go binary — it reads `app.html` at runtime from the repo, so `git pull` in Git Bash is all that's needed to pick up board updates. **No Python, no Node, no WSL.**

This narrows the real MCP use case to one specific scenario: **an agent running inside an IDE (opencode, VS Code + Copilot, Cursor) that needs programmatic access to sprint state**. A human Windows user managing their own tickets doesn't need MCP at all.

## Go server — no Python dependency on Windows

`tools/sprint-check-go/main.go` compiles to `sprint-check-win.exe` and reads `app.html` from the filesystem at runtime (`os.ReadFile`). This means:
- No Python required on Windows — the Go binary replaces `python3 server.py` entirely
- Board updates land via `git pull`; no rebuild needed for UI-only changes
- The binary is cross-compiled: `GOOS=windows GOARCH=amd64 go build -o tools/sprint-check-win.exe tools/sprint-check-go/main.go`
- Open ticket `t-c5d4`: add this rebuild step to `scripts/build-zip.sh` so the post-commit hook keeps the exe in sync automatically

## Open question

If MCP support moves forward, validate the minimal 7-tool surface with an MLX local model via `mlx_lm.server` + opencode before building. The core hypothesis — that `get_sprint_board` + basic write tools are sufficient for a small model to manage tickets without understanding the file system — should be tested before investing in implementation.
