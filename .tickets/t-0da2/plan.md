# Plan

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-0da2`
<!-- Keep this doc under ~500 words — it is injected at every session start. -->

## Sign-off
Tier: normal | Risk: a new command that starts a billable cloud session; mitigated by confirmation, a fixed prompt passed as one argv element, and no board route that spawns
<!-- Optional, append: | Gate model: <value> -- forces the sprint-close reviewer/evaluator onto that model, overriding the automatic Admin Review & Eval default. Valid values (case-insensitive): a model id (e.g. haiku, sonnet, opus), or the literal "session" to force full session-model review. Omit entirely for automatic behavior -- there is no separate "auto" value; absence already means automatic. -->

- [x] Plan approved — proceed to implementation

## Approach
Evidence: research t-60b2 (PR #135): `claude --cloud "text"` starts unattended and prints `Created cloud session`, `View: <url>`, `Resume with: claude --teleport <id>`; no repo, branch or hosted-environment flag.

1. `tools/tkt` `cmd_send_issue`: add `--launch` and `--yes`. Before anything is created: check `claude` exists and `claude --help` lists `--cloud`; require a TTY unless `--yes`; with a TTY print the dry-run preview and ask `[y/N]`.
2. After the existing create-and-record steps, build the prompt (the same printf, now in a helper) and run `(cd "$root" && claude --cloud "$prompt")` capturing output; show it, parse the `View:` URL, append `launched: <url>` to `github.md` via `_gh_trail`. On failure print the manual command and exit 1; the issue stays recorded.
3. Warn (never push) when the current branch is ahead of its upstream.
4. Always print one more line after the prompt: `From a terminal: claude --cloud '<prompt>'`, single-quoted with embedded quotes escaped.
5. Board: `board-github.js` `showSent` parses that line (same pattern as the `type:` line, t-093a), shows it, adds **Copy command**. No Go change, no new route.
6. Docs: `docs/setup.md` step 3, `tools/ticket.md` and the `tkt --help` line for send-issue.

## Files
- `tools/tkt` (cmd_send_issue, help text)
- `tests/tkt-send-issue.sh`
- `tools/sprint-check-app/static/board-github.js`, `tests/sprint-check-app.spec.js`
- `docs/setup.md`, `tools/ticket.md`

## Decisions
- No push: `--launch` warns, the user pushes. canon never pushes for the user without a yes, and the cloud session clones the remote branch, so an ahead warning is enough.
- `launched:` goes in `github.md` (the existing trail), not a new ticket.md field: no schema change.
- Board shows a command to copy instead of spawning: t-d42a is auditing agent-starting routes.
- Environment: no flag exists; the session uses the account default. Carried forward: confirm the default is `canon` (maintainer, on claude.ai/code).
- Carried forward: `claude --cloud` with no TTY (CI) is untested; `--launch` requires a TTY or `--yes`.
- Not in scope: GitHub Actions route (t-60b2 report), launching an already-sent ticket.
