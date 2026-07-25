# Root-Why

A lightweight root-cause step for `type: bug` sprints. Run it during planning, before drafting
`## Approach`. This is the fast, single-defect path — distinct from the heavier multi-stage
`docs/production-incident-playbook.md` (Surface → Trace → Isolate → Resolve → Harden), which is
for production incidents, not routine bug tickets.

Job-type routing: this step is *orthogonal to risk tier* — it adds planning work, it never
changes which close gates run.

## Steps

1. **State the symptom** exactly as observed (inputs → wrong output), not the suspected cause.
2. **Reproduce** it deterministically — the smallest input that shows the defect.
3. **5 Whys.** Ask "why" down the causal chain until you reach a cause you can change, not a
   restatement of the symptom. Stop when the next "why" leaves the codebase (e.g. a third-party
   contract). Record the chain in `plan.md`.
4. **Name the root cause** — the specific line/decision, not "the math is wrong".
5. **Convert the bug report into a checkable invariant** (see below) before writing any fix.

## Bug report → independent invariant (required)

A user's bug report describes a *symptom*. Before coding, restate it as:

- **An invariant, stated independently of the code** — the property that must hold for *all*
  inputs, in exact terms (name the field/unit; work in integers/cents where money is involved).
- **≥1 hand-computed worked example** — inputs → expected output, computed by hand, **not**
  derived by running the code or re-implementing its formula. Add a second example that stresses
  a different case (e.g. a different remainder) so a test cannot pass by hardcoding one answer.
- **Edge cases** the invariant must also cover (zero/one/empty, boundaries, rounding).

This is what the fresh-context evaluator grades against, and what "break the code on purpose"
tests: disabling the fix must make the test fail. A test that re-derives the code's own formula
agrees with itself and cannot fail — do not write one (see `DECISIONS.md`, `t-6098`).

**Worked example (bill-splitter):** symptom "3-way split of $11.00 shows $37.03×3 = $111.09 ≠
total". Root cause: per-person amount is rounded, then the leftover cent is dropped. Invariant:
*the per-person shares, summed in cents, equal the displayed total in cents, for any N and
remainder; `remainder` people pay `base+1`, the rest pay `base`.* Examples: $10.00 / 3 / 10% tip
→ $11.00 → {3.67, 3.67, 3.66} (remainder 2); $10.00 / 3 / 0% → $10.00 → {3.34, 3.33, 3.33}
(remainder 1). Edges: even split (remainder 0), N=1, singular/plural display grammar.

## Output

Write to `plan.md`: the 5-Whys chain, the root cause (one line), and the invariant + worked
examples. Feed the invariant into `acceptance.md ## Criteria` and a `## Test Plan` item that
asserts it independently.
