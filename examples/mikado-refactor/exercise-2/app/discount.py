"""Percentage-discount pricing — exercise 2 starting point.

The one coupling that makes the goal cascade: `discount_price` takes a bare `pct`
float, and *every* call site passes one. The team now needs fixed-amount
discounts too (e.g. "$10 off"), which means the second parameter has to become a
`Discount` object instead of a bare fraction. Change that signature in one shot
and every caller — plus the test — breaks at once. That is exactly what turns
"take a Discount" into a graph of prerequisites rather than a one-line edit.

The Mikado goal is to make `discount_price(price, discount)` accept a `Discount`
(percentage OR fixed), with the existing percentage behavior unchanged. Attempt
that naively and watch what breaks.
"""


def discount_price(price, pct):
    """Return `price` after a percentage discount. `pct` is a fraction (0.10 = 10% off)."""
    return round(price * (1 - pct), 2)
