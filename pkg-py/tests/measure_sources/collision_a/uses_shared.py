"""Imports shared_lib by its bare name, registering it in sys.modules under
that name for the rest of the process.
"""

from shared_lib import value  # type: ignore[missing-import]

from commons._measures import measure


@measure(description="From directory a.")
def a_measure() -> int:
    return value()
