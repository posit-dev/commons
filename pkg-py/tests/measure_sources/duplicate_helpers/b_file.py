"""Second file, sorted after a_file.py; defines a same-named helper.

Proves directory scanning keeps the first file's source for a colliding
helper name.
"""

from commons._measures import measure


def helper() -> int:
    """A colliding helper name; this definition must lose to a_file's."""
    return 2


@measure(description="Measure b.")
def measure_b() -> int:
    return helper()
