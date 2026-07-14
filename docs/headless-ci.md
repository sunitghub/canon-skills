# Headless CI Grading

`tools/sprint-headless` lets a CI job grade an already-open PR against a ticket's approved plan, using Claude Code's headless (`claude -p`) mode — no human present, no unattended code writing.

## Prerequisites

- Claude Code CLI (`claude`) installed and authenticated on the CI runner (an `ANTHROPIC_API_KEY` secret, or whatever auth method your `claude` install uses).
- `git`, `bash`, and `awk` available on the runner — `tools/sprint-headless` shells out to all three.
- **Parsing `claude -p`'s JSON output:** on Windows, `tools/sprint-headless` uses the committed `tools/sprint-headless-json-win.exe` binary and needs nothing further. Everywhere else (macOS, Linux, CI runners), it shells out to `python3` — make sure that's on the runner's `PATH`.

## What It Does, and Doesn't Do

- **Grades, never implements.** The PR's code already exists. Headless canon runs exactly three gates against it — `reviewer`, `evaluator`, `security-review` — and never edits or writes code itself.
- **Not the full wrapup pipeline.** `code-simplifier`/`repo-check`/`doc-audit` are quality/consistency gates, not safety-critical, and aren't run headlessly.
- **Reviewer/evaluator reports are persisted, despite the write restriction.** Claude Code's non-interactive `dontAsk` permission mode denies every dispatched agent's own Bash-redirection writes, including the orchestrator's — so the reviewer and evaluator subagents relay their full report text verbatim in their response instead of writing it themselves (the same fallback `review.md`/`eval.md` already document for a write refusal), and the orchestrator relays both reports back to `tools/sprint-headless` itself, delimited per gate. The wrapper script — an ordinary, unrestricted host process, not a `claude -p` instance — parses that relay and writes `.tickets/<id>/review-notes.md`/`eval-report.md` itself. This is fail-open: if a relay comes back malformed (missing or out-of-order delimiters), that one file is simply not written — a warning prints to stderr, but the run and its `HEADLESS_VERDICT` are unaffected. Security-review still has no dedicated report file, in headless or interactive mode — its findings only ever appear in the run's own output. Every subagent dispatch is also recorded to `.claude/subagent-runs.jsonl` via `subagent-log.sh` for audit purposes, and the full result is appended to `$GITHUB_STEP_SUMMARY` when that variable is set (GitHub Actions' own per-job summary UI).
- **Human approval is front-loaded, not skipped.** A ticket's `plan.md`/`acceptance.md` must already be authored and approved (the `- [x] Plan approved` checkbox) before it's ever eligible for headless grading — the CI run only executes gates against an already-approved scope, it never makes planning decisions itself.

## Making a Ticket CI-Eligible

1. Author `plan.md`/`acceptance.md` for the ticket as usual (by hand or via `sprint start`), and check `- [x] Plan approved`.
2. Mark it CI-eligible: `tkt ci <id> on`. This force-adds and commits the ticket's docs itself (`git add -f .tickets/<id>/` + a commit) — a CI checkout has nothing to grade against otherwise, and `.tickets/` is gitignored by default inside canon's own repo. In a consumer project without a `.tickets/` gitignore entry, the force-add is a harmless no-op (force-adding a file that isn't ignored just adds it normally). No separate manual step is needed.

Everything else about the ticket stays exactly as normal — `tkt ci <id> off` stops force-tracking further changes (existing commits aren't un-committed; whether the directory reverts to untracked-and-ignored depends entirely on whether your own project's `.gitignore` covers `.tickets/`, which canon's tooling never sets up for you).

## Running It

```
tools/sprint-headless <ticket-id> --base-ref <ref>
```

`--base-ref` (or `$GITHUB_BASE_REF`) is required — headless mode never infers a diff base the way an interactive session's `git merge-base HEAD origin/main` does. Point it at the PR's actual target branch.

Exit code 0 means all three gates passed; exit code 1 means a gate failed, or the invocation itself errored (auth, rate limit, dispatch failure — hard-fail, fail closed). The full grading summary, including each gate's individual verdict, prints to stdout.

## When a Gate Legitimately Can't Pass Headlessly

Some acceptance criteria are inherently untestable by an automated evaluator — e.g. a claim that only a real `claude -p` dispatch can verify, which would cost real API money on every CI run. If the evaluator correctly fails such a criterion, headless grading exits 1, and it should: the CLI never auto-waives anything.

To unblock a legitimate case like this, a human (never CI, never an agent) does the following, outside the CI run:

1. Confirm the failure is genuinely a known, accepted limitation, not a real defect — check the evaluator's findings.
2. Record a dated waiver directly in the ticket's `acceptance.md`, e.g. `**Waived:** live-API-only claim, user-approved waiver, 2026-07-11: cannot re-verify without real cost per run.`
3. Hand-edit `eval_override: false` to `eval_override: true` in the ticket's `ticket.md` frontmatter (`tkt create` already seeds it as `false` on every new ticket). **No `tkt` command ever sets it to `true` — it must be flipped by hand.** An agent asked to flip it must refuse.
4. Close the ticket interactively: `sprint start <id>` then `sprint complete` — not via `tools/sprint-headless`, which only grades, never closes.

`_gate_eval_report`'s check here is deliberately coarse: it confirms the flag is set and that `acceptance.md` records a dated waiver, nothing more. It does not try to verify which specific failing item the waiver covers — a mechanical per-item check was attempted and abandoned after repeatedly failing open in adversarial testing (see `DECISIONS.md`). That judgment is the human's, made at close time, not the CI run's.

## Example GitHub Actions Step

```yaml
- name: Headless canon grading
  if: "contains(github.event.pull_request.body, 'Closes: t-')" # or however you detect a CI-eligible ticket
  run: tools/sprint-headless <ticket-id> --base-ref "${{ github.event.pull_request.base.ref }}"
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

Run this only in an isolated, secret-scoped CI environment — `claude -p`'s own permission system genuinely restricts what the headless orchestrator and its subagents can do (`--permission-mode dontAsk` + a narrow `--allowedTools` — read/dispatch only, no unrestricted Bash), but an isolated runner is still recommended defense-in-depth, since the agent is processing PR content that could, in principle, be adversarial.

## Consumer-Project CI

The example above only works when the CI checkout **is** canon's own repo — `tools/sprint-headless` exists at that relative path because canon's `tools/` directory is right there in the checkout.

If your project installed canon via `~/.canon/tools/skills.sh add sprint` (per `docs/setup.md`), your repo has no local `tools/` directory of its own — `sprint`, `tkt`, and `sprint-headless` are only reachable via `$PATH`, pointing at wherever canon was cloned. That works fine on your own machine once you've answered `skills.sh add`'s PATH prompt, but **it does not carry over to a CI runner**: `skills.sh add`'s PATH offer (`tools/skills/prompts.sh`'s `offer_tkt_path`) only prompts when it detects an interactive terminal, and silently skips writing to `PATH` otherwise — a CI runner has no TTY, so it always takes that skip path. A fresh runner starts with neither a local `tools/` checkout nor a `PATH` entry for it, regardless of what's set up on your laptop.

Provision both explicitly in the workflow: clone canon to a known path, then add its `tools/` to the runner's `PATH` before grading.

```yaml
- name: Checkout canon
  uses: actions/checkout@v4
  with:
    repository: sunitghub/canon-skills
    path: canon

- name: Add canon tools to PATH
  run: echo "${{ github.workspace }}/canon/tools" >> "$GITHUB_PATH"

- name: Headless canon grading
  if: "contains(github.event.pull_request.body, 'Closes: t-')"
  run: sprint-headless <ticket-id> --base-ref "${{ github.event.pull_request.base.ref }}"
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

`$GITHUB_PATH` is GitHub Actions' own PATH-extension mechanism — appending to it persists the addition to every later step in the same job, so `sprint-headless` resolves bare in the grading step exactly as it would on a developer's machine after `skills.sh add` finishes locally. Note the grading step invokes `sprint-headless`, not `tools/sprint-headless` — with canon's `tools/` on `PATH` rather than vendored into your own repo, the relative path from the canon-repo-only example above doesn't exist here and would fail with "No such file or directory."
