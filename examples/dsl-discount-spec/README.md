# DSL Spec Workshop — Executable Specs for Agentic Coding

## Purpose

Agentic coding tools are good at producing code that *looks* right. The open problem is proving it
*is* right — and most teams still answer that by having a person read the diff. This workshop builds
a small, real example of the alternative: a `Given/When/Then` spec, written **before** the code, that
a machine runs and answers pass/fail. You'll have an AI agent build a small but **visible** feature —
a standalone HTML "Discount Apply" app — against that spec inside a canon sprint, then deliberately
break the implementation live and watch the spec — not a person, not the agent's own say-so — catch it.

Teaching question this answers: **when an agent tells you its work is done, what actually checked
that, and could it be wrong?**

## The app you'll build

A single-page **Discount Apply** app — one HTML file plus one JavaScript file, no framework, no build,
no server. Open `app/index.html` in a browser and it renders four controls:

- **Amount** — the cart total (a number input)
- **Code** — the discount code to try (a text input)
- **Message** — why the code was applied or rejected
- **Discounted Amount** — the final total after the rule runs

An **Apply** button runs the rule and fills in Message + Discounted Amount:

| Applied | Rejected |
|---|---|
| ![Discount Apply app: Amount 120.00, Code SAVE20, Message "SAVE20 applied — you saved $24.00." in green, Discounted Amount $96.00](images/app-applied.png) | ![Discount Apply app: Amount 40.00, Code SAVE10, Message "minimum not met" in amber, Discounted Amount $40.00](images/app-rejected.png) |

All the logic lives in one function in `app/app.js`:

```js
apply_discount(cartTotal, code) -> { applied, final_total, reason }
```

The HTML just wires the two inputs to that function and prints the two outputs. The same function is
what the spec runs against — so the thing you *see* in the browser and the thing the spec *checks* are
the same code, not two copies that can drift.

### The rules

- `"SAVE10"` — 10% off, only if `cart_total >= 50`
- `"SAVE20"` — 20% off, only if `cart_total >= 100`
- any other code — not applied, `reason: "invalid code"`
- a valid code below its minimum — not applied, `reason: "minimum not met"`

Deliberately small. The point of this workshop is the spec/verification loop, not the business logic.

## Two runners, one spec (JavaScript or Python)

The spec — `specs/discount.feature` — is plain, language-agnostic `Given/When/Then`. This example ships
**two** tiny fixed-pattern runners that execute that same spec, so you can run the workshop in whichever
language you prefer:

| You build | Runner | Command | Files |
|---|---|---|---|
| **`app/app.js`** (the HTML app above) | `app/dsl_runner.js` (Node) | `node dsl_runner.js ../specs/discount.feature` | `app/index.html`, `app/app.js`, `app/dsl_runner.js` |
| **`discount.py`** (headless function) | `dsl_runner.py` (Python) | `python dsl_runner.py specs/discount.feature` | `dsl_runner.py` |

Both grade the identical three scenarios and print the identical `[PASS]`/`[FAIL]` lines and exit code.
The rest of this README uses the **JavaScript / HTML app** as the main path (it's the one you can see);
the Python path is the original and is what canon's own docs reference — pick either.

> In this repo the app lives in `app/`, so the runner reads the shared spec one level up:
> `node dsl_runner.js ../specs/discount.feature`. When you copy the files flat into your own project
> (below), `app.js`, `dsl_runner.js`, and `specs/` are siblings, so it's `node dsl_runner.js specs/discount.feature`.

## Before you start

1. Install canon's sprint skill if you haven't: `~/.canon/tools/skills.sh add sprint` (see
   [`docs/setup.md`](../../docs/setup.md) for the full install guide).
2. Start the board so you can watch ticket state as you go: `sprint-check` (or `sprint-check-win` on
   Windows), then open the URL it prints (defaults to `http://127.0.0.1:8423`, auto-increments if busy).
3. Have your agent (Claude Code, Codex, or another canon-compatible agent) open in a terminal at the
   project folder you create in step 1 below.

**Git terms used below**, if you're new to them: `main` is the default branch; a `commit` is a saved
snapshot; `HEAD` is "the commit you're currently on."

## Beginner-friendly workflow

1. **Open a ticket first — plan before you build.** This is the whole point of canon: the check gets
   written *before* the code. Either ask your agent to run `sprint start "build the Discount Apply app"`,
   or create a **New Ticket** on the board (`sprint-check` → **+ New**) and have the agent adopt it with
   `sprint start <id>`. Both create the ticket and seed the planning docs the close gate later requires.

2. **Create a project folder** somewhere outside this `canon` repo, e.g. `~/DiscountApplyDemo`, and
   `cd` into it. Copy this example's `.gitignore` into your new project root.

3. **Copy the spec and the runner** from this example into your new project. For the JavaScript / HTML
   path:
   - `specs/discount.feature` → your project's `specs/discount.feature`
   - `app/dsl_runner.js` → your project's `dsl_runner.js`

   (For the Python path instead, copy `dsl_runner.py`.) Read `specs/discount.feature` before moving on —
   it's short. This is the contract the agent is about to build against; you should be able to read every
   line and know exactly what "correct" means here, without running anything.

4. **Create an `AGENTS.md`** in your new project with the workshop guidelines for the app you're building.

   For the **HTML app** (`app.js`):

   ```markdown
   ## Workshop Guidelines

   - Build a standalone HTML "Discount Apply" app: `index.html` with an **Amount** field, a **Code**
     text field, a **Message** line, and a **Discounted Amount** line, plus an Apply action.
   - Put the logic in `app.js` as a single function
     `apply_discount(cartTotal, code)` returning `{ applied, final_total, reason }`, and wire the form
     to it. Guard the DOM code (e.g. `if (typeof document !== 'undefined')`) and export the function so
     the runner can import it in Node.
   - The exact rules are defined in `specs/discount.feature` — read it, don't guess the behavior.
   - `node dsl_runner.js specs/discount.feature` must exit 0 before this is considered done.
   - Do not modify `specs/discount.feature` or `dsl_runner.js` to make the check pass — if the spec
     seems wrong, say so and ask, don't quietly edit the test.
   - Do not start implementation or run `sprint complete` without explicit approval.
   ```

   That second-to-last line matters more than it looks — it's the guard against the exact failure
   mode this workshop is about: an agent "passing" a check by editing the check, not the code.

   <details>
   <summary><strong>Python variant</strong> — the original headless-function guidelines <sub>(click to expand)</sub></summary>

   ```markdown
   ## Workshop Guidelines

   - Implement `discount.py` with a single function `apply_discount(cart_total: float, code: str) -> dict`,
     returning `{"applied": bool, "final_total": float, "reason": str}`.
   - The exact rules are defined in `specs/discount.feature` — read it, don't guess the behavior.
   - `python dsl_runner.py specs/discount.feature` must exit 0 before this is considered done.
   - Do not modify `specs/discount.feature` or `dsl_runner.py` to make the check pass — if the spec
     seems wrong, say so and ask, don't quietly edit the test.
   - Do not start implementation or run `sprint complete` without explicit approval.
   ```

   </details>

5. **Give your agent the build prompt:**

   > Read `specs/discount.feature`. Start a sprint to build the Discount Apply app —
   > `index.html` + `app.js` with Amount / Code / Message / Discounted Amount fields, logic in
   > `apply_discount` — so that `node dsl_runner.js specs/discount.feature` exits 0. Put the spec's
   > three scenarios directly into `acceptance.md`'s criteria — don't paraphrase them into prose — and
   > make the exact runner command the `## Test Plan` line.

6. **Review the plan before approving.** Check specifically that:
   - `acceptance.md`'s criteria reference the real scenario names from the `.feature` file, not a
     vague restatement like "discount logic works correctly."
   - `## Test Plan` contains the literal command `node dsl_runner.js specs/discount.feature`, not
     "manually verify the discount logic" or similar prose.

   This is the moment the workshop is really about: an acceptance criterion that names an exact,
   runnable check is fundamentally different from one a reviewer has to interpret.

7. **Approve the plan.** Let the agent build `index.html` and `app.js`.

8. **Run the check yourself** before letting the agent call it done:

   ```bash
   node dsl_runner.js specs/discount.feature
   ```

   You should see three `[PASS]` lines and exit code 0. Open `index.html` in a browser too — enter
   `120` and `SAVE20`, click Apply, and confirm you see **$96.00**. If anything fails, that's real
   signal — don't let the agent talk you out of it by re-explaining the code; the spec's answer is the
   answer.

9. **Run `sprint complete`.** Watch what the evaluator actually does for this criterion — it should
   run the Test Plan command and grade on the exit code, not just read `app.js` and judge whether
   it looks reasonable. That's the difference this whole workshop is trying to make visible.

10. **The live moment.** Open `app.js` and comment out (or delete) the minimum-cart-total check —
    make every valid code apply regardless of cart size. Save it, then re-run:

    ```bash
    node dsl_runner.js specs/discount.feature
    ```

    You should see `[FAIL] Valid code below minimum is rejected -- applied true != expected false; ...`
    — an exact, specific mismatch, not a vague "something's wrong." Reload `index.html` and you'll
    see the app now wrongly discounts a $40 cart with `SAVE10` too. Revert your edit and re-run to
    confirm it goes back to three `[PASS]` lines.

    Nobody had to notice that regression by reading the diff. The spec did.

11. **Reflect before moving on.** The check that just caught your break was written in step 5, before
    any implementation existed — that ordering is what made it a real check instead of a description
    of whatever the code happened to do.

## Seeing — and authoring — the spec on the board

`sprint-check` renders a `Given/When/Then` block written in an acceptance criterion as a
highlighted **scenario panel**, so the spec you're grading against is readable at a glance
instead of buried in a text file. When step 5's agent puts the three scenarios into
`acceptance.md`, the ticket's **Acceptance** tab shows them like this:

![The Acceptance tab rendering the three discount scenarios as a highlighted Gherkin panel under a checkbox criterion](images/scenario-panel.png)

You (or the agent) don't have to hand-type the fences — the Acceptance editor's toolbar has two
scenario buttons:

![The Acceptance editor toolbar; the Scenario button inserts an inline Given/When/Then block and the Scenario-from-file button references a .feature file](images/editor-toolbar.png)

- **Scenario** (the lines-and-arrow button) inserts an inline ` ```gherkin ` block skeleton to fill in.
- **Scenario from file** (the document button) inserts a ` ```gherkin-file ` reference to a
  `.feature` kept under the ticket (`.tickets/<id>/features/<name>.feature`); the board fetches and
  renders that file inline. The inserted skeleton now also seeds a `runner:` line — see below.

**Naming the runner on the reference.** A ` ```gherkin-file ` block can carry an optional
`runner: <cmd>` line right beside its `.feature` path:

```gherkin-file
features/discount.feature
runner: node dsl_runner.js
```

The board renders the referenced scenarios as usual and shows the **resolved runner command** —
`<runner>` joined to the feature path — as a labeled chip directly beneath the panel:

![The board's Acceptance tab: the three discount scenarios rendered as a Gherkin panel, with a RUNNER chip beneath it reading the resolved runner command joined to the feature path](images/runner-line.png)

This keeps the command that validates the spec *with the spec*, instead of only in `## Test Plan`
prose. It is **display only** — the board never executes the runner. At `sprint complete` the fresh
evaluator reads that line, forms `<runner> features/discount.feature`, runs it, and grades on the
exit code (the same "run it, report the boolean" behavior described below). The workshop's own
checker still runs the project copy — `node dsl_runner.js specs/discount.feature` (or
`python dsl_runner.py specs/discount.feature` for the Python path).

The criterion is a real checkbox, so leaving it unchecked blocks `sprint complete` like any
other unmet criterion. The panel above keeps all three scenarios under one criterion (mirroring
`discount.feature`); if you'd rather each scenario be graded and checked off on its own, split
them into one criterion per scenario — the panel renders the same either way.

**Why this matters for step 9's grading:** because the criterion carries a real `Given/When/Then`
block and names its runner command in `## Test Plan`, canon's evaluator grades it by **running that
command and reading the exit code** — not by reading `app.js` and judging whether it looks
right. That "run it, report the boolean" behavior is canon's defined rule for scenario-backed
criteria, and it's exactly what makes the live break in step 10 impossible for the gate to miss.

## Hands-on: create the ticket on the board and grade it with the evaluator

The Beginner-friendly workflow above drives everything through `sprint start`. Here's the same idea
**board-first** — create the ticket in the UI, author the spec as a scenario in the Acceptance form,
let the agent build against it, and watch the fresh evaluator *run* your scenario and grade it. Run
it on the cheaper, faster **Haiku** model.

1. **New Ticket.** On the board (`sprint-check`), click **+ New**, title it `Discount Apply`, Type
   **Task**, Priority **P2**, then **Create →**.

   ![New Ticket modal — Discount Apply, Task, P2](images/new-ticket.png)

2. **Author the spec as an Acceptance scenario.** Open the card → **+ New doc → Acceptance**. In the
   editor, click the **Scenario** toolbar button and paste the three discount scenarios as one
   criterion, then name the runner in the Test Plan:

   ````markdown
   ## Criteria
   - [ ] **Discount rules — apply/reject by code and cart minimum**
   ```gherkin
   Scenario: Valid code above minimum applies the discount
     Given cart_total 120.00
     And code "SAVE20"
     When discount is applied
     Then applied is true
     And final_total is 96.00

   Scenario: Valid code below minimum is rejected
     Given cart_total 40.00
     And code "SAVE10"
     When discount is applied
     Then applied is false
     And reason is "minimum not met"

   Scenario: Unknown code is rejected
     Given cart_total 200.00
     And code "SAVE99"
     When discount is applied
     Then applied is false
     And reason is "invalid code"
   ```

   ## Test Plan
   - [ ] `node dsl_runner.js specs/discount.feature` exits 0
   ````

   Save — the board renders your scenario as a highlighted panel under its checkbox:

   ![Acceptance tab rendering the three discount scenarios as a highlighted Gherkin panel](images/scenario-panel.png)

3. **Let the agent plan and build against it.** Ask your agent (use the ticket id from step 1):

   > Start a sprint on ticket `<id>` (`sprint start <id>`) to build the Discount Apply app
   > (`index.html` + `app.js`, logic in `apply_discount`) against the Gherkin scenario in its
   > Acceptance. Write the plan; after I approve it, implement — keeping
   > `node dsl_runner.js specs/discount.feature` as the check. Don't edit the spec or the runner.

   `sprint start <id>` adopts the ticket you created on the board and seeds a `plan.md` (approach +
   sign-off) — which the close gate in step 4 requires; your Acceptance scenario is left as-is.
   Review and approve the plan, then let the agent implement.

4. **Grade it with the evaluator — on Haiku.** Set the gate model to Haiku (the ticket's **Plan**
   tab → **Model** dropdown → `haiku`, or add `| Gate model: haiku` to `plan.md`'s `## Sign-off`
   line), then run `sprint complete`. The fresh evaluator **runs your Test Plan command and grades on
   the exit code** — it doesn't just read `app.js`. Against a not-yet-correct implementation it
   fails, naming the exact mismatch:

   ```
   [FAIL] Valid code above minimum applies the discount -- applied false != expected true; final_total 120 != expected 96
   [FAIL] Valid code below minimum is rejected -- reason "invalid code" != expected "minimum not met"
   [PASS] Unknown code is rejected
   fail: runner exited 1 — "Valid code above minimum" and "Valid code below minimum is rejected" mismatched.
   ```

   Fix `app.js` and re-run; the same evaluator now passes:

   ```
   [PASS] Valid code above minimum applies the discount
   [PASS] Valid code below minimum is rejected
   [PASS] Unknown code is rejected
   pass: the runner exited 0 with all three scenarios reporting [PASS].
   ```

   Nobody read the diff to catch the wrong implementation — the evaluator *ran the spec* and the
   boolean did. That's the whole point, and on Haiku it's cheap enough to do on every close.

> **Why the interactive close here, not the headless gate?** canon's headless gate
> (`sprint-headless-eval`, the one CI uses) deliberately runs the evaluator with a **narrow tool
> allowlist** because it grades *untrusted* PR diffs — so it can't execute an arbitrary scenario
> runner and would mark the "runner exits 0" item *not-run*. The interactive `sprint complete`
> evaluator has the tools to run it, so scenario execution works there today. Letting the headless
> path run scenario runners safely is tracked as a separate improvement.

## The spec, annotated

```gherkin
Scenario: Valid code below minimum is rejected
  Given cart_total 40.00
  And code "SAVE10"
  When discount is applied
  Then applied is false
  And reason is "minimum not met"
```

Every line here is both **readable** (a non-engineer can confirm this rule is what they meant) and
**executable** (the runner runs it against the real function and gets a real answer). That
dual requirement is the whole pattern — a spec that's precise but unreadable is just code with extra
steps; a spec that's readable but unrun is just a comment.

## The runner, annotated

Each runner (`app/dsl_runner.js` and `dsl_runner.py`) is intentionally small (~50–70 lines) and
intentionally *not* a general Gherkin engine — it recognizes only the five step shapes this spec file
uses. That's a deliberate constraint, not a shortcut: a parser this size can be read end to end and
trusted; a general natural-language step interpreter can't, and pointing one at live-edited text (in a
workshop, or in production) is asking for silent misparses. The two runners are line-for-line twins —
same step patterns, same output, same exit-code contract — so the JavaScript and Python paths grade
identically. If you outgrow this pattern, the fix is adding more recognized step shapes, not switching
to free-text parsing.

## Test cases

| Scenario | cart_total | code | Expected `applied` | Expected result |
|---|---|---|---|---|
| Valid code, above minimum | 120.00 | `SAVE20` | `true` | `final_total: 96.00` |
| Valid code, below minimum | 40.00 | `SAVE10` | `false` | `reason: "minimum not met"` |
| Unknown code | 200.00 | `SAVE99` | `false` | `reason: "invalid code"` |

## What each case means in the business

The table above is the machine-facing contract. This companion table keeps the same cases legible to
the person who owns the pricing policy and explains what each result protects.

| Case | What to run or change | Expected result | Why it matters |
|---|---|---|---|
| Valid code above minimum | Run the saved spec with cart `120.00` and code `SAVE20`. | `[PASS]`; `applied: true`; final total `96.00`. | Confirms an approved promotion is applied at the correct threshold and amount. |
| Valid code below minimum | Run the saved spec with cart `40.00` and code `SAVE10`. | `[PASS]`; `applied: false`; reason `minimum not met`. | Prevents discounts from leaking below the commercial minimum and protects margin. |
| Unknown code | Run the saved spec with cart `200.00` and code `SAVE99`. | `[PASS]`; `applied: false`; reason `invalid code`. | Prevents an unapproved or mistyped code from changing the order total. |
| Deliberate implementation break | Remove the minimum-total check from `app.js`, then rerun the same spec. | The below-minimum scenario returns `[FAIL]` with the actual/expected mismatch. | Demonstrates that the written policy catches a regression without someone having to inspect the diff. |
| Restore the implementation | Put the minimum-total check back and rerun the spec. | Three `[PASS]` lines; exit code `0`. | Confirms the production behavior is back in agreement with the policy contract. |

## Where this pattern fits — and where it doesn't

Say this part out loud if you're running this as a group workshop; it's what keeps the exercise
honest instead of a sales pitch for DSLs:

- **Fits well:** anything with a checkable ground truth — this discount function, data validation,
  routing decisions, structured extraction, query generation. If you can write a `Then`, use one.
- **Doesn't fit:** open-ended output with no single right answer — "write a better error message,"
  "summarize this concisely." Forcing a spec there either flattens the task into a checklist that
  misses the point, or you end up building an LLM judge — which just moves "who verifies this" one
  level up, onto something that itself needs verifying.
- **The honest limit of *this* exercise specifically:** the runner proves the *code* matches the
  *spec*. It doesn't prove the spec matches what you actually meant — if the same person (or the same
  agent) writes both the implementation and the spec by watching the code run, you get a regression
  lock on today's behavior, not a correctness check against intent. The spec in this workshop was
  handed to you already written, in step 3, before any code existed — that's what makes it a real
  check. In your own work, that means: write the spec first, or have someone other than the
  implementer sign off on it, before trusting it as proof of anything.

## "Isn't this just a unit test?"

Say yes first — for this exact bug, a unit-test equivalent would catch it too:

```js
test("below minimum is rejected", () => {
  const result = apply_discount(40.0, "SAVE10");
  expect(result.applied).toBe(false);
  expect(result.reason).toBe("minimum not met");
});
```

Same detection power, same mechanism. The DSL isn't a stronger test — the difference is *who could
have written it*. The `.feature` version only requires knowing the discount rule; the unit-test
version requires knowing the rule **and** the language (`expect`, object access, how to run the
suite). Whoever owns the pricing policy can write and sign off on the scenario directly, with zero
code literacy — the unit test needs a translation step from rule to assertion syntax, done by whoever
implements it, which is exactly where intent quietly drifts.

One counter to have ready: "isn't 'write the check before the code' just TDD?" Yes — concede it.
TDD gets you the ordering. It doesn't get you the readership: a test-first unit-test file is still
unreadable to whoever actually owns the rule. That gap matters more, not less, as rules move further
from engineering — pricing policy, compliance, CFIHOS conformance — cases where the person who knows
what "correct" means was never going to write the assertion.

## Suggested demonstration sequence (for instructors)

Condensed recap of the steps above, for running this live in front of a group:

1. Show `specs/discount.feature` on screen — read it aloud, confirm the room agrees on what "correct"
   means before any code exists.
2. Prompt the agent to build the app against it (step 5 above); narrate what you're checking for in
   the plan (step 6) before approving.
3. Let the build finish, run the checker, open `index.html` and show the app applying `SAVE20` → $96.00.
4. `sprint complete` — pause on the evaluator's output specifically calling out that it ran the
   command rather than reading the code.
5. Break `app.js` live (step 10), re-run, show the exact failure message (and the app now
   wrongly discounting a $40 cart), revert, show green again. This is the moment to slow down — it's
   the entire point of the workshop in about fifteen seconds.
6. Close on the honest-limit section above — name what this does and doesn't prove before anyone in
   the room asks.

## Related material

- The real-world version of this pattern: a CFIHOS-style conformance engine for plant equipment data,
  with the same spec/runner/live-break structure, in `overtone_demo/scenarios.py` (separate repo).
- `posts/dsl-for-agentic-coding-session.md` in this repo — the talk this workshop is built from,
  including a longer treatment of the "where it doesn't fit" section above.
