# Research t-0da2

- `cmd_send_issue` (tools/tkt:1090-1199) prints `Sent <id> as <url>`, `In a Claude cloud session on <repo>, type:`, then the prompt line. It refuses a ticket already sent.
- The board shows what the CLI prints: `board-github.js` takes the line after `type:` (t-093a) and has a **Copy prompt** button (showSent, line ~534). The spec at tests/sprint-check-app.spec.js:14997 covers it.
- `tests/tkt-send-issue.sh` stubs `gh` on PATH and logs calls: the same pattern fits a stub `claude`.
- `claude --help` (v2.1.309): `--cloud [description|session_id|url]`, `--environment` is self-hosted only; no repo or branch flag. Maintainer run printed `Created cloud session`, `View: <url>`, `Resume with: claude --teleport <id>`.
- LEARNINGS 2026-10-21 (t-7f5f): cloud bash 5 passes what macOS bash 3.2 rejects; avoid `;;&` and friends.
- DECISIONS.md is empty; HANDOFF.md is empty.
