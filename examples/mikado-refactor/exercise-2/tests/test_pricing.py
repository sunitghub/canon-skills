"""Behavior tests — the green tree exercise 2's Mikado refactor must never break.

The expected numbers are written by hand here, not derived from the code: a 10%
discount on 100.00 is 90.00; the fixed cart totals 155.00 (90 + 40 + 25). They
pin *behavior*, so they stay green while the `discount_price` signature is
migrated from a bare `pct` float to a `Discount` object underneath them.

`test_express_checkout` and `test_receipt_line` also exercise two of the call
sites directly, so you feel the cascade from the test side too — the naive
signature change reddens these along with the callers.
"""

import unittest

from app.cart import cart_total
from app.checkout import express_checkout
from app.discount import discount_price
from app.receipt import receipt_line


class TestDiscountPricing(unittest.TestCase):
    def test_percentage_discount(self):
        self.assertEqual(discount_price(100.0, 0.10), 90.0)

    def test_zero_discount_is_identity(self):
        self.assertEqual(discount_price(25.0, 0.0), 25.0)

    def test_cart_total(self):
        # 90.00 + 40.00 + 25.00
        self.assertEqual(cart_total(), 155.0)

    def test_express_checkout(self):
        self.assertEqual(express_checkout(50.0, 0.20), 40.0)

    def test_receipt_line(self):
        self.assertEqual(receipt_line("widget", 100.0, 0.10), "widget: $90.00")


if __name__ == "__main__":
    unittest.main()
