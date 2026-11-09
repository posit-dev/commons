"""call_metrics over a warehouse's native semantic metrics, end to end.

Which calls are refused is pinned by tests/shared/semantic-models.json, and
when a listed model is read by tests/shared/snowflake-semantic-views.json;
these cover the run itself: the query sent and the values bound.
"""

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
