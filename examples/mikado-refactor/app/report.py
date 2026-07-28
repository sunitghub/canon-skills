"""Order reporting.

Starting point of the workshop. Two couplings live here, and they are the
reason the naive refactor cascades:

  1. It *imports and constructs* `SqliteOrders` itself (line below) — callers
     can't swap the storage, and every `OrderReport()` silently opens a DB.
  2. It reads raw tuples by index (`row[1]`, `row[2]`) — the report's logic is
     welded to SQLite's column order.

The Mikado goal is to make `OrderReport` depend on an injected `OrderStore`
interface instead, with no direct `SqliteOrders` import. Attempt that naively
and watch what breaks.
"""

from app.db import SqliteOrders


class OrderReport:
    def __init__(self):
        self.db = SqliteOrders()

    def total_revenue(self):
        # row = (id, amount, status); count only paid orders
        return sum(row[1] for row in self.db.fetch_all_rows() if row[2] == "paid")

    def count_by_status(self):
        counts = {}
        for row in self.db.fetch_all_rows():
            counts[row[2]] = counts.get(row[2], 0) + 1
        return counts
