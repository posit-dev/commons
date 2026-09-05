"""Measures loaded from a path by the test suite."""

from typing import Annotated, Any

from pydantic import Field

from commons import Injected, measure


def double(x: int) -> int:
    """A helper the measure calls. Not a measure itself."""
    return x * 2


@measure(description="Count of orders.")
def order_count(
    region: Annotated[str, Field(description="The sales region.")],
    warehouse: Injected[Any],
) -> int:
    return double(1)
