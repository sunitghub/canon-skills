# Acceptance

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-0da2`

## Criteria
The checklist of behavior that must be true before the sprint can close.
<!-- Add or edit checklist items below. Keep this heading unchanged. -->

- [ ] `tkt send-issue <id> --launch` refuses before creating anything when `claude` is missing or its `--help` has no `--cloud`, and refuses without a TTY unless `--yes` is given
- [ ] With `--launch` and no `--yes`, it shows the same preview as `--dry-run`, asks `[y/N]`, and on `n` creates no issue and runs no `claude`
- [ ] On yes (or `--yes`) it creates the issue exactly as today, then runs `claude --cloud <prompt>` from the project root, where `<prompt>` is the one line send-issue already prints and is passed as one argument (never through `eval` or the shell)
- [ ] The `View: https://claude.ai/code/session_…` URL `claude --cloud` prints is shown and appended to `.tickets/<id>/github.md` as a `launched` entry with a `session: <url>` line
- [ ] If `claude --cloud` fails after the issue was created, the issue stays recorded, the exact manual command is printed, and the exit status is non-zero
- [ ] A local branch ahead of origin prints a warning naming the branch; nothing is pushed
- [ ] Without `--launch`, send-issue's output and exit codes are unchanged except one added line after the prompt: `From a terminal: claude --cloud '<prompt>'` (single-quoted, shell-safe)
- [ ] The board's "Sent" panel shows that command and a **Copy command** button beside **Copy prompt**; no board or daemon route runs `claude`
- [ ] Works under bash 3.2 (macOS): no `;;&`, `mapfile`, `${var,,}` or associative arrays

## Test Plan
The commands or checks that prove the criteria work.
<!-- Add or edit test commands below. Keep this heading unchanged. -->

- [ ] `bash tests/tkt-send-issue.sh` — protects the shipped `tkt send-issue` command; new cases with a stub `claude` on PATH: missing `--cloud`, no TTY without `--yes`, answer `n`, `--yes` success (args, cwd, `launched` trail entry), `claude` failure after the issue, ahead-of-origin warning, and the added `From a terminal:` line without `--launch`
- [ ] `bash -n tools/tkt` and `grep -nE ';;&|mapfile|\$\{[a-z_]+,,\}|declare -A' tools/tkt` prints nothing — protects macOS bash 3.2
- [ ] Playwright, one new test in `tests/sprint-check-app.spec.js` next to the existing "Copy prompt" test (line ~14997): the Sent panel shows the command and Copy command puts it on the clipboard — protects the board's Send to GitHub panel; chromium and `--browser=webkit` (board CLAUDE.md)
- [ ] `grep -rn "claude" tools/canon-go/internal/board/main.go` shows no new `exec.Command` of `claude` in this diff (`git diff origin/main -- tools/canon-go | grep -n 'exec.Command'` prints nothing) — protects the t-d42a rule that the board starts no agent

## QA
Edge cases and sign-off.
<!-- Add or edit QA items below. Keep this heading unchanged. -->

- [ ] Tested locally
