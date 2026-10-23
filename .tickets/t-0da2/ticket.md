---
id: t-0da2
status: in_progress
created: 2026-10-23T15:25:27Z
type: feature
priority: 3
eval_override: false
eval_fail_count: 0
---
# send-issue --launch: start a Claude cloud session from the terminal and from the board

Today: Send to GitHub (board button or tkt send-issue) creates the issue, then the user opens a new cloud session by hand and pastes the printed prompt. Goal: one step. (1) tkt send-issue <id> --launch: push the branch, show the issue and confirm, create it, run 'claude --cloud "<printed prompt>"' from the checkout, parse the 'View:' URL and record it on the ticket. (2) Board: after Create issue, show the same claude --cloud one-liner with a Copy button; the board does not spawn the agent (t-d42a audits agent-starting routes). Evidence: research t-60b2 report section 6 (PR sunitghub/canon#135): claude --cloud 'text' starts unattended and prints Created cloud session / View: <url> / Resume with: claude --teleport <id>; no repo, branch or hosted-environment flag (uses cwd remote+branch and the account default environment). Open: confirm which environment a launched session lands in (set canon as default); behaviour with no TTY.
