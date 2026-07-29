// app.js — discount logic for the standalone "Discount Apply" app.
//
// Dual-use by design:
//   • In the browser, the guarded block at the bottom wires the form to apply_discount.
//   • In Node, dsl_runner.js imports apply_discount and runs specs/discount.feature
//     against it — the same function, so there is no second copy of the logic to drift.
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

// --- Browser glue (skipped when imported by Node) --------------------------
if (typeof document !== "undefined") {
  const $ = (id) => document.getElementById(id);
  const money = (n) => `$${Number(n).toFixed(2)}`;

  function onApply() {
    const cartTotal = parseFloat($("amount").value);
    const code = $("code").value.trim();
    const message = $("message");
    const discounted = $("discounted");

    if (Number.isNaN(cartTotal)) {
      message.textContent = "Enter a cart amount to apply a code.";
      message.dataset.state = "reject";
      discounted.textContent = "—";
      return;
    }

    const result = apply_discount(cartTotal, code);
    message.textContent = result.applied
      ? `${result.reason} — you saved ${money(cartTotal - result.final_total)}.`
      : result.reason;
    message.dataset.state = result.applied ? "apply" : "reject";
    discounted.textContent = money(result.final_total);
  }

  document.addEventListener("DOMContentLoaded", () => {
    $("apply").addEventListener("click", onApply);
    $("code").addEventListener("keydown", (e) => {
      if (e.key === "Enter") onApply();
    });
  });
}

// --- Node export (ignored by the browser) ----------------------------------
if (typeof module !== "undefined" && module.exports) {
  module.exports = { apply_discount };
}
