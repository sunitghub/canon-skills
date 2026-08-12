# Mikado Refactor Workshop — Cascading Changes That Stay Green

> **Running this as a class or demo?** Jump to **[FACILITATOR.md](FACILITATOR.md)** — a 60-minute
> run sheet with a minute-by-minute agenda and a verified answer key (agent-free hands-on path +
> an optional agent-driven `sprint` demo). This README is the self-guided long form.

## Purpose

Most refactors that matter aren't one-line renames — they *cascade*. You change the thing you set
out to change, and three other things break; you fix those, and five more break. A few hours later
the project doesn't compile and your last green commit is somewhere over the horizon. That failure
mode has a name (the "quicksand of legacy code") and a cure: the
**[Mikado Method](https://understandlegacycode.com/blog/a-process-to-do-safe-changes-in-a-complex-codebase/)**
— *attempt the change, watch what breaks, **revert**, record the breakages as prerequisites, and
execute leaves-first so the tree is green after every step.*

canon ships this as a first-class **`mikado` skill**, and it plugs into a normal `sprint` as the
**refactor job type**. This workshop makes that concrete: you get a tiny app with a deliberately
*coupled* design, and you drive an AI agent through a Mikado-planned refactor inside a canon sprint —
watching it discover the dependency graph by attempting the goal, not by guessing up front.

Teaching question this answers: **when a refactor is going to cascade, how do you keep the codebase
shippable the entire way through instead of holding a giant broken change in your hands?**

## What's in this folder

```
app/
  db.py          SqliteOrders — the only storage impl; returns raw (id, amount, status) tuples
  report.py      OrderReport — imports & constructs SqliteOrders itself, reads tuples by index
  cli.py         a caller: OrderReport()  (breaks if you add a required store param)
  dashboard.py   a second caller: OrderReport()
tests/
  test_report.py behavior tests — the green tree the refactor must never break
```

The coupling is the point. `OrderReport` is welded to `SqliteOrders` two ways: it **constructs it
inline** (so no caller can swap storage, and every report silently opens a DB), and it **reads raw
tuples by index** (`row[1]`, `row[2]` — its logic depends on SQLite's column order). Two independent
callers construct `OrderReport()` with no arguments. This is a small stand-in for the widely-used
symbol / god-object / dependency-inversion refactors where Mikado actually earns its keep.

## The refactor goal (the "Mikado Goal")

> **`OrderReport` no longer imports or constructs `SqliteOrders`. It depends on an injected
> `OrderStore` interface and works with domain objects, not raw tuples.**

Behavior must not change — `total_revenue()` still returns `80.0`, the status counts stay identical.
That invariant is exactly what the test suite pins, and it's why the tests stay green through every
step while the *structure* underneath them is rebuilt.

## Before you start

**Requires Python 3.10+** (the refactor's answer key uses the `X | None` type-annotation syntax,
which raises a `TypeError` on 3.9 and earlier). On Windows, use `py` wherever this guide shows
`python3` — e.g. `py -m unittest discover -s tests`.

1. Install canon's skills if you haven't:
   ```bash
   ~/.canon/tools/skills.sh add sprint
   ~/.canon/tools/skills.sh add mikado
   ```
   (See [`docs/setup.md`](../../docs/setup.md) for the full install guide. `sprint start` will also
   remind you to add a skill it needs.)
2. Start the board so you can watch ticket state and the plan's Mikado graph as you go:
   `sprint-check` (or `sprint-check-win` on Windows), then open the URL it prints.
3. Have your agent (Claude Code, Codex, or another canon-compatible agent) open in a terminal at the
   project folder you create below.

**Git terms used below**, if you're new to them: a `commit` is a saved snapshot;
`git checkout -- <file>` throws away uncommitted edits to a file (this is the "revert" Mikado leans
on); "the tree is green" means the build/tests all pass.

## Beginner-friendly workflow

### 1. Create a disposable project

Copy this example into a folder *outside* the canon repo, so you don't add sprint state to the canon
checkout:

```bash
mkdir ~/MikadoDemo && cd ~/MikadoDemo
cp -R /path/to/canon/examples/mikado-refactor/. .
git init && git add -A && git commit -m "Starting point: coupled OrderReport"
```

That first commit matters — Mikado's "revert" step (`git checkout -- <files>`) is only safe when you
have a clean baseline to fall back to.

### 2. Confirm the green baseline

```bash
python3 -m unittest discover -s tests -v   # 3 tests, all OK
python3 -m app.cli                          # Revenue: 80.00  + status counts
```

You should see three passing tests and `Revenue: 80.00`. This is the tree you're going to keep green
the entire refactor. Read `app/report.py` — it's ~30 lines; you should be able to *see* the two
couplings named in the goal before touching anything.

### 3. Add workshop guidelines for the agent

Create an `AGENTS.md` in your new project:

```markdown
## Workshop Guidelines

- This is a REFACTOR: behavior must not change. `python3 -m unittest discover -s tests` must be
  green before AND after every step, and the CLI must still print `Revenue: 80.00`.
- Use the mikado skill to plan the change as a dependency graph you discover by ATTEMPTING the
  goal — do not design the whole graph up front from reading the code.
- On any breakage during discovery: REVERT immediately (`git checkout -- <files>`), record the
  breakage as a prerequisite node, then recurse. Never push a half-migrated change through.
- Execute leaves-first. Commit after each leaf lands green.
- Do not edit tests to make them pass — the tests assert the behavior that must be preserved.
- Do not start implementation or run `sprint complete` without explicit approval.
```

The "do not edit tests" line is the guardrail: the whole value of the green tree is that it's an
*independent* statement of behavior. An agent that edits the test to match new code has thrown away
its own safety net.

### 4. Start the refactor sprint

Give your agent this prompt:

> Start a sprint to refactor `app/report.py` so `OrderReport` no longer imports or constructs
> `SqliteOrders` — it should depend on an injected `OrderStore` interface and work with domain
> objects, not raw tuples. This is a refactor, so use the **mikado** skill: state the Mikado Goal,
> attempt it to discover prerequisites, and put the resulting Mikado graph in `plan.md`. Behavior
> must not change — `python3 -m unittest discover -s tests` stays green throughout. Don't implement
> until I approve the plan.

Because this is a **refactor job type**, `sprint start` routes through the mikado planning step (see
`skills/sprint/SKILL.md` → *Job types*). The agent should:

1. **State the Mikado Goal** as the root node.
2. **Attempt it naively** — e.g. make `OrderReport.__init__` take a required `store` and drop the
   `SqliteOrders` import.
3. **Observe the breakage** — `cli.py` and `dashboard.py` both call `OrderReport()` with no args, and
   the tuple-indexing logic has nothing clean to read from. Those breakages *are* the prerequisites.
4. **Revert** (`git checkout -- app/report.py`) — the discovery is recorded, not kept.
5. **Record prerequisite nodes** and recurse until it reaches leaves.
6. Write the graph into `plan.md` under `## Approach` (or a `## Mikado` subsection).

### 5. Review the plan before approving

This is the moment the workshop is about. Check that `plan.md` contains a real **Mikado graph** —
a goal with prerequisites nested underneath, checked off leaves-first — and not a flat "step 1, 2,
3" list that pretends the agent knew the whole path up front. A faithful graph looks like this
(yours may differ in detail — that's fine, the *shape* is what matters):

```
Goal: OrderReport depends on an injected OrderStore interface (no direct SqliteOrders import,
      no raw-tuple indexing)
- [ ] Inject the store via constructor; drop the inline SqliteOrders() construction   ← goal, done last
      - [ ] Add `store: OrderStore | None = None`, defaulting to SqliteOrders()        (leaf — keeps both callers green)
      - [ ] OrderReport reads Order objects, not row[1]/row[2]
            - [ ] Introduce an `Order` domain object (dataclass)                        (leaf)
            - [ ] Define the OrderStore interface: `all_orders() -> list[Order]`        (leaf)
            - [ ] SqliteOrders grows `all_orders()` returning Order objects             (adapter over fetch_all_rows)
- [ ] Update callers/tests to pass a store explicitly                                   (optional, after the default lands)
```

Execution is **deepest-first**: the `Order` dataclass and `OrderStore` interface (leaves), then the
`SqliteOrders` adapter, then `OrderReport` switching to objects, then the defaulted constructor
param, and the direct-dependency removal **last** — by which point it applies cleanly because every
prerequisite is already in place.

Two things to verify before approving, because they're the discipline that makes it Mikado and not
just "a plan":
- The **goal node is checked off last**, not first.
- Every leaf is a change that's **green on its own** — small enough to commit and ship.

Then approve the plan.

### 6. Watch it execute leaves-first — green after every step

As the agent works each leaf, it should run the tests and confirm green *before moving up the tree*.
The teaching payoff is that the suite passes at **every** checkpoint even though the internals are
being rewritten — because the tests assert behavior (`80.0`, the status counts), and behavior never
changes. Run it yourself after any step:

```bash
python3 -m unittest discover -s tests
python3 -m app.cli    # still Revenue: 80.00
```

### 7. The live moment — a surprise breakage mid-execution

This is the Mikado reflex worth feeling directly. Partway through, introduce an unexpected wrinkle:
before the agent adds the defaulted constructor param, ask it to make `store` **required** right now
and run the suite.

```bash
python3 -m unittest discover -s tests
```

You'll watch it go **red** — `cli.py` / `dashboard.py` (and the tests that build `OrderReport()`)
break, because a required param wasn't a leaf yet. The correct Mikado response is *not* to start
patching every call site under time pressure. It's:

1. **Revert** the surprising change immediately (`git checkout -- app/report.py`).
2. **Record** the newly-revealed breakage as a new prerequisite node in the graph.
3. **Resume** leaves-first — land the *defaulted* param first, migrate callers, and only then make it
   required.

That reflex — *revert on surprise, record, never push through* — is the entire method in fifteen
seconds. An agent that instead starts fixing call sites while the tree is red is exactly the quicksand
the method exists to prevent.

### 8. Close the sprint

Run `sprint complete`. The goal is finished only when: the direct `SqliteOrders` import is gone from
`report.py`, `OrderReport` takes an `OrderStore`, the tests are green, and `python3 -m app.cli` still
prints `Revenue: 80.00`. The evaluator grades the acceptance criteria against the actual code with a
fresh, no-history context — so "behavior unchanged" gets checked against the real output, not the
agent's say-so.

> **Scope note — mikado is planning-only.** The mikado skill decides *what order to change things
> in*; it **touches no close gate**. The sprint's risk tier and the reviewer/evaluator gates are
> exactly what they'd be for any refactor. If your agent ever offers to "skip the reviewer because
> it's just a refactor," that's out of bounds — mikado never grants that. (canon's own mikado evals
> include this as a boundary case.)

## Why the graph lives in `plan.md`

The blog does this on a literal piece of paper. canon does it in `plan.md`, which is
`sprint start`-read on every future session and after every context compaction. That's the same
"decisions outlive the context window" property the rest of canon is built on: if the agent's
context resets halfway through a cascading refactor, the Mikado graph — *which leaves are done, which
remain, what order* — is still right there in the repo, checkboxes and all. A refactor that spans
sessions doesn't lose its place.

## Where this pattern fits — and where it doesn't

Say this out loud if you're running this as a group workshop:

- **Fits well:** any refactor where you *can't fully predict what breaks until you try* — renaming
  or moving a widely-used symbol, extracting a module, inverting a dependency, splitting a
  god-object, replacing an API many callers touch. The bigger the blast radius, the more Mikado pays.
- **Doesn't fit:** a self-contained one-file change with no dependents. That's a normal edit — don't
  manufacture a dependency graph for a change that has none. (canon's mikado evals include exactly
  this edge case: a private helper rename with no external callers is a single leaf, done directly,
  no graph invented.)
- **The honest limit:** Mikado keeps you *shippable* through a cascade; it does not tell you the
  refactor is a good idea. Deciding the target design (`OrderStore` interface, dependency injection)
  is still your judgment — Mikado only makes getting there safe.

## "Isn't this just breaking work into small commits?"

Concede the overlap — yes, both give you small, green, shippable steps. The difference is *how you
find them*. "Break it into small commits" assumes you already know the safe order up front. Mikado's
premise is that in a complex codebase **you don't**, and pretending you do is how you end up in the
quicksand. You discover the order by *attempting the goal and letting the breakage tell you the
prerequisites* — the revert-and-record loop is the part that plain "small commits" advice leaves out,
and it's the part that keeps you from three hours deep in a change you can't finish or abandon.

## A second exercise (replay value)

Once a room has worked this refactor, the answer key is spent. For a fresh cascade with a *different*
shape — migrating the signature of an API that many call sites depend on, rather than inverting a
dependency — run **[`exercise-2/`](exercise-2/README.md)**. It's self-contained (its own `app/` +
`tests/` + verified answer key) and produces a leaf-per-call-site graph, so exercise 1's solution
doesn't carry over.

## The Mikado skill, for reference

- Skill definition: [`skills/mikado/SKILL.md`](../../skills/mikado/SKILL.md)
- Evals (control / boundary / edge / over-caution): [`skills/mikado/evals/evals.json`](../../skills/mikado/evals/evals.json)
- Triggers: Claude Code `/mikado <goal>`; Codex / Pi — "Plan this refactor with mikado".
- The method in one line: *attempt → observe breakage → revert → record prerequisite → recurse →
  execute leaves-first, green between every step, goal done last.*

## Related material

- The source method: Nicolas Carlo, *[Use the Mikado Method to do safe changes in a complex
  codebase](https://understandlegacycode.com/blog/a-process-to-do-safe-changes-in-a-complex-codebase/)*.
- The book that goes deeper: *[The Mikado Method](https://www.manning.com/books/the-mikado-method)*
  (Ellnestam & Brolund).
- Sibling workshops in this repo: [`examples/dsl-discount-spec`](../dsl-discount-spec) (executable
  specs) and [`examples/restaurant-bill-split`](../restaurant-bill-split) (a fresh evaluator catching
  plausible-but-wrong code).
