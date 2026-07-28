"""Concrete SQLite-backed order storage.

Starting point of the workshop: this is the *only* storage implementation, and
the report layer reaches straight into it. Note the method name (`fetch_all_rows`)
and the return shape (raw `(id, amount, status)` tuples) are both SQLite-flavored
— that leakage is exactly what the refactor has to untangle.
"""

import sqlite3

# (id, amount, status)
_SEED = [
    (1, 50.0, "paid"),
    (2, 30.0, "paid"),
    (3, 20.0, "refunded"),
    (4, 40.0, "pending"),
]


class SqliteOrders:
    def __init__(self, path=":memory:"):
        self.conn = sqlite3.connect(path)
        self.conn.execute(
            "CREATE TABLE orders (id INTEGER PRIMARY KEY, amount REAL, status TEXT)"
        )
        self.conn.executemany(
            "INSERT INTO orders (id, amount, status) VALUES (?, ?, ?)", _SEED
        )
        self.conn.commit()

    def fetch_all_rows(self):
        """Return raw rows as (id, amount, status) tuples."""
        return self.conn.execute(
            "SELECT id, amount, status FROM orders"
        ).fetchall()
