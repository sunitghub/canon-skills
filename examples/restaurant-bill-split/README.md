# Restaurant Bill Splitter Workshop Example

## Purpose

Use a restaurant bill-splitting app to demonstrate why agentic workflows need
explicit acceptance criteria and a fresh evaluator. The application should use
deterministic arithmetic; the evaluator should independently check whether the
implementation satisfies the numerical contract.

The teaching question is:

> Can a fresh evaluator detect plausible-looking but numerically incorrect code?

## Suggested app behavior

The app accepts:

- A subtotal in dollars and cents
- A tip percentage, defaulting to 10%, with 15% and 20% as additional choices
- A positive whole-number split count: 1, 2, 3, and so on

It displays the tip, total bill, and amount owed by each person.

The agent-generated acceptance criteria should include that the user can choose
the number of people splitting the bill and can choose a tip percentage. The
default tip is 10%; the other available choices are 15% and 20%.

The implementation must define its currency policy. The recommended policy is
to convert input to integer cents, calculate in cents, round the per-person
share to cents, and explicitly handle any remainder so the displayed shares sum
to the total bill.

## Beginner-friendly workflow

1. Create a project folder named `RestaurantBillSplit` and open it in VS Code.
2. Initialize the Canon skills and sprint workflow as shown in the workshop.
3. Create (or open) `AGENTS.md` in the project root and add this section, exactly as written:

   ```markdown
   ## Workshop Guidelines

   - Use vanilla HTML/CSS/JavaScript with no build step or external dependencies.
   - Support equal splits using subtotal, number of people, and exactly three tip options: 10% selected by default, with 15% and 20% as alternatives.
   - Do not add itemized splitting, tax, service charges, or persistence.
   - Keep bill calculations in an isolated deterministic function.
   - Do not start implementation or run `sprint complete` without explicit user approval.
   - Verification and testing are manual-only; do not install or suggest test-automation tooling without asking first.
   ```

   This is project-local — it applies only inside this workshop folder, not to canon
   generally. Note what it deliberately does *not* say: nothing about input validation.
   That omission is intentional — asking for validation upfront would prevent the gap
   this workshop exists to demonstrate from ever appearing in Act 1.

4. Start a sprint with this prompt:

   `Create a Restaurant Bill Splitter app that runs in a browser.`

5. Let the agent generate its initial acceptance criteria and Test Plan. Review
   them, approve the plan, and allow the agent to implement the first version.
6. Open the implemented app and run the generated manual checks. The UI may
   appear to handle invalid input correctly because its parser functions guard
   the form fields. Now inspect the isolated `calculateSplit()` function: it
   assumes that callers have already provided valid values.

   Before moving on, check what the generated Test Plan actually tested. It's
   common for every case to use a subtotal and people count that divide evenly
   (for example, people = 4 with subtotals of 100, 110, 115, 120) — every one of
   those totals splits with no remainder. A fully-checked Test Plan built only
   from round, evenly-divisible inputs proves nothing about the remainder path:
   try a subtotal that doesn't divide evenly by the people count, such as $101
   split 3 ways, and check whether the displayed per-person amounts actually sum
   to the displayed total. This is the same author writing the code and picking
   its own test numbers — no incentive to reach for the input that would expose
   its own bug. That's what the fresh evaluator exists to catch independently.

   Try more than one non-evenly-divisible case, not just one, and compare the
   *display format* between them — not just the numbers. When shares differ,
   the app should show each distinct amount and how many people pay it, for
   example "1 person pays $37.04, 2 people pay $37.03" — not a single averaged
   "Per person: $X" line. It's possible for this to work for some inputs and
   silently fall back to a flat, incorrect average for others, if the grouped
   display only triggers under some condition rather than unconditionally
   whenever shares aren't identical. Testing only one case can hide that
   inconsistency; testing two or three different remainders exposes it.
7. Fix the remainder gap right now, before looking at anything else. Open
   **Acceptance**, and check the existing criteria for the per-person output —
   this is usually a wording problem, not a missing criterion. It's common for
   the generated text to say something like "per-person share (total / people)"
   — that's not vague, it's *precise*, and it precisely describes the bug: a
   single value from plain division, with no mention of "shares" (plural),
   remainder handling, or summing to the total. A fresh evaluator grading that
   criterion as written would likely call it a pass, because the code
   faithfully does compute `total / people` — the criterion itself encodes the
   wrong model of correct behavior, not an absent one.

   Leave that existing criterion as it is. Add two new checkboxes under
   **Criteria**, directly underneath it — kept separate rather than bundled
   into one, since they're independent risks: the arithmetic could be correct
   while the display still isn't, or vice versa, and a single compound
   criterion can only report "partial" on the whole thing instead of pointing
   at which half actually failed.

   `If the bill doesn't split evenly, the extra pennies must be distributed among specific people's shares instead of being dropped, so all the shares added together equal the total exactly.`

   `When shares differ from each other, the app must display each distinct amount along with how many people pay it (for example "1 person pays $X, 2 people pay $Y") instead of a single averaged per-person number.`

   Then add matching cases to the **Test Plan**, one per criterion:

   `$101.00 subtotal, 3 people, 10% tip — check that the underlying shares are $37.04, $37.03, $37.03 and add up to exactly $111.10, not $111.09.`

   `$101.00 subtotal, 3 people, 10% tip, and at least one other non-evenly-divisible case — check that the app displays a grouped breakdown ("1 person pays $X, 2 people pay $Y") in both cases, not a single averaged per-person number in either.`

   New, specific criteria are enough on their own — the evaluator grades each
   independently, so the old loose wording sitting alongside them doesn't block
   either from correctly failing on the real bug. (If you'd rather clean up the
   old wording too instead of leaving it, that's a valid alternative — replace
   "(total / people)" with language that explicitly rules out a single flat
   value — but it's not necessary for the new criteria to work.)
8. Add the other discovered requirement to the ticket: open **Acceptance**,
   choose **Edit**, add a new checkbox under **Criteria** for each, and save:

   `Calling calculateSplit() directly with an invalid subtotal or invalid people count must return a validation result and never produce NaN, Infinity, or a misleading calculation.`

   `The app and calculateSplit() must reject split counts above a defined maximum, such as 100, and must never allocate an unbounded number of shares.`

   This is subtle: normal UI testing may miss it because the UI validates first,
   while the fresh evaluator can inspect whether the deterministic function
   protects its own contract. The maximum also protects against excessive
   memory allocation or a browser freeze from a maliciously large people count.

   Check the UI parser too, not just the function: it likely enforces "positive"
   but not "at most the maximum." A fix that only guards `calculateSplit()` still
   leaves the UI's own front door unlocked — the second criterion says "the app
   *and* `calculateSplit()`" for exactly this reason. Both layers need the same
   cap; catching only one is a common, plausible-looking half-fix.
9. Ask the agent:

   `Update the plan and Test Plan with the requirements I just added — the new remainder-distribution criterion and its test case, and the validation and resource-limit criteria. Do not implement yet; wait for my approval.`

10. Review the updated plan, then reply:

    `Approve the updated plan. Do not implement yet.`

11. Run `sprint complete` before fixing the new requirements. The security
    reviewer should flag the unbounded share-allocation risk, and the fresh
    evaluator should fail the related criteria with code evidence.
12. Ask the agent to implement the approved validation and maximum-count
    changes, then manually rerun the original bill-splitting checks. Test the
    safe boundary, such as 100 people and then 101 people; do not enter an
    enormous value that could freeze the browser.
13. Run `sprint complete` again and confirm that the evaluator now passes.

## Separate the probabilistic and deterministic paths

The language model may interpret the user’s request, collect missing inputs,
and explain the result. It should not calculate the bill in free-form text.

This is what's commonly called **tool use** or **function calling**: the
model orchestrates and explains, but a deterministic function computes. The
alternative — the model generating the numeric answer itself as part of its
own text — is **probabilistic**: sampled token-by-token, capable of producing
a wrong number that reads as confident and correct, and not guaranteed to
repeat identically on the same inputs.

Put the arithmetic in ordinary application code or behind a calculator/tool
boundary. A suitable interface is:

```text
calculate_bill(subtotal_cents, tip_percent, split_count)
```

The function or tool should return structured data, for example:

```json
{
  "subtotal_cents": 10000,
  "tip_cents": 1500,
  "total_cents": 11500,
  "shares_cents": [5750, 5750]
}
```

The agent can then explain those returned values without changing them. The
calculation function and executable tests remain authoritative; the evaluator
is an independent review layer.

## Acceptance criteria

- A `$100.00` subtotal with a 15% tip and 2 people produces a `$115.00` total
  and `$57.50` per person.
- A `$100.00` subtotal with a 15% tip and 3 people produces a `$115.00` total.
  The app documents and consistently applies its cent-rounding/remainder policy
  for the three shares.
- A `$10.00` subtotal with a 15% tip and 3 people produces an `$11.50` total;
  the displayed shares contain two `$3.83` amounts and one `$3.84` amount, in
  a deterministic order, and sum exactly to `$11.50`.
- A split count of 1 produces one share equal to the full total.
- Split counts must be positive whole numbers; zero, negative, fractional, blank,
  and non-numeric values are rejected.
- The tip is applied exactly once to the subtotal.
- Displayed shares are currency values and sum to the displayed total under the
  documented rounding policy.
- The calculation does not rely on an LLM call to perform the arithmetic.

## Test cases for the evaluator

The acceptance test plan should include at least these cases:

| Subtotal | Tip | People | Expected total | Expected result |
|---:|---:|---:|---:|---|
| $100.00 | 15% | 1 | $115.00 | One share of $115.00 |
| $100.00 | 15% | 2 | $115.00 | Two shares of $57.50 |
| $100.00 | 15% | 3 | $115.00 | Three shares following the stated remainder policy |
| $10.00 | 15% | 3 | $11.50 | Two shares of $3.83 and one share of $3.84 |
| Direct `calculateSplit()` call with invalid input | — | — | Validation result | No `NaN`, `Infinity`, or misleading calculation |
| People count above maximum, such as 101 | — | — | Rejected | No unbounded share allocation |
| $0.00 | 15% | 2 | $0.00 | Two shares of $0.00 |
| $12.34 | 15% | 2 | Policy-defined | Shares sum to the displayed total |

## Suggested demonstration sequence

1. Ask the coding agent to build the app from the behavior and criteria above.
2. Run the app and perform the manual checks.
3. Inspect the deterministic function and add the direct-input and maximum-count criteria.
4. Ask the agent to update the plan and Test Plan, then approve the change.
5. Run the security review and evaluator before fixing the function; inspect their evidence.
6. Implement the approved validation and resource-limit changes, then rerun both gates.

## Example evaluator finding

The evaluator may report that the boundary criterion fails because
`calculateSplit()` assumes valid inputs and does not guard against invalid
values, even though the UI parser prevents those values during normal use. It
should cite the function and explain the contract gap. The security reviewer
may also flag the user-controlled loop that can allocate an unbounded shares
array. These are example findings, not guaranteed results; each reviewer grades
the implementation it actually finds.

## Session 2: headless CLI grading (local, no CI)

Session 1 ran the reviewer, evaluator, and security-review gates *interactively* —
inside a live chat, as part of `sprint complete`. This session shows that the exact
same three gates can also be replayed *non-interactively*, from a plain terminal,
against the ticket you already closed. This is the same mechanism a CI pipeline
would run against a pull request (see `docs/headless-ci.md`) — here you run it
locally, so no GitHub repository, Actions workflow, or per-student API secret is
needed. Your already-authenticated local `claude` CLI is enough.

> If you've used the sprint-check board's "Start grading" button on a `ci: true`
> card instead, this is the exact same flow — the button runs this same
> `sprint-headless` command underneath, mapped to its own 3-step display:
> steps 1-2 below are "Set base ref", step 4 (the run itself) is "Grading in
> progress", and step 5 (reading `HEADLESS_VERDICT`) is "Result ready".

Prerequisites: the ticket from Session 1 is closed, its `plan.md`/`acceptance.md`
were approved, and the evaluator passed interactively. Note that ticket's ID (for
example `t-a1b2`) — you'll need it below. Your `MealSplit` folder was `git init`'d
before Session 1 started, with no remote — headless grading works fine against a
purely local repo, but every step below is written to never assume history
beyond that `git init`, since your repo may have as few as one commit.

1. Record the current commit as your base ref — the "before" state that a
   future diff will be graded against, the same role a PR's target branch
   plays in CI:

   ```
   git rev-parse HEAD
   ```

   Copy the SHA it prints; you'll pass it as `--base-ref` in step 4.

2. Mark the ticket CI-eligible:

   ```
   tkt ci <your-ticket-id> on
   ```

   This flips `ci: true` in the ticket's frontmatter and commits the ticket's
   docs itself (`git add -f .tickets/<your-ticket-id>/` + a commit) — a CI
   checkout (or, here, a fresh headless run) has nothing to grade against
   otherwise, and `.tickets/` is gitignored by default. No separate manual
   commit step is needed.

3. Create something for headless grading to actually check — stand in for a
   teammate's PR by temporarily reintroducing a bug: comment out the
   remainder-distribution fix from Session 1 so shares no longer sum to the
   total, then commit it:

   ```
   git commit -am "chore: temporarily reintroduce remainder bug for grading demo"
   ```

4. Run headless grading against the base ref from step 1:

   ```
   sprint-headless <your-ticket-id> --base-ref <sha-from-step-1>
   ```

   This dispatches fresh reviewer, evaluator, and security-review subagents —
   the same protocols Session 1 used, reading the same `plan.md`/`acceptance.md`
   — against the diff between that base ref and your current code. No code is
   written or edited; this call only grades.

5. Read the output. The full findings from all three gates print to stdout,
   ending in exactly one line: `HEADLESS_VERDICT: PASS` or
   `HEADLESS_VERDICT: FAIL`. Exit code `0` means all three gates passed; `1`
   means a gate failed, or the invocation itself errored. Confirm the evaluator
   reports `fail:` on the remainder-sum criterion, citing the commented-out
   code as evidence, and that `HEADLESS_VERDICT: FAIL` prints with a non-zero
   exit code — the same kind of finding Session 1's evaluator would have made
   interactively.

6. Unlike an interactive close, headless mode never writes `review-notes.md` or
   `eval-report.md` to disk (`claude -p`'s non-interactive permission mode
   denies that). The full text is in your terminal's scrollback instead, and
   every subagent dispatch is still logged to `.claude/subagent-runs.jsonl` for
   audit purposes — inspect it with `tail .claude/subagent-runs.jsonl`.

7. Revert the bug and rerun the same command from step 4 against the same base
   ref:

   ```
   git revert --no-edit HEAD
   sprint-headless <your-ticket-id> --base-ref <sha-from-step-1>
   ```

   Confirm all three gates now pass and `HEADLESS_VERDICT: PASS` prints with
   exit code `0` — the same acceptance criteria, graded the same way, now
   satisfied by the real fix from Session 1.

## Session 2 (GitHub, optional)

This is what the instructor demos live, using their own API key — most students should
stick with the local CLI flow above (Session 2) rather than provision their own
credential. If you want to see the same grading run as a real GitHub Actions check on a
pull request instead of from your own terminal, this section walks through it. Nothing
here is required to complete the workshop.

1. Create a GitHub repository for your `MealSplit` project and push your code to it.

2. Add your Anthropic API key as a repository secret: **Settings → Secrets and
   variables → Actions → New repository secret**, name it `ANTHROPIC_API_KEY`. Use a
   Console API key (console.anthropic.com), not a Claude.ai or Copilot subscription
   login — headless `claude -p` in a CI runner needs a credential that drops into a
   single secret with no interactive login step, which is exactly what an API key is
   and a subscription-based login isn't.

3. Before wiring the workflow, know one real pitfall: GitHub does **not** expose repo
   secrets to workflows triggered by `pull_request` from a fork — that's a genuine
   protection, not a bug to work around. Don't switch the trigger to
   `pull_request_target` combined with checking out the fork's own code just to make
   the secret available; that combination is a well-known way to let an external PR
   exfiltrate your secret. Keep the workflow scoped to your own branches/PRs.

4. Mark your ticket CI-eligible, same as the local flow — this commits its docs
   itself, no separate manual step needed:

   ```
   tkt ci <your-ticket-id> on
   ```

   See `docs/headless-ci.md`'s "Making a Ticket CI-Eligible" section for the full
   mechanics — this workshop doesn't change any of it.

5. Add this workflow at `.github/workflows/headless-grading.yml`. It extends
   `docs/headless-ci.md`'s own "Consumer-Project CI" recipe with one step that recipe
   doesn't cover on its own: `sprint-headless` finds its gate docs (`review.md`,
   `eval.md`, `security-review.md`) by looking for a `skills/` or `.claude/skills`
   directory *inside your own MealSplit repo* — neither exists there, since (correctly)
   you never commit `.claude/`. Create it fresh, every run, pointing at the canon
   checkout instead of fighting that rule:

   ```yaml
   name: Headless canon grading

   on:
     pull_request:

   jobs:
     grade:
       runs-on: ubuntu-latest
       steps:
         - name: Checkout MealSplit
           uses: actions/checkout@v4

         - name: Checkout canon
           uses: actions/checkout@v4
           with:
             repository: sunitghub/canon-skills
             path: canon

         - name: Add canon tools to PATH
           run: echo "${{ github.workspace }}/canon/tools" >> "$GITHUB_PATH"

         - name: Make canon's skill docs discoverable from this repo
           run: |
             mkdir -p .claude
             ln -s "${{ github.workspace }}/canon/skills" .claude/skills

         - name: Headless canon grading
           if: "contains(github.event.pull_request.body, 'Closes: t-')"
           run: sprint-headless <your-ticket-id> --base-ref "${{ github.event.pull_request.base.ref }}"
           env:
             ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
   ```

   Replace `<your-ticket-id>` with your real ticket ID. The `ln -s` step is what makes
   the difference from a plain canon-repo checkout — without it, `sprint-headless`
   would hard-fail with "no sprint/wrapup skill docs found" before ever reaching
   `claude -p`, even though the binary itself resolves fine via `$GITHUB_PATH`.

6. Open a pull request against your own repo. The workflow runs the same three gates
   (reviewer, evaluator, security-review) you already saw locally, this time as a real
   GitHub check on the PR. See `docs/headless-ci.md` for exit codes, what
   `$GITHUB_STEP_SUMMARY` shows, and the waiver process for a criterion that genuinely
   can't pass headlessly.

## Important limitation

A fresh evaluator is not automatically a mathematically reliable oracle. Vague
criteria such as “calculate the bill correctly” are insufficient. Concrete
input/output examples, invariants, and a rounding policy make numerical grading
auditable. For production financial behavior, executable tests and a trusted
calculation implementation should remain authoritative; the evaluator is an
additional independent review layer.
