# Headless CI Grading

`tools/sprint-headless` lets a CI job grade an already-open PR against a ticket's approved plan, using Claude Code's headless (`claude -p`) mode — no human present, no unattended code writing.

## Prerequisites

- Claude Code CLI (`claude`) installed and authenticated on the CI runner (an `ANTHROPIC_API_KEY` secret, or whatever auth method your `claude` install uses).
- `git`, `bash`, and `awk` available on the runner — `tools/sprint-headless` shells out to all three.
- **Parsing `claude -p`'s JSON output:** on Windows, `tools/sprint-headless` uses the committed `tools/sprint-headless-json-win.exe` binary and needs nothing further. Everywhere else (macOS, Linux, CI runners), it shells out to `python3` — make sure that's on the runner's `PATH`.

## What It Does, and Doesn't Do

- **Grades, never implements.** The PR's code already exists. Headless canon runs three gates against it — `reviewer`, `evaluator`, `security-review` — and never edits or writes code itself. (A `Tier: bugfix` ticket runs only `evaluator` + `security-review` — the advisory reviewer is skipped; see the bugfix note below.)
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

`--base-ref` (or `$GITHUB_BASE_REF`) points at the PR's target branch. When omitted it defaults to `origin/main` (then `main`, else a clear error) — convenient for local runs; in CI always pass it explicitly (the workflow template does), so the diff base is never ambiguous.

Exit code 0 means all three gates passed; exit code 1 means a gate failed, or the invocation itself errored (auth, rate limit, dispatch failure — hard-fail, fail closed). The full grading summary, including each gate's individual verdict, prints to stdout.

Note the reviewer's binding-ness differs from interactive close: at an interactive `sprint complete` the `reviewer` gate is **advisory** (a `NO` verdict doesn't block close — see `complete.md`/`review.md`). Headless CI is stricter — a reviewer `NO` (like an evaluator `fail` or a HIGH security finding) makes the overall verdict FAIL and forces exit 1, because CI has no human in the loop to weigh an advisory verdict.

**`Tier: bugfix` tickets — reviewer skipped (eval-only).** When the committed `plan.md` `## Sign-off` records `Tier: bugfix` (canon's eval-only tier), headless dispatches only the **evaluator + security-review** and skips the advisory reviewer entirely — matching interactive `sprint complete`, where bugfix drops the advisory reviewer but keeps the binding evaluator. The verdict is then PASS iff the evaluator passes and security-review finds no HIGH finding. Headless reads the tier from the `Tier:` field in `## Sign-off` (not the `type:` frontmatter, which is the orthogonal job type), and it **trusts the committed tier**: because bugfix only skips the *advisory* reviewer, a wrongly-set `Tier: bugfix` costs at most a skipped advisory pass — the binding evaluator and security-review always run. (Mechanically detecting/proposing the tier from the diff is tracked separately; headless only honors what is committed.)

**Choosing the model (cost control).** By default the gates run on `claude`'s default model (why unqualified runs land on Sonnet/Opus). To run them cheaper — e.g. Haiku for a low-risk PR — set the model one of two ways:
- **Via the ticket's Plan:** add `| Gate model: <model>` to the committed `plan.md` `## Sign-off` line — the same field interactive `sprint complete` already honors. `sprint-headless` reads it and passes `--model <model>` to the dispatch; the literal `session` or an absent field means the default. Example: `Tier: normal | Risk: low-risk client-only change | Gate model: haiku`.
- **Via the environment:** set `ANTHROPIC_MODEL` in the workflow step's `env:` (e.g. `ANTHROPIC_MODEL: claude-haiku-4-5`) — `claude` honors it. An explicit `Gate model:` takes precedence when both are set.

The model applies to the dispatched reviewer/evaluator subagents (the expensive part), not just the orchestrator — verified via the run's `modelUsage`.

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

## Lightweight Spec-Driven Gate (`sprint-headless-eval`)

`tools/sprint-headless-eval` is the low-ceremony alternative to the full `sprint-headless` pipeline. It runs **only the evaluator** against criteria you write directly in a markdown file — no ticket, no plan approval, no reviewer, no security-review.

Use it when:
- You want a quick CI assertion on a narrow requirement without full sprint ceremony
- You're grading a PR against a single spec file checked into the repo
- You want the cheapest possible "does this diff satisfy this requirement?" check

### Spec File Format

Any markdown file with checklist items:

```markdown
---
ci: true
---
# calculateSplit() must reject split counts above 100

- [ ] Calling calculateSplit() with people > 100 returns a validation error
- [ ] The UI rejects people > 100 before calling calculateSplit()
- [ ] No unbounded array allocation occurs for large people values
```

Frontmatter is optional. The body must contain at least one `- [ ]` or `- [x]` checklist item — each becomes an independently graded acceptance criterion.

### Running It

```
sprint-headless-eval <ticket-id|spec-file> [--base-ref <ref>] [--model <model>]
```

Pass **a ticket id** (`t-xxxx`) to grade that ticket's `.tickets/<id>/acceptance.md` and write `eval-report.md` **into the ticket folder** — every artifact stays ticket-self-contained, and its `## QA` items are not graded (per `eval.md`, QA is the human's attestation). Or pass **any markdown spec file** with `- [ ]` criteria; its `eval-report.md` is written next to it.

`--base-ref` (or `$GITHUB_BASE_REF`) defaults to `origin/main` (then `main`, else a clear error) when omitted; an explicit `--base-ref` and `$GITHUB_BASE_REF` take precedence, in that order. Relative refs (`HEAD~1`, `main~3`, `HEAD^`) are accepted.

The evaluator grades each criterion with pass/fail/partial and `file:line` evidence, writes `eval-report.md` (in the ticket folder, or next to the spec file), and prints `HEADLESS_VERDICT: PASS` (exit 0) or `HEADLESS_VERDICT: FAIL` (exit 1).

To run the evaluator on a specific model (e.g. Haiku to save tokens), pass `--model <model>` — an alias (`haiku`/`sonnet`/`opus`) or a full model id: `sprint-headless-eval t-abcd --model haiku`. Alternatively set `ANTHROPIC_MODEL` in the environment; `claude` honors either. The model governs the dispatched evaluator subagent, not just the orchestrator.

### Differences from `sprint-headless`

| | `sprint-headless` | `sprint-headless-eval` |
|---|---|---|
| Gates run | reviewer + evaluator + security-review | evaluator only |
| Input | ticket ID + committed plan.md/acceptance.md | a **ticket id** (grades its acceptance.md) or any markdown spec file with criteria |
| Requires | `tkt ci <id> on`, plan approved, ticket committed | just the ticket/spec and a git repo |
| Output | review-notes.md + eval-report.md in `.tickets/<id>/` | eval-report.md in the ticket folder (ticket id) or next to the spec file |
| Cost | ~100k+ tokens (three subagents) | ~30-40k tokens (one subagent) |

### Example GitHub Actions Step

```yaml
- name: Spec-driven eval
  run: sprint-headless-eval specs/input-validation.md --base-ref "${{ github.event.pull_request.base.ref }}"
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

### When to Use Which

- **`sprint-headless`** — full-ceremony grading for tickets that went through planning, approval, and implementation. Three independent gates, advisory + binding + security.
- **`sprint-headless-eval`** — quick, targeted assertion. One spec file, one evaluator, one verdict. Good for: regression checks ("does this PR still satisfy requirement X?"), ad-hoc quality gates, and lightweight CI on narrow changes.
