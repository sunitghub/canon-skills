# Mikado Exercise 2 — Migrating a Widely-Used API (stays green)

A second, self-contained Mikado kata for [the mikado-refactor workshop](../README.md). Exercise 1
is a **dependency inversion** (inject an `OrderStore`). This one is a different cascade: **changing
the signature of an API that many call sites already depend on.** Run it after exercise 1 when a
room has already seen that answer key and you want a fresh discovery — the *shape* of the graph here
is different (a leaf per call site), so memorizing exercise 1 doesn't help.

**Requires Python 3.10+.** On Windows, use `py` wherever this guide shows `python3`
(e.g. `py -m unittest discover -s tests`).

## What's in this folder

```
app/
  discount.py    discount_price(price, pct) — the widely-used API; pct is a bare float
  cart.py        a caller: totals a fixed cart, passes pct floats
  checkout.py    a second caller: express_checkout(price, pct)
  receipt.py     a third caller: receipt_line(name, price, pct)
tests/
  test_pricing.py behavior tests — the green tree the refactor must never break
```

The coupling is the point: `discount_price` takes a bare `pct` **float**, and *every* caller — plus
two of the tests — passes one. The team now needs **fixed-amount** discounts ("$10 off"), which
means the second parameter has to become a `Discount` object. Change that signature in one shot and
everything breaks at once. That's what makes "take a Discount" a graph of prerequisites, not a
one-liner.

## The refactor goal (the "Mikado Goal")

> **`discount_price(price, discount)` takes a `Discount` (percentage OR fixed), not a bare `pct`
> float — with existing percentage behavior unchanged.**

Behavior must not change for the percentage path: a 10% discount on `100.00` is still `90.0`, and the
cart still totals `155.0`. That invariant is what the tests pin, and it's why they stay green while
the signature is migrated underneath them.

## Before you start

```bash
mkdir ~/MikadoDemo2 && cd ~/MikadoDemo2
cp -R /path/to/canon/examples/mikado-refactor/exercise-2/. .
git init && git add -A && git commit -m "start: pct-float discount_price"
python3 -m unittest discover -s tests    # -> OK, 5 tests
```

You should see **5 passing tests**. That's the tree you keep green the whole way.

## Step 0 — the naive attempt (the teachable failure)

Make the goal change directly — assume the second arg is already a `Discount` and call `.apply`:

```python
# app/discount.py — naive
def discount_price(price, discount):
    return discount.apply(price)
```

Run the tests (verified real output):

```
AttributeError: 'float' object has no attribute 'apply'
...
Ran 5 tests ... FAILED (errors=5)
```

**All five** go red at once — every caller (and the tests) still passes a bare float. Those breakages
are the prerequisites. Now revert — do not start patching call sites:

```bash
git checkout -- app/discount.py
python3 -m unittest discover -s tests    # green again, 5 tests
```

## The Mikado graph

```
Goal: discount_price takes a Discount (percentage OR fixed), not a bare pct float   ← done LAST
- [ ] Drop the legacy float branch — Discount-only signature                         (Step 6)
      - [ ] Migrate every call site to pass a Discount — one leaf each:
            - [ ] cart.py                                                             (Step 3 — leaf)
            - [ ] checkout.py                                                         (Step 4 — leaf)
            - [ ] receipt.py                                                          (Step 5 — leaf)
            - [ ] tests/test_pricing.py (+ add a fixed-discount case)                 (Step 5 — leaf)
      - [ ] Shim: discount_price accepts a float OR a Discount                        (Step 2 — leaf)
            - [ ] Introduce the Discount type                                         (Step 1 — leaf)
```

Execution is **deepest-first**: the `Discount` type (Step 1), then the shim that accepts both
(Step 2) so callers can move one at a time, then each call site (Steps 3–5), and only when nothing
passes a float any more do you drop the legacy branch (Step 6, the goal).

## Answer key (verified — tests stay green after every step)

Each step ends with `python3 -m unittest discover -s tests` → **OK**, then `git commit`.

### Step 1 — introduce the `Discount` type (leaf) — new file `app/discount_types.py`

```python
from dataclasses import dataclass


@dataclass(frozen=True)
class Discount:
    kind: str      # "percentage" or "fixed"
    value: float

    @classmethod
    def percentage(cls, fraction):
        return cls("percentage", fraction)

    @classmethod
    def fixed(cls, amount):
        return cls("fixed", amount)

    def apply(self, price):
        if self.kind == "percentage":
            return round(price * (1 - self.value), 2)
        return round(price - self.value, 2)
```

Nothing imports it yet — 5 tests stay green.

### Step 2 — shim: accept a float OR a Discount (leaf) — `app/discount.py`

```python
from app.discount_types import Discount


def discount_price(price, discount):
    # transitional: a legacy pct float still means a percentage discount,
    # so call sites can migrate to Discount one at a time.
    if isinstance(discount, Discount):
        return discount.apply(price)
    return round(price * (1 - discount), 2)
```

All callers still pass floats — 5 tests stay green. This "add the new alongside the old" leaf is what
lets the migration proceed one caller at a time instead of all at once.

### Steps 3–5 — migrate the call sites (one leaf each)

`app/cart.py` — build `Discount.percentage(...)` instead of bare floats:

```python
from app.discount import discount_price
from app.discount_types import Discount

CART = [
    ("widget", 100.0, Discount.percentage(0.10)),
    ("gadget", 50.0, Discount.percentage(0.20)),
    ("gizmo", 25.0, Discount.percentage(0.0)),
]


def cart_total():
    return round(sum(discount_price(price, d) for _, price, d in CART), 2)
```

`app/checkout.py` and `app/receipt.py` — take a `discount` and pass it straight through:

```python
def express_checkout(price, discount):
    return discount_price(price, discount)
```

```python
def receipt_line(name, price, discount):
    return f"{name}: ${discount_price(price, discount):.2f}"
```

Then migrate the tests to pass `Discount.percentage(...)`, and add a fixed-discount case that proves
the new capability (behavior for percentages is unchanged):

```python
def test_fixed_discount(self):
    self.assertEqual(discount_price(100.0, Discount.fixed(10.0)), 90.0)
```

Commit each caller separately — the suite is green after every one (6 tests once the fixed case is
added).

### Step 6 — the goal: drop the legacy float branch — `app/discount.py`

```python
from app.discount_types import Discount


def discount_price(price, discount: Discount):
    return discount.apply(price)
```

By now nothing passes a float, so the branch is dead — remove it and the signature is `Discount`-only.
**Goal met, verified:** 6 tests OK; `grep -n "1 - pct\|pct)" app/discount.py` returns nothing.

The payoff to point out: the **shim** (Step 2) is the leaf that let the goal land without breaking a
single caller mid-flight. Without it, Step 6 *is* the Step 0 breakage.

## Where it fits — and where it doesn't

Same boundaries as exercise 1 (see [FACILITATOR.md](../FACILITATOR.md) and
[the main README](../README.md)): use Mikado when a change *cascades* and you can't predict the whole
path up front — here, an API many callers touch. A one-caller signature tweak is a normal edit; don't
invent a graph for it. Mikado keeps you shippable through the cascade; it doesn't decide whether the
`Discount` design is the right target — that's still your judgment.
