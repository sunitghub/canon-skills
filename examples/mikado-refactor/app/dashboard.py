"""A second, independent caller.

Two separate `OrderReport()` call sites are what make the "add a *defaulted*
constructor param" step a real leaf: it lets both callers keep working, green,
while the store is threaded through — instead of breaking them both at once.
"""

from app.report import OrderReport


def revenue_banner():
    return f"Total revenue to date: ${OrderReport().total_revenue():.2f}"
