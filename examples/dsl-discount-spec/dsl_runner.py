"""dsl_runner.py — minimal Given/When/Then runner for discount.py's apply_discount().

Not a general Gherkin engine — a small fixed-pattern step-matcher. It only recognizes the
exact step shapes used in specs/discount.feature. That's a deliberate choice, not a shortcut:
a step-matcher this size is easy to read and trust in full; a general natural-language parser
would be neither. The same idea scales to real domains — see overtone_demo/scenarios.py in
the CFIHOS/Overtone work this example is drawn from, a spec runner for a plant-equipment
conformance engine built the same way.

Run:  python dsl_runner.py specs/discount.feature
"""
import re
import sys
from pathlib import Path

from discount import apply_discount

GIVEN_TOTAL = re.compile(r'Given cart_total ([\d.]+)')
GIVEN_CODE = re.compile(r'And code "(\w+)"')
THEN_APPLIED = re.compile(r'Then applied is (true|false)')
THEN_TOTAL = re.compile(r'And final_total is ([\d.]+)')
THEN_REASON = re.compile(r'And reason is "([^"]+)"')


def parse_scenarios(text: str) -> list[dict]:
    scenarios: list[dict] = []
    current: dict | None = None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("Scenario:"):
            current = {"name": s.removeprefix("Scenario:").strip()}
            scenarios.append(current)
        elif current is None:
            continue
        elif m := GIVEN_TOTAL.search(s):
            current["total"] = float(m.group(1))
        elif m := GIVEN_CODE.search(s):
            current["code"] = m.group(1)
        elif m := THEN_APPLIED.search(s):
            current["expect_applied"] = m.group(1) == "true"
        elif m := THEN_TOTAL.search(s):
            current["expect_total"] = float(m.group(1))
        elif m := THEN_REASON.search(s):
            current["expect_reason"] = m.group(1)
    return scenarios


def run(path: str) -> bool:
    ok = True
    for sc in parse_scenarios(Path(path).read_text()):
        result = apply_discount(sc["total"], sc["code"])
        problems = []
        if result["applied"] != sc["expect_applied"]:
            problems.append(f"applied {result['applied']} != expected {sc['expect_applied']}")
        if "expect_total" in sc and abs(result.get("final_total", 0) - sc["expect_total"]) > 0.01:
            problems.append(f"final_total {result.get('final_total')} != expected {sc['expect_total']}")
        if "expect_reason" in sc and result.get("reason") != sc["expect_reason"]:
            problems.append(f"reason {result.get('reason')!r} != expected {sc['expect_reason']!r}")
        mark = "PASS" if not problems else "FAIL"
        print(f"  [{mark}] {sc['name']}" + (f" -- {'; '.join(problems)}" if problems else ""))
        ok = ok and not problems
    return ok


if __name__ == "__main__":
    sys.exit(0 if run(sys.argv[1]) else 1)
