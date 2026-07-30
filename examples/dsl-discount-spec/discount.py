"""discount.py — the business rule, imported by dsl_runner.py.

Faithful Python twin of app/discount.js's apply_discount (same rules, same field names), so the
Python runner (python dsl_runner.py specs/discount.feature) checks the exact same behavior the JS
runner does. The exact rules are defined in specs/discount.feature; this file must satisfy them —
don't edit the spec to match the code.
"""

# 10% off only if cart_total >= 50; 20% off only if cart_total >= 100. Pinned by the boundary
# scenarios in specs/discount.feature (t-ef19) — not left to inference.
RULES = {
    "SAVE10": {"rate": 0.1, "min": 50},
    "SAVE20": {"rate": 0.2, "min": 100},
}


def apply_discount(cart_total: float, code: str) -> dict:
    rule = RULES.get(code)
    if rule is None:
        return {"applied": False, "final_total": cart_total, "reason": "invalid code"}
    if cart_total < rule["min"]:
        return {"applied": False, "final_total": cart_total, "reason": "minimum not met"}
    # Round to cents so 120.00 * 0.8 lands exactly on 96.00.
    final_total = round(cart_total * (1 - rule["rate"]) + 1e-9, 2)
    return {"applied": True, "final_total": final_total, "reason": f"{code} applied"}
