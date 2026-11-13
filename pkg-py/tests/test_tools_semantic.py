"""describe_table, first-touch delivery, and retrieval for semantic models.

What the prose says and which models a table gets it from are pinned by
tests/shared/semantic-models.json and context_layer.json; these cover the
tool wiring around them.
"""

import pytest

from commons import DataSource
from commons._context_layer import augment_context_layer
from commons._tools import FirstTouch, _describe_table_text, _first_touch_entries

from ._warehouse import FakeWarehouse

REVENUE = """name: revenue
description: Revenue semantics.
custom_instructions: Use booked revenue for finance questions.
tables:
  - name: orders
    base_table: {database: ANALYTICS, schema: PUBLIC, table: ORDERS}
    metrics:
      - name: revenue
        description: Booked revenue.
"""

BROKEN = "tables: [unclosed"

VIEW = "ANALYTICS.PUBLIC.REVENUE_MODEL"
ORDERS = "ANALYTICS.PUBLIC.ORDERS"


def source(tables=None, views=None) -> DataSource:
    warehouse = FakeWarehouse(semantic_views=views or {"REVENUE_MODEL": REVENUE})
    return DataSource._from_warehouse(warehouse, tables, None, None)


def test_describe_table_describes_a_stub_and_keeps_it_lazy() -> None:
    namespace = source()
    text = _describe_table_text(namespace, "warehouse", VIEW, FirstTouch())
    assert text.startswith(f"Semantic model `{VIEW}`.")
    assert "`ANALYTICS.PUBLIC.REVENUE_MODEL::orders.revenue` (metric)" in text
    assert VIEW not in namespace.semantic_models


def test_describe_table_reports_an_unreadable_stub() -> None:
    namespace = source(views={"REVENUE_MODEL": BROKEN})
    text = _describe_table_text(namespace, "warehouse", VIEW, FirstTouch())
    assert "could not be read" in text


def test_describe_table_describes_a_loaded_model() -> None:
    exact = source(tables=[VIEW])
    text = _describe_table_text(exact, "warehouse", VIEW, FirstTouch())
    assert "Revenue semantics." in text


def test_first_touch_includes_semantic_context_once() -> None:
    over_orders = source(tables=[ORDERS])
    tracker = FirstTouch()
    described = _describe_table_text(over_orders, "warehouse", ORDERS, tracker)
    assert described.endswith("Use booked revenue for finance questions.")
    assert (
        _first_touch_entries(over_orders, "SELECT * FROM ORDERS", "warehouse", tracker)
        == []
    )

    fresh = FirstTouch()
    entries = _first_touch_entries(
        over_orders, "SELECT * FROM ORDERS", "warehouse", fresh
    )
    assert entries == ["Use booked revenue for finance questions."]
    assert (
        _first_touch_entries(over_orders, "SELECT * FROM ORDERS", "warehouse", fresh)
        == []
    )


@pytest.mark.parametrize("tables", [None])
def test_stubs_add_no_retrieval_until_read(tables) -> None:
    assert augment_context_layer(None, [source(tables=tables)]) is None
