// discount.js — the business rule, on its own so both the checker and the app share it.
//
// Part 1 of the workshop builds this file plus the runner that checks it.
// Part 2's browser app (index.html + app.js) imports this same function for its UI, so the
// thing the spec checks and the thing the user clicks are the same code — no second copy to drift.
//
// The exact rules are defined in ../specs/discount.feature. This file must satisfy them;
// don't edit the spec to match the code.

function apply_discount(cartTotal, code) {
  const RULES = {
    SAVE10: { rate: 0.1, min: 50 }, // 10% off, only if cart_total >= 50
    SAVE20: { rate: 0.2, min: 100 }, // 20% off, only if cart_total >= 100
  };

  const rule = RULES[code];
  if (!rule) {
    return { applied: false, final_total: cartTotal, reason: "invalid code" };
  }
  if (cartTotal < rule.min) {
    return { applied: false, final_total: cartTotal, reason: "minimum not met" };
  }

  // Round to cents so 120.00 * 0.8 lands exactly on 96.00.
  const final_total = Math.round(cartTotal * (1 - rule.rate) * 100) / 100;
  return { applied: true, final_total, reason: `${code} applied` };
}

// Node (the runner) imports it; the browser reads it as a global from <script src="discount.js">.
if (typeof module !== "undefined" && module.exports) {
  module.exports = { apply_discount };
}
