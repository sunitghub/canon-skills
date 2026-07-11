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
3. Start a sprint with this prompt:

   `Create a Restaurant Bill Splitter app that runs in a browser.`

4. Let the agent generate its initial acceptance criteria. Then edit the ticket
   yourself: open the ticket, select **Acceptance**, choose **Edit**, add a new
   checkbox under **Criteria**, and save it. Use this exact criterion:

   `Displayed shares must be rounded to cents and sum exactly to the displayed total, including for uneven splits.`

   This demonstrates that a human can append one precise requirement without
   spending another model turn. Leave the other generated criteria in place;
   the acceptance document becomes the durable evidence that the evaluator
   must check later.
5. Leave the other generated criteria and the generated **Test Plan** in place.
   Review them, then approve the plan.
6. Ask the agent to implement the app, then manually test the sample bills.
7. Run `sprint complete` so the fresh reviewer and evaluator inspect the work.

## Separate the probabilistic and deterministic paths

The language model may interpret the user’s request, collect missing inputs,
and explain the result. It should not calculate the bill in free-form text.

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
| $0.00 | 15% | 2 | $0.00 | Two shares of $0.00 |
| $12.34 | 15% | 2 | Policy-defined | Shares sum to the displayed total |

## Suggested demonstration sequence

1. Ask the coding agent to build the app from the behavior and criteria above.
2. Run the app and perform the manual checks.
3. Run the sprint completion workflow and inspect the fresh evaluator report.
4. Confirm that the evaluator checks the rounding criterion with concrete
   file/line evidence. A naïve implementation that rounds every share to the
   same amount may fail because the displayed shares do not add up to the total.

## Example evaluator finding

The evaluator may report that the rounding criterion fails because the
implementation rounds each share independently. For an `$11.50` total split
among 3 people, displaying `$3.83` for everyone produces `$11.49` in total.
The evaluator should cite the calculation code and explain that the leftover
cent was not reconciled. This is an example finding, not a guaranteed result;
the evaluator grades the implementation it actually finds.

## Important limitation

A fresh evaluator is not automatically a mathematically reliable oracle. Vague
criteria such as “calculate the bill correctly” are insufficient. Concrete
input/output examples, invariants, and a rounding policy make numerical grading
auditable. For production financial behavior, executable tests and a trusted
calculation implementation should remain authoritative; the evaluator is an
additional independent review layer.
