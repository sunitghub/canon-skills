"""A second caller: one discounted line, `pct` passed straight through."""

from app.discount import discount_price


def express_checkout(price, pct):
    return discount_price(price, pct)
