// app.js — browser glue for the Discount Apply page.
//
// The business rule lives in discount.js (loaded before this file by index.html), which defines
// the global apply_discount(cartTotal, code). This file only reads the form, calls the rule, and
// writes the result — no business logic here, so the rule has exactly one home.

(function () {
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

    const result = apply_discount(cartTotal, code); // from discount.js
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
})();
