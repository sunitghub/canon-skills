"""A caller: totals a fixed cart. Passes bare `pct` floats to discount_price —
one of the call sites the naive signature change breaks all at once.
"""

from app.discount import discount_price

# (name, price, pct)
CART = [
    ("widget", 100.0, 0.10),
    ("gadget", 50.0, 0.20),
    ("gizmo", 25.0, 0.0),
]


def cart_total():
    return round(sum(discount_price(price, pct) for _, price, pct in CART), 2)
