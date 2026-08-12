"""A third caller: a formatted receipt line. Also passes a bare `pct`."""

from app.discount import discount_price


def receipt_line(name, price, pct):
    return f"{name}: ${discount_price(price, pct):.2f}"
