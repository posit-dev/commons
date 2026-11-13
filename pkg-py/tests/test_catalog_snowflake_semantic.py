"""Selecting Snowflake semantic views: the detail beneath the shared contract.

Which views become models and which stay stubs is pinned by
tests/shared/snowflake-semantic-views.json; these cover what it does not,
such as the probe's SQL and binds, and that stubs are never read early.
"""

import pytest

from commons import DataSource
from commons._catalog import CatalogAuthorizationError
from commons._tools import _queryable

from ._warehouse import FakeWarehouse

REVENUE = """name: revenue
description: Revenue semantics.
tables:
  - name: orders
    base_table: {database: ANALYTICS, schema: PUBLIC, table: ORDERS}
    dimensions:
      - name: region
        description: Sales region.
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


def data_source(warehouse, tables=None, exclude=None) -> DataSource:
    return DataSource._from_warehouse(warehouse, tables, exclude, None)


def test_namespace_selection_reads_no_specification() -> None:
    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": REVENUE})
    assert list(data_source(warehouse).semantic_stubs) == [VIEW]
    assert warehouse.yaml_reads == []


def test_manifest_lists_stubs() -> None:
    source = data_source(FakeWarehouse(semantic_views={"REVENUE_MODEL": REVENUE}))
    assert source.manifest is not None
    assert source.manifest.objects[VIEW].kind == "semantic_view"
    assert VIEW not in source.manifest.access


def test_exact_view_is_read_and_probed() -> None:
    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": REVENUE})
    source = data_source(warehouse, tables=[VIEW])
    assert list(source.semantic_models) == [VIEW]
    assert source.semantic_models[VIEW].name == "revenue"
    assert source.semantic_stubs == {}
    assert source.tables == []
    assert (
        'SELECT * FROM SEMANTIC_VIEW(\n  "ANALYTICS"."PUBLIC"."REVENUE_MODEL"\n'
        '  METRICS "orders"."revenue"\n)\nLIMIT 0'
    ) in warehouse.queries


def test_exact_view_is_removed_from_relations() -> None:
    warehouse = FakeWarehouse(
        relations=["SALES", "ORDERS", "REVENUE_MODEL"],
        semantic_views={"REVENUE_MODEL": REVENUE},
    )
    source = data_source(warehouse, tables=[VIEW, "ANALYTICS.PUBLIC.ORDERS"])
    assert source.tables == ["ANALYTICS.PUBLIC.ORDERS"]
    assert VIEW in source.semantic_models


def test_semantic_only_selection_is_nonempty() -> None:
    warehouse = FakeWarehouse(relations=[], semantic_views={"REVENUE_MODEL": REVENUE})
    assert list(data_source(warehouse).semantic_stubs) == [VIEW]


def test_probe_binds_typed_nulls_for_required_parameters() -> None:
    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": PARAMETERIZED})
    data_source(warehouse, tables=[VIEW])
    probe = next(q for q in warehouse.queries if "LIMIT 0" in q)
    assert 'VARIABLES "REGION" => CAST(:p0 AS VARCHAR(16))' in probe
    assert warehouse.params[warehouse.queries.index(probe)] == {"p0": None}


def test_refused_view_fails_construction() -> None:
    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": REVENUE})
    warehouse.refuse.add("REVENUE_MODEL")
    with pytest.raises(CatalogAuthorizationError):
        data_source(warehouse, tables=[VIEW])


def test_catalog_search_treats_a_stub_as_queryable() -> None:
    warehouse = FakeWarehouse(semantic_views={"REVENUE_MODEL": REVENUE})
    source = data_source(warehouse)
    assert source.manifest is not None
    probes = len(warehouse.queries)
    assert _queryable(source, source.manifest)(VIEW) is True
    assert len(warehouse.queries) == probes
