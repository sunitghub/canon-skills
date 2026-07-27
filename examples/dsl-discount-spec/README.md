# DSL Spec Workshop — Executable Specs for Agentic Coding

## Purpose

Agentic coding tools are good at producing code that *looks* right. The open problem is proving it
*is* right — and most teams still answer that by having a person read the diff. This workshop builds
a small, real example of the alternative: a `Given/When/Then` spec, written **before** the code, that
a machine runs and answers pass/fail. You'll watch an AI agent build a feature against that spec
inside a canon sprint, then deliberately break the implementation live and watch the spec — not a
person, not the agent's own say-so — catch it.

Teaching question this answers: **when an agent tells you its work is done, what actually checked
that, and could it be wrong?**

## Suggested app behavior

A single function, `apply_discount(cart_total, code) -> dict`, that decides whether a discount code
applies to a cart:

- `"SAVE10"` — 10% off, only if `cart_total >= 50`
- `"SAVE20"` — 20% off, only if `cart_total >= 100`
- any other code — not applied, `reason: "invalid code"`
- a valid code below its minimum — not applied, `reason: "minimum not met"`

Deliberately small. The point of this workshop is the spec/verification loop, not the business logic.

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

1. **Create a project folder** somewhere outside this `canon` repo, e.g. `~/DiscountSpecDemo`, and
   `cd` into it. Copy this example's `.gitignore` into your new project root.

2. **Copy the spec and the runner** from this example into your new project:
   - `specs/discount.feature` → your project's `specs/discount.feature`
   - `dsl_runner.py` → your project's `dsl_runner.py`

   Read `specs/discount.feature` before moving on — it's short. This is the contract the agent is
   about to build against; you should be able to read every line and know exactly what "correct"
   means here, without running anything.

3. **Create an `AGENTS.md`** in your new project with:

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

   That second-to-last line matters more than it looks — it's the guard against the exact failure
   mode this workshop is about: an agent "passing" a check by editing the check, not the code.

4. **Start the sprint.** Give your agent this prompt:

   > Read `specs/discount.feature`. Start a sprint to implement `discount.py` so that
   > `python dsl_runner.py specs/discount.feature` exits 0. Put the spec's three scenarios directly
   > into `acceptance.md`'s criteria — don't paraphrase them into prose — and make the exact runner
   > command the `## Test Plan` line.

5. **Review the plan before approving.** Check specifically that:
   - `acceptance.md`'s criteria reference the real scenario names from the `.feature` file, not a
     vague restatement like "discount logic works correctly."
   - `## Test Plan` contains the literal command `python dsl_runner.py specs/discount.feature`, not
     "manually verify the discount logic" or similar prose.

   This is the moment the workshop is really about: an acceptance criterion that names an exact,
   runnable check is fundamentally different from one a reviewer has to interpret.

6. **Approve the plan.** Let the agent implement `discount.py`.

7. **Run the check yourself** before letting the agent call it done:

   ```bash
   python dsl_runner.py specs/discount.feature
   ```

   You should see three `[PASS]` lines and exit code 0. If anything fails, that's real signal — don't
   let the agent talk you out of it by re-explaining the code; the spec's answer is the answer.

8. **Run `sprint complete`.** Watch what the evaluator actually does for this criterion — it should
   run the Test Plan command and grade on the exit code, not just read `discount.py` and judge whether
   it looks reasonable. That's the difference this whole workshop is trying to make visible.

9. **The live moment.** Open `discount.py` and comment out (or delete) the minimum-cart-total check —
   make every valid code apply regardless of cart size. Save it, then re-run:

   ```bash
   python dsl_runner.py specs/discount.feature
   ```

   You should see `[FAIL] Valid code below minimum is rejected -- applied True != expected False; ...`
   — an exact, specific mismatch, not a vague "something's wrong." Revert your edit and re-run to
   confirm it goes back to three `[PASS]` lines.

   Nobody had to notice that regression by reading the diff. The spec did.

10. **Reflect before moving on.** The check that just caught your break was written in step 4, before
    any implementation existed — that ordering is what made it a real check instead of a description
    of whatever the code happened to do.

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
**executable** (`dsl_runner.py` runs it against the real function and gets a real answer). That
dual requirement is the whole pattern — a spec that's precise but unreadable is just code with extra
steps; a spec that's readable but unrun is just a comment.

## The runner, annotated

`dsl_runner.py` is intentionally small (~50 lines) and intentionally *not* a general Gherkin
engine — it recognizes only the five step shapes this spec file uses. That's a deliberate
constraint, not a shortcut: a parser this size can be read end to end and trusted; a general
natural-language step interpreter can't, and pointing one at live-edited text (in a workshop, or in
production) is asking for silent misparses. If you outgrow this pattern, the fix is adding more
recognized step shapes, not switching to free-text parsing.

## Test cases

| Scenario | cart_total | code | Expected `applied` | Expected result |
|---|---|---|---|---|
| Valid code, above minimum | 120.00 | `SAVE20` | `true` | `final_total: 96.00` |
| Valid code, below minimum | 40.00 | `SAVE10` | `false` | `reason: "minimum not met"` |
| Unknown code | 200.00 | `SAVE99` | `false` | `reason: "invalid code"` |

## Where this pattern fits — and where it doesn't

Say this part out loud if you're running this as a group workshop; it's what keeps the exercise
honest instead of a sales pitch for DSLs:

- **Fits well:** anything with a checkable ground truth — this discount function, data validation,
  routing decisions, structured extraction, query generation. If you can write a `Then`, use one.
- **Doesn't fit:** open-ended output with no single right answer — "write a better error message,"
  "summarize this concisely." Forcing a spec there either flattens the task into a checklist that
  misses the point, or you end up building an LLM judge — which just moves "who verifies this" one
  level up, onto something that itself needs verifying.
- **The honest limit of *this* exercise specifically:** `dsl_runner.py` proves the *code* matches the
  *spec*. It doesn't prove the spec matches what you actually meant — if the same person (or the same
  agent) writes both the implementation and the spec by watching the code run, you get a regression
  lock on today's behavior, not a correctness check against intent. The spec in this workshop was
  handed to you already written, in step 2, before any code existed — that's what makes it a real
  check. In your own work, that means: write the spec first, or have someone other than the
  implementer sign off on it, before trusting it as proof of anything.

## "Isn't this just a unit test?"

Say yes first — for this exact bug, a `pytest` equivalent would catch it too:

```python
def test_below_minimum_rejected():
    result = apply_discount(40.00, "SAVE10")
    assert result["applied"] is False
    assert result["reason"] == "minimum not met"
```

Same detection power, same mechanism. The DSL isn't a stronger test — the difference is *who could
have written it*. The `.feature` version only requires knowing the discount rule; the `pytest`
version requires knowing the rule **and** Python (`assert`, dict indexing, how to run the suite).
Whoever owns the pricing policy can write and sign off on the scenario directly, with zero code
literacy — the unit test needs a translation step from rule to `assert` syntax, done by whoever
implements it, which is exactly where intent quietly drifts.

One counter to have ready: "isn't 'write the check before the code' just TDD?" Yes — concede it.
TDD gets you the ordering. It doesn't get you the readership: a test-first `pytest` file is still
unreadable to whoever actually owns the rule. That gap matters more, not less, as rules move further
from engineering — pricing policy, compliance, CFIHOS conformance — cases where the person who knows
what "correct" means was never going to write the `assert`.

## Suggested demonstration sequence (for instructors)

Condensed recap of the steps above, for running this live in front of a group:

1. Show `specs/discount.feature` on screen — read it aloud, confirm the room agrees on what "correct"
   means before any code exists.
2. Prompt the agent to build against it (step 4 above); narrate what you're checking for in the plan
   (step 5) before approving.
3. Let the build finish, run the checker, show green.
4. `sprint complete` — pause on the evaluator's output specifically calling out that it ran the
   command rather than reading the code.
5. Break `discount.py` live (step 9), re-run, show the exact failure message, revert, show green
   again. This is the moment to slow down — it's the entire point of the workshop in about fifteen
   seconds.
6. Close on the honest-limit section above — name what this does and doesn't prove before anyone in
   the room asks.

## Related material

- The real-world version of this pattern: a CFIHOS-style conformance engine for plant equipment data,
  with the same spec/runner/live-break structure, in `overtone_demo/scenarios.py` (separate repo).
- `posts/dsl-for-agentic-coding-session.md` in this repo — the talk this workshop is built from,
  including a longer treatment of the "where it doesn't fit" section above.
