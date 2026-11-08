"""call_metrics over a warehouse's native semantic metrics."""

import pytest

from commons import DataSource
from commons._definitions import Registry
from commons._handles import HandleStore
from commons._pool import call_metrics

from ._warehouse import FakeWarehouse
from .test_pool import record

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

FINANCE = """tables:
  - name: ledger
    base_table: {database: ANALYTICS, schema: PUBLIC, table: ORDERS}
    metrics:
      - name: margin
"""

UNSUPPORTED = """variables:
  - name: payload
    data_type: VARIANT
tables:
  - name: orders
    base_table: {database: ANALYTICS, schema: PUBLIC, table: ORDERS}
    metrics:
      - name: revenue
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


def test_call_metrics_hydrates_a_stub_from_a_qualified_name() -> None:
    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": REVENUE})
    source = warehouse_source(warehouse)
    assert VIEW in source.semantic_stubs
    run(source, metrics=[f"{VIEW}::revenue"])
    assert warehouse.yaml_reads == ["REVENUE_MODEL"]
    assert VIEW in source.semantic_models


def test_hydration_skips_models_already_loaded() -> None:
    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": REVENUE})
    source = warehouse_source(warehouse)
    run(source, metrics=[f"{VIEW}::revenue"])
    run(source, metrics=[f"{{{{{VIEW}::revenue}}}}"])
    assert warehouse.yaml_reads == ["REVENUE_MODEL"]


def test_an_unsupported_stub_reports_why() -> None:
    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": UNSUPPORTED})
    source = warehouse_source(warehouse)
    with pytest.raises(ValueError, match="is not supported: .*VARIANT"):
        run(source, metrics=[f"{VIEW}::revenue"])


def test_call_metrics_refuses_mixed_origins() -> None:
    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": REVENUE})
    source = warehouse_source(warehouse, [VIEW])
    registry = Registry([record("net_revenue", source="warehouse")])
    with pytest.raises(ValueError, match="either data-dict definitions or one"):
        run(source, registry, metrics=["revenue", "net_revenue"])


def test_call_metrics_refuses_metrics_across_models() -> None:
    warehouse = FakeWarehouse(
        semantic_views={"REVENUE_MODEL": REVENUE, "FINANCE_MODEL": FINANCE}
    )
    source = warehouse_source(warehouse, [VIEW, "ANALYTICS.PUBLIC.FINANCE_MODEL"])
    with pytest.raises(ValueError, match="one native semantic model"):
        run(source, metrics=["revenue", "margin"])


def test_call_metrics_binds_arguments() -> None:
    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": PARAMETERIZED})
    source = warehouse_source(warehouse, [VIEW])
    run(source, metrics=["revenue"], arguments={"REGION": "EMEA"})
    assert 'VARIABLES "REGION" => CAST(:p0 AS VARCHAR(16))' in warehouse.queries[-1]
    assert warehouse.params[-1] == {"p0": "EMEA"}


def test_call_metrics_checks_arguments_against_the_model() -> None:
    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": PARAMETERIZED})
    source = warehouse_source(warehouse, [VIEW])
    with pytest.raises(ValueError, match="Missing required argument: 'REGION'"):
        run(source, metrics=["revenue"])


def test_arguments_are_refused_for_definitions() -> None:
    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": REVENUE})
    source = warehouse_source(warehouse, [VIEW])
    registry = Registry([record("net_revenue", source="warehouse")])
    with pytest.raises(ValueError, match="only for native semantic metrics"):
        run(source, registry, metrics=["net_revenue"], arguments={"x": 1})
