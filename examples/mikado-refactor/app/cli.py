"""A caller that constructs `OrderReport()` with no arguments.

One of the call sites the naive "just add a required `store` param" refactor
breaks — which is what turns "inject the store" into a prerequisite node rather
than a one-line change.
"""

from app.report import OrderReport


def main():
    report = OrderReport()
    print(f"Revenue: {report.total_revenue():.2f}")
    for status, n in sorted(report.count_by_status().items()):
        print(f"  {status}: {n}")


if __name__ == "__main__":
    main()
