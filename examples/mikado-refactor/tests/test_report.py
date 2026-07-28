"""Behavior tests — the green tree the Mikado refactor must never break.

These assert *behavior*, and they assert it independently: the expected numbers
(80.0 revenue, the status counts) are written by hand here, not derived from the
code. Read against canon's own lesson — "a test that reads the same list the code
does can't fail" — these are real checks. They must stay green after every single
Mikado step; the moment one goes red, you've left the tree broken and it's time to
revert and record a prerequisite instead of pushing through.

`test_store_returns_seeded_rows` also instantiates the concrete `SqliteOrders`
directly. That's a deliberate coupling point: it's one of the call sites your
refactor will have to account for, so you feel the cascade from the test side too.
"""

import unittest

from app.db import SqliteOrders
from app.report import OrderReport


class TestOrderReport(unittest.TestCase):
    def test_total_revenue_sums_only_paid_orders(self):
        # Seed has paid orders of 50.0 and 30.0; refunded/pending are excluded.
        self.assertEqual(OrderReport().total_revenue(), 80.0)

    def test_count_by_status(self):
        self.assertEqual(
            OrderReport().count_by_status(),
            {"paid": 2, "refunded": 1, "pending": 1},
        )


class TestSqliteOrders(unittest.TestCase):
    def test_store_returns_seeded_rows(self):
        rows = SqliteOrders().fetch_all_rows()
        self.assertEqual(len(rows), 4)


if __name__ == "__main__":
    unittest.main()
