"""First file, sorted before b_file.py in this directory."""

from commons._measures import measure


def helper() -> int:
    """A helper this file's measure calls."""
    return 1


@measure(description="Measure a.")
def measure_a() -> int:
    return helper()
