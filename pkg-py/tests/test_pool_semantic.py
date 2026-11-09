"""call_metrics over a warehouse's native semantic metrics, end to end.

Which calls are refused is pinned by tests/shared/semantic-models.json, and
when a listed model is read by tests/shared/snowflake-semantic-views.json;
these cover the run itself: the query sent and the values bound.
"""

import re

import pytest

from commons import DataSource
from commons._definitions import Registry
from commons._handles import HandleStore
from commons._pool import call_metrics

from ._warehouse import FakeWarehouse

REVENUE = """name: revenue
tables:
  - name: orders
    base_table: {database: ANALYTICS, schema: PUBLIC, table: ORDERS}
    dimensions:
      - name: region
    metrics:
      - name: revenue
        description: Booked revenue.
"""


PARAMETERIZED = """variables:
  - name: REGION
    data_type: VARCHAR(16)
  - name: SINCE
    data_type: DATE
    default_value: "2024-01-01"
tables:
  - name: orders
    base_table: {database: ANALYTICS, schema: PUBLIC, table: ORDERS}
    metrics:
      - name: revenue
"""

VIEW = "ANALYTICS.PUBLIC.REVENUE_MODEL"


def warehouse_source(warehouse: FakeWarehouse, tables=None) -> DataSource:
    return DataSource._from_warehouse(warehouse, tables, None, None)


def run(source: DataSource, registry: Registry | None = None, **kwargs):
    return call_metrics(
        registry or Registry(), source, "warehouse", HandleStore(), **kwargs
    )


def test_call_metrics_runs_a_native_metric() -> None:
    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": REVENUE})
    source = warehouse_source(warehouse, [VIEW])
    result = run(
        source,
        metrics=["revenue"],
        dimensions=["region"],
        where=[{"column": "region", "op": "=", "value": "EMEA"}],
    )
    assert warehouse.queries[-1] == (
        'SELECT * FROM SEMANTIC_VIEW(\n  "ANALYTICS"."PUBLIC"."REVENUE_MODEL"\n'
        '  DIMENSIONS "orders"."region"\n  METRICS "orders"."revenue"\n'
        '  WHERE ("orders"."region" = \'EMEA\')\n)'
    )
    assert isinstance(result.value, str)
    assert "1200" in result.value


def test_call_metrics_binds_arguments() -> None:
    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": PARAMETERIZED})
    source = warehouse_source(warehouse, [VIEW])
    run(source, metrics=["revenue"], arguments={"REGION": "EMEA"})
    assert 'VARIABLES "REGION" => CAST(:p0 AS VARCHAR(16))' in warehouse.queries[-1]
    assert warehouse.params[-1] == {"p0": "EMEA"}


def test_call_metrics_binds_each_argument_to_its_variable() -> None:
    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": PARAMETERIZED})
    source = warehouse_source(warehouse, [VIEW])
    arguments = {"SINCE": "2024-06-01", "REGION": "EMEA"}
    run(source, metrics=["revenue"], arguments=arguments)
    binds = re.findall(r'"(\w+)" => CAST\(:(p\d+) AS', warehouse.queries[-1])
    assert len(binds) == 2
    params = warehouse.params[-1]
    assert params is not None
    assert {name: params[bind] for name, bind in binds} == arguments


VERIFIED = """tables:
  - name: orders
    base_table: {database: ANALYTICS, schema: PUBLIC, table: ORDERS}
    metrics:
      - name: revenue
verified_queries:
  - name: all_orders
    question: Which orders are there?
    sql: SELECT * FROM "ANALYTICS"."PUBLIC"."ORDERS"
"""


def test_call_calculation_reads_a_stub_and_runs_its_verified_query() -> None:
    from commons._citations import TAG_EXTRA_KEY
    from commons._pool import call_calculation
    from commons._provenance import Tag

    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": VERIFIED})
    source = warehouse_source(warehouse)
    result = call_calculation(
        {"warehouse": source}, "warehouse", HandleStore(), f"{VIEW}::all_orders"
    )
    assert warehouse.yaml_reads == ["REVENUE_MODEL"]
    assert warehouse.queries[-1] == 'SELECT * FROM "ANALYTICS"."PUBLIC"."ORDERS"'
    assert result.extra[TAG_EXTRA_KEY] == Tag.A


def test_call_calculation_refuses_arguments() -> None:
    from commons._pool import call_calculation

    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": VERIFIED})
    source = warehouse_source(warehouse, [VIEW])
    with pytest.raises(ValueError, match="Unexpected argument"):
        call_calculation(
            {"warehouse": source}, "warehouse", None, "all_orders", {"region": "EMEA"}
        )


def test_call_calculation_names_queries_on_other_sources() -> None:
    from commons._pool import call_calculation

    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": VERIFIED})
    source = warehouse_source(warehouse, [VIEW])
    other = warehouse_source(FakeWarehouse(), ["ANALYTICS.PUBLIC.SALES"])
    sources = {"warehouse": source, "archive": other}
    with pytest.raises(ValueError, match=f"{VIEW}::all_orders"):
        call_calculation(sources, "archive", None, "all_orders")


def test_a_trusted_query_still_refuses_dml() -> None:
    warehouse = FakeWarehouse()
    source = warehouse_source(warehouse)
    with pytest.raises(ValueError, match="exactly one read-only SELECT"):
        source._query_trusted("WITH t AS (SELECT 1) DELETE FROM orders")
    assert not any("DELETE" in query for query in warehouse.queries)
