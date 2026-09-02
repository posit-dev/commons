"""A second file in the same directory, to prove directory loading."""

from commons._measures import measure


@measure(description="Total revenue.")
def total_revenue() -> int:
    return 100
