from pydantic import create_model

from commons._measures import Measure


def total() -> int:
    return 1


# A measure need not be a decorated function; a bare record at module level
# is harvested too.
grand_total = Measure(
    name="grand_total",
    title="Grand total",
    description="Total of everything.",
    func=total,
    params=create_model("grand_total"),
)
