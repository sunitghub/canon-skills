# Headless CI Grading

`tools/sprint-headless` lets a CI job grade an already-open PR against a ticket's approved plan, using Claude Code's headless (`claude -p`) mode — no human present, no unattended code writing.

## Prerequisites

- Claude Code CLI (`claude`) installed and authenticated on the CI runner (an `ANTHROPIC_API_KEY` secret, or whatever auth method your `claude` install uses).
- `git`, `bash`, and `python3` available on the runner — `tools/sprint-headless` shells out to all three.

## What It Does, and Doesn't Do

- **Grades, never implements.** The PR's code already exists. Headless canon runs exactly three gates against it — `reviewer`, `evaluator`, `security-review` — and never edits or writes code itself.
- **Not the full wrapup pipeline.** `code-simplifier`/`repo-check`/`doc-audit` are quality/consistency gates, not safety-critical, and aren't run headlessly.
- **No per-ticket report files.** Claude Code's non-interactive `dontAsk` permission mode denies Bash-redirection writes outright, so `review-notes.md`/`eval-report.md` are never persisted to disk in headless mode. The full text of every gate's findings is captured in the CI job's own log output instead, and every subagent dispatch is recorded to `.claude/subagent-runs.jsonl` via `subagent-log.sh` for audit purposes.
- **Human approval is front-loaded, not skipped.** A ticket's `plan.md`/`acceptance.md` must already be authored and approved (the `- [x] Plan approved` checkbox) before it's ever eligible for headless grading — the CI run only executes gates against an already-approved scope, it never makes planning decisions itself.

## Making a Ticket CI-Eligible

1. Author `plan.md`/`acceptance.md` for the ticket as usual (by hand or via `sprint start`), and check `- [x] Plan approved`.
2. Mark it CI-eligible: `tkt ci <id> on`.
3. Commit the ticket's docs — they're gitignored by default like every other ticket, so a CI checkout has nothing to grade against otherwise:
   ```
   git add -f .tickets/<id>/
   git commit -m "mark <id> CI-eligible"
   ```
   `tkt ci` prints this reminder every time you enable it.

Everything else about the ticket stays exactly as normal — `tkt ci <id> off` returns it to the gitignored default (existing commits aren't un-committed, but no further changes are force-tracked).

## Running It

```
tools/sprint-headless <ticket-id> --base-ref <ref>
```

`--base-ref` (or `$GITHUB_BASE_REF`) is required — headless mode never infers a diff base the way an interactive session's `git merge-base HEAD origin/main` does. Point it at the PR's actual target branch.

Exit code 0 means all three gates passed; exit code 1 means a gate failed, or the invocation itself errored (auth, rate limit, dispatch failure — hard-fail, fail closed). The full grading summary, including each gate's individual verdict, prints to stdout.

## Example GitHub Actions Step

```yaml
- name: Headless canon grading
  if: contains(github.event.pull_request.body, 'Closes: t-') # or however you detect a CI-eligible ticket
  run: tools/sprint-headless <ticket-id> --base-ref "${{ github.event.pull_request.base.ref }}"
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

Run this only in an isolated, secret-scoped CI environment — `claude -p`'s own permission system genuinely restricts what the headless orchestrator and its subagents can do (`--permission-mode dontAsk` + a narrow `--allowedTools` — read/dispatch only, no unrestricted Bash), but an isolated runner is still recommended defense-in-depth, since the agent is processing PR content that could, in principle, be adversarial.
