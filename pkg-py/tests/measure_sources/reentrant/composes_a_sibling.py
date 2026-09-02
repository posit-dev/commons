"""Calls semantic_layer() on another path during its own import.

A non-reentrant lock around the import machinery would deadlock here: this
module's own load already holds _IMPORT_LOCK when the line below tries to
acquire it again on the same thread.
"""

from pathlib import Path

from commons._measures import measure, semantic_layer

NESTED_LAYER = semantic_layer(Path(__file__).parent.parent / "nested" / "orders.py")


@measure(description="Outer measure.")
def outer_measure() -> int:
    return 1
