# Facilitator Guide — 60-Minute Mikado Session

A minute-by-minute run sheet for teaching the Mikado Method with this example, plus a **verified
answer key** (every step below was run and the tests stay green at each one). Two ways to run it:

- **Path A — Hands-on (agent-free).** Students do the Mikado loop by hand: Python 3 + git only, no
  canon install, no agent. Guaranteed to fit the hour, and it makes them *feel the revert*. This is
  the recommended default for a room of students.
- **Path B — Agent demo (canon sprint).** You drive an AI agent through the same refactor inside a
  `sprint` using the `mikado` skill. Best as an instructor-led demo after Path A, to show the method
  automated. Needs canon + an agent installed (see the main [`README.md`](README.md)).

You can run A only (a full hour), or A for ~40 min + B as a 15-min demo.

---

## Pre-flight (do this BEFORE the session, not during)

Send students this the day before, or have them do it in the first 3 minutes:

```bash
# 1. Copy the example out of canon into a disposable folder
mkdir ~/MikadoDemo && cd ~/MikadoDemo
cp -R /path/to/canon/examples/mikado-refactor/. .

# 2. Sanity-check Python + git
python3 --version        # any 3.x
git --version

# 3. Establish the green baseline and the clean commit Mikado reverts to
git init && git add -A && git commit -m "start: coupled OrderReport"
python3 -m unittest discover -s tests    # -> OK, 3 tests
python3 -m app.cli                        # -> Revenue: 80.00 + status counts
```

If those two commands don't print `OK` and `Revenue: 80.00`, fix the environment before the session
starts — you do not want to debug Python paths live.

> **Only for Path B (agent demo):** also `~/.canon/tools/skills.sh add sprint` and
> `... add mikado`, and have `sprint-check` running on the board.

---

## The one-sentence goal (write it on the board)

> **`OrderReport` no longer imports or constructs `SqliteOrders`. It depends on an injected
> `OrderStore` interface and reads domain objects, not raw tuples — with behavior unchanged.**

"Behavior unchanged" = `total_revenue()` still returns `80.0` and the status counts are identical.
That's what the tests pin, and it's why they stay green while the structure is rebuilt underneath.

---

## Timed agenda (Path A — hands-on)

| Time | Segment | What happens |
|---|---|---|
| 0:00–0:05 | **Frame the quicksand** | The failure mode: change one thing, three break, fix those, five more break — hours later nothing compiles. Read the goal aloud. |
| 0:05–0:10 | **Green baseline** | Everyone runs the tests + CLI. Read `app/report.py` together (~30 lines) and name the *two* couplings: inline `SqliteOrders()` construction, and `row[1]`/`row[2]` tuple indexing. |
| 0:10–0:20 | **The naive attempt → REVERT** | Everyone makes `store` a required arg (Step 0 below), runs tests, watches them go **red**, and `git checkout --` reverts. This is the whole method in one move. |
| 0:20–0:25 | **Draw the graph** | From the breakage, derive the prerequisites. Sketch the Mikado graph together (below). |
| 0:25–0:48 | **Execute leaves-first** | Work Steps 1→6 (answer key below). Run the tests after **every** step; commit each green leaf. The point lands when they see green at every checkpoint. |
| 0:48–0:55 | **Surprise-breakage drill** | Optional: mid-way, make `store` required *again* before the default is in place, watch red, revert, resume. The reflex: revert on surprise, don't push through. |
| 0:55–1:00 | **Debrief** | Where Mikado fits / doesn't (see main README). The graph would live in `plan.md` and survive a context reset — that's the canon tie-in. |

---

## Step 0 — the naive attempt (the teachable failure)

Make the goal change directly: `store` becomes a required constructor argument and the direct import
is dropped.

```python
# app/report.py — naive: required store, no import
class OrderReport:
    def __init__(self, store):
        self.db = store
    # ... methods unchanged ...
```

Run the tests. You get (verified real output):

```
ERROR: test_total_revenue_sums_only_paid_orders
TypeError: OrderReport.__init__() missing 1 required positional argument: 'store'
...
Ran 3 tests ... FAILED (errors=2)
```

`python3 -m app.cli` breaks the same way — both call sites construct `OrderReport()` with no args.
**Those breakages are the prerequisites.** Now revert — do not start patching call sites:

```bash
git checkout -- app/report.py
python3 -m unittest discover -s tests    # green again
```

Say the line out loud: *the breakage told us the order; we recorded it and threw the attempt away.*

---

## The Mikado graph (derive this with the room)

```
Goal: OrderReport depends on an injected OrderStore interface           ← done LAST
      (no direct SqliteOrders import, no raw-tuple indexing)
- [ ] Default the store so every OrderReport() caller keeps working      (Step 5 — leaf)
      - [ ] OrderReport reads Order objects, not row[1]/row[2]           (Step 4)
            - [ ] Order domain object (dataclass)                        (Step 1 — leaf)
            - [ ] OrderStore interface: all_orders() -> list[Order]      (Step 2 — leaf)
            - [ ] SqliteOrders.all_orders() adapter                      (Step 3)
      - [ ] default_store() composition root owns SqliteOrders           (Step 5 — leaf)
```

Execution is **deepest-first**: leaves (Steps 1, 2) → adapter (3) → report switches to objects (4)
→ defaulted store + composition root (5) → the direct dependency is already gone (6, the goal).

---

## Answer key (verified — tests stay green after every step)

Hand these out only if students get stuck, or paste them live. Each step ends with
`python3 -m unittest discover -s tests` → **OK**, then `git commit`.

### Step 1 — `Order` domain object (leaf) — new file `app/models.py`

```python
from dataclasses import dataclass


@dataclass(frozen=True)
class Order:
    id: int
    amount: float
    status: str
```

### Step 2 — `OrderStore` interface (leaf) — new file `app/store.py`

```python
from typing import Protocol

from app.models import Order


class OrderStore(Protocol):
    def all_orders(self) -> list[Order]:
        ...
```

### Step 3 — adapter on `SqliteOrders` — add to `app/db.py`

Add `from app.models import Order` at the top, keep `fetch_all_rows`, and add:

```python
    def all_orders(self):
        """Adapter: expose rows as domain Order objects (implements OrderStore)."""
        return [Order(id=r[0], amount=r[1], status=r[2]) for r in self.fetch_all_rows()]
```

### Step 4 — report reads objects, still constructs inline — `app/report.py`

```python
from app.db import SqliteOrders


class OrderReport:
    def __init__(self):
        self.store = SqliteOrders()

    def total_revenue(self):
        return sum(o.amount for o in self.store.all_orders() if o.status == "paid")

    def count_by_status(self):
        counts = {}
        for o in self.store.all_orders():
            counts[o.status] = counts.get(o.status, 0) + 1
        return counts
```

### Step 5 — composition root (leaf) — new file `app/defaults.py`

```python
from app.db import SqliteOrders
from app.store import OrderStore


def default_store() -> OrderStore:
    return SqliteOrders()
```

### Step 6 — the goal: inject the store, drop the direct dependency — `app/report.py`

```python
from app.defaults import default_store
from app.store import OrderStore


class OrderReport:
    def __init__(self, store: OrderStore | None = None):
        self.store = store or default_store()

    def total_revenue(self):
        return sum(o.amount for o in self.store.all_orders() if o.status == "paid")

    def count_by_status(self):
        counts = {}
        for o in self.store.all_orders():
            counts[o.status] = counts.get(o.status, 0) + 1
        return counts
```

**Goal met, verified:** `report.py` no longer imports or constructs `SqliteOrders`; the
`default_store()` composition root owns that choice, so both callers *and the tests* keep working
with **zero edits** and the tree is green:

```bash
python3 -m unittest discover -s tests   # OK, 3 tests
python3 -m app.cli                       # Revenue: 80.00
grep -nE "import.*SqliteOrders|SqliteOrders\(" app/report.py   # (no matches)
```

The key thing to point out: the defaulted param + composition root is what let the goal land
**without touching a single caller or test**. That's the leaf that made the cascade disappear.

---

## Path B — the agent demo (canon sprint), ~15 min

After the hands-on, show it automated. Reset to the starting commit first:

```bash
git stash -u 2>/dev/null; git checkout .   # back to the coupled starting point
```

1. Add the `AGENTS.md` from the main [`README.md`](README.md) step 3 (the "revert on breakage,
   don't edit tests" guardrails).
2. Give the agent the sprint prompt from README step 4. Because this is a **refactor job type**,
   `sprint start` routes through the `mikado` planning step.
3. **Pause on the plan** — show the room that `plan.md` contains a real Mikado *graph* (goal checked
   off last, leaves underneath), not a flat 1-2-3 list. This is the moment worth slowing down on.
4. Approve, let it execute leaves-first, then `sprint complete` — the fresh evaluator grades
   "behavior unchanged" against the actual output, not the agent's say-so.

Talking point: the agent discovered the same graph you drew by hand — and in a real project that
graph persists in `plan.md`, so a context reset mid-refactor doesn't lose which leaves are done.

> **Boundary to state explicitly:** the `mikado` skill is planning-only — it decides change order,
> it never skips a close gate. If the agent offers to "skip the reviewer because it's just a
> refactor," that's out of bounds.

---

## Facilitator cheat-sheet

- **Green baseline:** `Revenue: 80.00`, 3 tests OK.
- **Naive-attempt error:** `TypeError: OrderReport.__init__() missing 1 required positional argument: 'store'`.
- **Revert command:** `git checkout -- app/report.py`.
- **Leaves-first order:** models → store → db adapter → report(objects) → defaults+report(inject).
- **Done check:** `grep -nE "import.*SqliteOrders|SqliteOrders\(" app/report.py` returns nothing.
- **The one-liner to repeat:** *attempt → break → revert → record → leaves-first, green between every step, goal last.*

## Common student stumbles

| Symptom | Cause | Fix |
|---|---|---|
| `ModuleNotFoundError: No module named 'app'` | Running from inside `app/` or `tests/` | Run all commands from the project root. |
| Tests still red after a step | Skipped a leaf (e.g. `all_orders()` not added before report uses it) | Follow leaves-first order; test after every step. |
| "Should I just fix the callers?" during Step 0 | The instinct Mikado exists to resist | No — revert, record the prerequisite, come back to it as a leaf. |
| Wants to edit the test to pass | Misreads the refactor as behavior change | Tests assert *preserved* behavior; if they'd need editing, the change broke behavior — revert. |
