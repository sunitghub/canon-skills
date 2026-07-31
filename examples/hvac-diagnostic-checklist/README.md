# HVAC Diagnostic Checklist Workshop — Executable Specs for a Real Field Checklist

## Purpose

Field-service checklists are full of exactly the kind of claim a spec can check: a technician
records a **required** value and an **actual** value, and correctness is "does actual satisfy
required" — a breaker rated high enough, a running amp draw under the motor's max, a refrigerant
reading inside its target band. This workshop takes a real HVAC diagnostic checklist and turns
three of its recurring field pairs into `Given/When/Then` scenarios, has an agent build the rule
and a runner that grades it, then breaks the rule on purpose and watches the runner catch it.

This is the same spec → runner → live-break arc as
**[`examples/dsl-discount-spec`](../dsl-discount-spec/README.md)** — read that one first if you're
new to the pattern; this workshop assumes it and swaps the domain from retail discounts to field
diagnostics.

Teaching question this answers: **when a technician's checklist says "compliant," what actually
checked that — and could it be wrong?**

## Where this came from

The scenarios below are derived from a real field-tech HVAC diagnostic checklist — a residential
service report with two-column fields like "Breaker size required ___ amp" / "Breaker
Installed ___ amp" and "Blower Motor max RLA ___" / "Blower Run Amps ___". Only that paired
bound/actual structure is kept here; the job number, technician and client signatures, and every
other piece of identifying information from the source document are **not** reproduced.

## Three rule shapes, not one

`dsl-discount-spec` has one rule (`apply_discount`). A real diagnostic checklist has several
different *kinds* of field, so this workshop keeps three, each with its own scenario shape:

| Rule | Checklist fields it covers | Signature |
|---|---|---|
| **breaker** | "Breaker size required" vs "Breaker Installed" | `checkBreaker(requiredAmps, installedAmps)` |
| **RLA** | "max RLA" vs the corresponding "Run Amps"/"actual RLA" (blower, condenser fan, compressor) | `checkRLA(maxRLA, actualRLA)` |
| **tolerance** | "Target superheat" vs "Actual superheat", "Recommended subcooling" vs "Actual subcooling" | `checkTolerance(target, actual, tolerance)` |

Each returns `{ compliant, reason }`. The runner recognizes all three step shapes from one
`.feature` file — this is what "a small fixed-pattern runner, not a general Gherkin engine" means
in practice: three shapes it was built to recognize, not free-text natural language.

## Before you start

1. Install canon's sprint skill if you haven't: `~/.canon/tools/skills.sh add sprint` (see
   [`docs/setup.md`](../../docs/setup.md) for the full install guide).
2. Start the board so you can watch ticket state as you go: `sprint-check` (or `sprint-check-win`
   on Windows), then open the URL it prints (defaults to `http://127.0.0.1:8423`).
3. Have your agent (Claude Code, Codex, or another canon-compatible agent) open in a terminal at a
   fresh project folder outside this `canon` repo. Copy this example's `.gitignore` into it.

**Git terms used below**, if you're new to them: `main` is the default branch; a `commit` is a
saved snapshot; `HEAD` is "the commit you're currently on."

## Part 1 — Author the scenarios, and have the agent build the runner

1. **New Ticket.** On the board, click **+ New**, title it `HVAC diagnostic rules`, Type **Task**,
   Priority **P2**, then **Create →**.

2. **Author the three scenario blocks in Acceptance.** Open the card → **+ New doc → Acceptance**.
   Use the **Scenario** toolbar button for each of the three rule shapes and enter them as one
   criterion each:

   ````markdown
   ## Criteria
   - [ ] **Breaker sizing — installed amps vs required amps**
   ```gherkin
   Scenario: Installed breaker meets the required rating
     Given required_amps 60
     And installed_amps 60
     When the breaker is checked
     Then compliant is true
     And reason is "breaker meets required rating"

   Scenario: Installed breaker below the required rating fails
     Given required_amps 60
     And installed_amps 50
     When the breaker is checked
     Then compliant is false
     And reason is "breaker undersized"
   ```

   - [ ] **RLA — actual running load amps vs a component's max RLA rating**
   ```gherkin
   Scenario: Actual RLA at the max rating is compliant
     Given max_rla 19
     And actual_rla 19
     When the RLA reading is checked
     Then compliant is true
     And reason is "actual RLA within max rating"

   Scenario: Actual RLA exceeding the max rating is a fault
     Given max_rla 19
     And actual_rla 22
     When the RLA reading is checked
     Then compliant is false
     And reason is "actual RLA exceeds max rating"
   ```

   - [ ] **Tolerance — a measured value vs a target within a pinned tolerance (superheat,
     subcooling)**
   ```gherkin
   Scenario: Actual reading exactly matches target
     Given target 9
     And actual 9
     And tolerance 3
     When the reading is checked
     Then compliant is true
     And reason is "actual within tolerance of target"

   Scenario: Actual reading outside tolerance fails
     Given target 9
     And actual 15
     And tolerance 3
     When the reading is checked
     Then compliant is false
     And reason is "actual outside tolerance of target"
   ```

   ## Test Plan
   - [ ] <the agent writes the runner command here after it builds the runner>
   ````

   You author only the scenarios — not the runner, not the filenames, not the language. Save; the
   board renders each block as a highlighted Gherkin panel under its checkbox.

3. **Pin the tolerance, don't recite one.** Notice `tolerance` is a `Given` value in the scenario
   itself, not a number baked into the rule. This example does **not** assert that "±3°F is normal
   superheat tolerance" as an HVAC fact — that's exactly the kind of unpinned domain claim an
   agent must not invent (see "What this checklist leaves unpinned," below). The scenario supplies
   its own tolerance so the rule stays generic and the example makes no claim it can't back up.

4. **`sprint start <id>` and approve.** Point your agent at the ticket:

   > Start a sprint on ticket `<id>` (`sprint start <id>`) and follow the build instruction it
   > seeds into `plan.md` from the Acceptance scenarios. Ask me anything ambiguous first; after I
   > approve the plan, build it — don't edit the spec or the runner to force a pass.

   `sprint start` seeds a standard build instruction into `plan.md`: extract the scenarios
   verbatim into `specs/hvac-diagnostic.feature` (a *derived* artifact — Acceptance stays the
   source), infer the three function **signatures** only from `Given`/`Then` (never invent rule
   *values* the scenarios don't pin), implement `app/hvac_check.js`, build
   `app/dsl_runner.js`, and write the runner command into `## Test Plan`.

5. Review the plan, then approve. The agent writes `specs/hvac-diagnostic.feature`, the three rule
   functions in `app/hvac_check.js`, the runner `app/dsl_runner.js`, and fills the `## Test Plan`
   line to match.

## Part 2 — Run the check

From the `app/` directory (where `dsl_runner.js` and `hvac_check.js` live):

```bash
cd app
node dsl_runner.js ../specs/hvac-diagnostic.feature
```

Nine lines — one `Verdict: PASS` per scenario — and exit code 0:

```
Scenario: Installed breaker meets the required rating, Verdict: PASS, Reason: breaker meets required rating
Scenario: Installed breaker below the required rating fails, Verdict: PASS, Reason: breaker undersized
Scenario: Second required/installed pair from the checklist (outdoor unit), Verdict: PASS, Reason: breaker meets required rating
Scenario: Actual RLA at the max rating is compliant, Verdict: PASS, Reason: actual RLA within max rating
Scenario: Actual RLA exceeding the max rating is a fault, Verdict: PASS, Reason: actual RLA exceeds max rating
Scenario: Second max/actual RLA pair from the checklist (blower motor), Verdict: PASS, Reason: actual RLA within max rating
Scenario: Actual reading exactly matches target, Verdict: PASS, Reason: actual within tolerance of target
Scenario: Actual reading outside tolerance fails, Verdict: PASS, Reason: actual outside tolerance of target
Scenario: Second target/actual pair from the checklist (subcooling), Verdict: PASS, Reason: actual within tolerance of target
```

Try a rule on any reading you like — this just computes the result, it is *not* a pass/fail check:

```bash
$ node dsl_runner.js breaker 60 60
  required_amps:    60
  installed_amps:   60
  compliant:        true
  reason:           breaker meets required rating

$ node dsl_runner.js rla 19 22
  max_rla:          19
  actual_rla:       22
  compliant:        false
  reason:           actual RLA exceeds max rating
```

## The live moment — break a rule, watch the check catch it

1. Open `app/hvac_check.js` and comment out (or stub to always pass) the undersized-breaker check
   in `checkBreaker`. Save, then re-run the check:

   ```bash
   node dsl_runner.js ../specs/hvac-diagnostic.feature
   ```

   (still from `app/`.) The "below the required rating fails" scenario now reports `Verdict: FAIL` — the exact
   mismatch (`compliant true != expected false; reason "breaker meets required rating" !=
   expected "breaker undersized"`) — and the run exits 1. The other eight scenarios still pass;
   only the one the broken code actually affects goes red.

2. **Grade it with the evaluator.** Run `sprint complete`. The fresh evaluator — no
   implementation history — grades the scenario-backed criteria by **running the Test Plan
   command and reading the exit code**, not by reading `hvac_check.js` and judging whether it
   looks right. Against the broken rule it fails, naming the exact mismatch; fix `hvac_check.js`
   and the same evaluator passes.

3. Revert your edit and re-run to confirm nine `PASS` lines and exit 0.

## What this checklist leaves unpinned

The source checklist has more paired fields than the three rules above check, and some of them
don't reduce to a clean bound/actual comparison without a domain expert's judgment. The clearest
example: a supply-air and return-air temperature reading, where "correct" depends on a target
**split** between the two that this checklist doesn't itself state as a number.

This workshop deliberately does **not** turn that into a fourth rule. Inventing a plausible-sounding
"normal" split and shipping it as a check would be exactly the failure this whole pattern exists to
prevent — a guessed threshold that passes every scenario because nothing pins it, catchable by
neither the runner nor a fresh evaluator (see `dsl-discount-spec`'s README on why unpinned rule
values must be surfaced as a gap, not filled in). The correct move, and the one a real HVAC
technician's checklist actually depends on, is to ask the domain expert who owns the checklist for
the number and the scenario that pins it — not to reach for what sounds plausible from general
knowledge. If you want to extend this example, that's the next scenario to author: get the target
split (and its tolerance) from someone who owns the diagnostic procedure, write it as a
`Given/When/Then` the same way the three rules above were, and only then ask an agent to build it.

## Where this pattern fits — and where it doesn't

- **Fits well:** any checklist field that's already a bound/actual pair with a checkable rule —
  breaker sizing, RLA vs max rating, a reading within a stated tolerance. If the checklist already
  hands you both numbers, you can write a `Then`.
- **Doesn't fit:** a checklist field that's a visual inspection, a yes/no judgment call, or a
  reading with no stated target (see "What this checklist leaves unpinned" above). Forcing those
  into a spec means inventing the missing number yourself — don't.
- **The honest limit:** this proves the *code* matches the *spec* the three scenarios pin. It says
  nothing about whether "installed >= required" or "actual <= max" is the complete safety rule a
  real HVAC technician should apply — that's domain judgment outside what nine scenarios can
  encode, same caveat `dsl-discount-spec`'s README states for its own domain.

## Related material

- **[`examples/dsl-discount-spec`](../dsl-discount-spec/README.md)** — the same pattern, one rule
  shape, more detail on the BDD mechanics (the "one-minute version," why scenario values must be
  pinned, "isn't this just a unit test?").
- **[`examples/restaurant-bill-split`](../restaurant-bill-split/README.md)** — a fresh evaluator
  catching plausible-but-wrong code, plus the full headless-CI ceremony this workshop leaves out.
