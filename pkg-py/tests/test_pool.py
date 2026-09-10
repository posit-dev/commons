"""The pool: ranking a query against it, and the governed query it compiles."""

from pathlib import Path
from typing import Annotated, Any

import pandas as pd
import pytest
from pydantic import Field

from commons import DataSource, data_source, measure
from commons._definitions import ExportRecord, Registry
from commons._handles import HandleStore
from commons._measures import as_measure
from commons._pool import (
    call_metrics,
    definition_pool_text,
    lexical_rank,
    search_pool_text,
)

DICTIONARY = """
name: sales
tables:
  - name: sales
    description: One row per order line.
    columns:
      - name: revenue
        type: number
      - name: region
        type: string
  - name: regions
    columns:
      - name: name
        type: string
"""


def record(
    name: str,
    table: str = "sales",
    *,
    source: str = "sales_db",
    kind: str = "metric",
    sql: str = "sum(revenue)",
    label: str | None = None,
    description: str | None = None,
    details: str | None = None,
    mixed_grain: bool = False,
    notes: list[str] | None = None,
) -> ExportRecord:
    return ExportRecord(
        name=name,
        table=table,
        source=source,
        kind=kind,
        type="number",
        expression="SUM(revenue)",
        label=label,
        description=description,
        details=details,
        columns=["revenue"],
        definitions=[],
        sql=sql,
        target="SQL(duckdb)",
        notes=notes or [],
        mixed_grain=mixed_grain,
    )


@pytest.fixture
def source(tmp_path: Path) -> DataSource:
    path = tmp_path / "data-dict.yaml"
    path.write_text(DICTIONARY, encoding="utf-8")
    return data_source(
        sales=pd.DataFrame(
            {
                "revenue": [500.0, 900.0, 300.0],
                "region": ["EMEA", "Americas", "EMEA"],
            }
        ),
        regions=pd.DataFrame({"name": ["EMEA", "Americas"]}),
        dictionary=path,
    )


def metrics(source: DataSource, registry: Registry, **kwargs: Any) -> str:
    result = call_metrics(registry, source, "sales_db", HandleStore(), **kwargs)
    assert isinstance(result.value, str)
    return result.value


# ---- ranking --------------------------------------------------------------


def test_documents_rank_by_how_much_of_the_query_they_cover() -> None:
    documents = ["revenue by region", "revenue", "orders"]

    assert lexical_rank("revenue region", documents) == [0, 1]


def test_a_single_character_term_is_not_worth_ranking_on() -> None:
    assert lexical_rank("a", ["a b c"]) == []


def test_a_query_matching_nothing_ranks_nothing() -> None:
    assert lexical_rank("nothing here", ["revenue by region"]) == []


def test_the_limit_caps_the_hits() -> None:
    assert lexical_rank("revenue", ["revenue", "revenue", "revenue"], limit=2) == [0, 1]


# ---- search_pool_text -----------------------------------------------------


def _order_count():
    @measure(description="Count orders in a region.")
    def order_count(
        region: Annotated[str, Field(description="Which region to count.")],
    ) -> int:
        return 1

    found = as_measure(order_count)
    assert found is not None
    return {found.name: found}


def test_an_empty_pool_says_so() -> None:
    assert search_pool_text({}, Registry(), "revenue") == "The semantic layer is empty."


def test_a_query_matching_nothing_points_at_sql() -> None:
    text = search_pool_text({}, Registry([record("net_revenue")]), "shipping delays")

    assert text == (
        'Nothing in the semantic layer matches "shipping delays". '
        "Consider writing a SQL query."
    )


def test_a_matching_measure_comes_back_as_its_schema_block() -> None:
    text = search_pool_text(_order_count(), Registry(), "count orders")

    assert text.startswith("### order_count\nCount orders in a region.")
    assert "arguments:" in text


def test_a_matching_definition_comes_back_as_its_pool_block() -> None:
    text = search_pool_text({}, Registry([record("net_revenue")]), "net revenue")

    assert text.startswith("### {{net_revenue}} --- metric on table `sales`")


def test_measures_and_definitions_are_ranked_together() -> None:
    text = search_pool_text(
        _order_count(), Registry([record("net_revenue")]), "count orders revenue"
    )

    assert "### order_count" in text
    assert "### {{net_revenue}}" in text


# ---- definition_pool_text -------------------------------------------------


def test_a_metric_says_how_to_run_it_both_ways() -> None:
    records = [record("net_revenue")]

    text = definition_pool_text(records[0], records)

    assert "Selected SQL(duckdb): `(sum(revenue))`." in text
    assert text.endswith(
        'Query with call_metrics (metrics = ["net_revenue"]) or in run_sql as '
        "`SELECT {{net_revenue}} AS value`."
    )


def test_a_metric_names_the_siblings_a_query_can_be_shaped_with() -> None:
    records = [
        record("net_revenue"),
        record("emea", kind="filter", sql="region = 'EMEA'"),
        record("big", kind="derived", sql="revenue > 100"),
    ]

    text = definition_pool_text(records[0], records)

    assert text.endswith(
        "Filters and derived definitions on this table: "
        "{{emea}} (filter), {{big}} (derived)."
    )


def test_a_sibling_on_another_source_is_not_named() -> None:
    records = [
        record("net_revenue"),
        record("emea", kind="filter", sql="region = 'EMEA'", source="other"),
    ]

    assert "{{emea}}" not in definition_pool_text(records[0], records)


def test_a_filter_offers_call_metrics_only_when_the_table_has_a_metric() -> None:
    alone = [record("emea", kind="filter", sql="region = 'EMEA'")]
    beside = [*alone, record("net_revenue")]

    assert definition_pool_text(alone[0], alone).endswith(
        "Apply in run_sql (e.g. `WHERE {{emea}}`)."
    )
    assert definition_pool_text(alone[0], beside).endswith(
        "Apply in run_sql (e.g. `WHERE {{emea}}`) or as a call_metrics filter "
        "or dimension."
    )


def test_a_derived_definition_offers_grouping() -> None:
    records = [record("big", kind="derived", sql="revenue > 100"), record("total")]

    assert definition_pool_text(records[0], records).endswith(
        "Use in run_sql SELECT or GROUP BY as `{{big}}`, or as a call_metrics "
        "dimension."
    )


def test_a_mixed_grain_definition_is_offered_to_run_sql_alone() -> None:
    records = [record("ratio", mixed_grain=True)]

    text = definition_pool_text(records[0], records)

    assert text.endswith(
        "Use `{{ratio}}` only in run_sql with manually grain-correct query structure."
    )
    assert "call_metrics" not in text


def test_translation_notes_travel_with_the_definition() -> None:
    records = [record("net_revenue", notes=["Rounded half up."])]

    assert "Translation notes: Rounded half up." in definition_pool_text(
        records[0], records
    )


def test_prose_is_flattened_onto_one_line() -> None:
    records = [record("net_revenue", description="Revenue\nafter refunds.")]

    assert "Revenue after refunds." in definition_pool_text(records[0], records)


# ---- call_metrics ---------------------------------------------------------


def test_a_metric_alone_is_grouped_globally(source: DataSource) -> None:
    registry = Registry([record("net_revenue")])

    body = metrics(source, registry, metrics=["net_revenue"])

    assert "| net_revenue |" in body
    assert "| 1700 |" in body


def test_a_documented_column_can_be_grouped_by(source: DataSource) -> None:
    registry = Registry([record("net_revenue")])

    body = metrics(source, registry, metrics=["net_revenue"], dimensions=["region"])

    assert "| region | net_revenue |" in body
    assert "| EMEA | 800 |" in body


def test_a_derived_definition_can_be_grouped_by(source: DataSource) -> None:
    registry = Registry(
        [record("net_revenue"), record("big", kind="derived", sql="revenue > 400")]
    )

    body = metrics(source, registry, metrics=["net_revenue"], dimensions=["big"])

    assert "| big | net_revenue |" in body


def test_braces_around_a_name_are_tolerated(source: DataSource) -> None:
    registry = Registry([record("net_revenue")])

    body = metrics(source, registry, metrics=["{{net_revenue}}"])

    assert "| net_revenue |" in body


def test_a_governed_filter_narrows_the_query(source: DataSource) -> None:
    registry = Registry(
        [record("net_revenue"), record("emea", kind="filter", sql="region = 'EMEA'")]
    )

    body = metrics(source, registry, metrics=["net_revenue"], filters=["emea"])

    assert "| 800 |" in body


def test_a_where_predicate_narrows_the_query(source: DataSource) -> None:
    registry = Registry([record("net_revenue")])

    body = metrics(
        source,
        registry,
        metrics=["net_revenue"],
        where=[{"column": "revenue", "op": ">", "value": "400"}],
    )

    assert "| 1400 |" in body


def test_a_string_predicate_is_quoted_for_the_dialect(source: DataSource) -> None:
    # An apostrophe in the value would end the literal early and leave the
    # rest of it as SQL, so the query has to survive one and match nothing.
    registry = Registry([record("net_revenue")])

    body = metrics(
        source,
        registry,
        metrics=["net_revenue"],
        where=[{"column": "region", "op": "=", "value": "O'Hare"}],
    )

    assert body.splitlines()[:3] == ["| net_revenue |", "|---|", "| NA |"]


def test_the_applied_definitions_are_reported(source: DataSource) -> None:
    registry = Registry([record("net_revenue")])

    body = metrics(source, registry, metrics=["net_revenue"])

    assert "Applied governed definitions:" in body
    assert "- {{net_revenue}} (sales): SQL(duckdb) `(sum(revenue))`" in body


def test_the_result_is_reachable_as_a_handle(source: DataSource) -> None:
    registry = Registry([record("net_revenue")])
    handles = HandleStore()

    call_metrics(registry, source, "sales_db", handles, metrics=["net_revenue"])

    assert handles.ids() == ["r1"]


def test_no_metric_at_all_is_refused(source: DataSource) -> None:
    with pytest.raises(ValueError, match="at least one governed metric"):
        metrics(source, Registry([record("net_revenue")]), metrics=[])


def test_an_unknown_metric_names_the_ones_that_exist(source: DataSource) -> None:
    registry = Registry([record("net_revenue")])

    with pytest.raises(ValueError, match="Available metrics: net_revenue"):
        metrics(source, registry, metrics=["profit"])


def test_a_definition_of_the_wrong_kind_is_sent_to_sql(source: DataSource) -> None:
    registry = Registry([record("emea", kind="filter", sql="region = 'EMEA'")])

    with pytest.raises(ValueError, match="is a filter, not a metric"):
        metrics(source, registry, metrics=["emea"])


def test_an_ambiguous_metric_name_asks_for_a_qualified_one(
    source: DataSource,
) -> None:
    registry = Registry(
        [record("total"), record("total", table="regions", sql="count(*)")]
    )

    with pytest.raises(ValueError, match=r"\{\{regions::total\}\}"):
        metrics(source, registry, metrics=["total"])


def test_a_qualified_name_resolves_the_ambiguity(source: DataSource) -> None:
    registry = Registry(
        [record("total"), record("total", table="regions", sql="count(*)")]
    )

    body = metrics(source, registry, metrics=["regions::total"])

    assert "| 2 |" in body


def test_metrics_spanning_two_tables_are_refused(source: DataSource) -> None:
    registry = Registry(
        [record("net_revenue"), record("regions", table="regions", sql="count(*)")]
    )

    with pytest.raises(ValueError, match="must share a table"):
        metrics(source, registry, metrics=["net_revenue", "regions"])


def test_a_mixed_grain_metric_is_refused(source: DataSource) -> None:
    registry = Registry([record("ratio", mixed_grain=True)])

    with pytest.raises(ValueError, match="Mixed-grain metric ratio"):
        metrics(source, registry, metrics=["ratio"])


def test_a_mixed_grain_filter_is_refused(source: DataSource) -> None:
    registry = Registry(
        [record("net_revenue"), record("odd", kind="filter", mixed_grain=True)]
    )

    with pytest.raises(ValueError, match="Mixed-grain filter odd"):
        metrics(source, registry, metrics=["net_revenue"], filters=["odd"])


def test_a_mixed_grain_dimension_is_refused(source: DataSource) -> None:
    registry = Registry(
        [record("net_revenue"), record("odd", kind="derived", mixed_grain=True)]
    )

    with pytest.raises(ValueError, match="cannot be grouped by"):
        metrics(source, registry, metrics=["net_revenue"], dimensions=["odd"])


def test_a_metric_cannot_be_grouped_by(source: DataSource) -> None:
    registry = Registry([record("net_revenue")])

    with pytest.raises(ValueError, match="is a metric and can't be grouped by"):
        metrics(source, registry, metrics=["net_revenue"], dimensions=["net_revenue"])


def test_an_undocumented_dimension_names_the_documented_columns(
    source: DataSource,
) -> None:
    registry = Registry([record("net_revenue")])

    with pytest.raises(ValueError, match="Documented columns: revenue, region"):
        metrics(source, registry, metrics=["net_revenue"], dimensions=["rep"])


def test_an_undocumented_where_column_is_refused(source: DataSource) -> None:
    registry = Registry([record("net_revenue")])

    with pytest.raises(ValueError, match="not a documented column"):
        metrics(
            source,
            registry,
            metrics=["net_revenue"],
            where=[{"column": "rep", "op": "=", "value": "Ada"}],
        )


def test_an_unsupported_where_operator_is_refused(source: DataSource) -> None:
    registry = Registry([record("net_revenue")])

    with pytest.raises(ValueError, match="where operator must be one of"):
        metrics(
            source,
            registry,
            metrics=["net_revenue"],
            where=[{"column": "revenue", "op": "LIKE", "value": "1"}],
        )


def test_an_incomplete_where_entry_is_refused(source: DataSource) -> None:
    registry = Registry([record("net_revenue")])

    with pytest.raises(ValueError, match="needs column, op, and value"):
        metrics(
            source,
            registry,
            metrics=["net_revenue"],
            where=[{"column": "revenue", "op": ">"}],
        )
