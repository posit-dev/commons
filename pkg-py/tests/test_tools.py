"""Which tools an agent registers, and what each one does when it runs."""

from pathlib import Path
from typing import Annotated, Any

import pandas as pd
import pytest
from chatlas import ContentToolResult, Tool
from pydantic import Field

from commons import ContextLayer, DataSource, data_source, measure
from commons._catalog import (
    CatalogTransientError,
    Manifest,
    Relation,
    session_snapshot,
)
from commons._citations import CitationRequest
from commons._data_source import TableId
from commons._definitions import ExportRecord, Registry
from commons._handles import HandleStore
from commons._measures import as_measure
from commons._provenance import TAG_EXTRA_KEY, Tag
from commons._tools import (
    FirstTouch,
    ToolContext,
    build_commons_tools,
    catalog_searchable,
    pool_searchable,
    registry_has_metrics,
    run_sql_description,
    tool_description,
)
from tests._warehouse import FakeWarehouse

DICTIONARY = """
name: sales
description: What the shop sold.
tables:
  - name: sales
    description: One row per order line.
    columns:
      - name: revenue
        type: number
        description: Line revenue.
      - name: region
        type: string
"""


def frame() -> pd.DataFrame:
    return pd.DataFrame(
        {"revenue": [500.0, 900.0, 300.0], "region": ["EMEA", "Americas", "EMEA"]}
    )


@pytest.fixture
def plain() -> DataSource:
    return data_source(sales=frame())


@pytest.fixture
def documented(tmp_path: Path) -> DataSource:
    path = tmp_path / "data-dict.yaml"
    path.write_text(DICTIONARY, encoding="utf-8")
    return data_source(sales=frame(), dictionary=path)


def record(
    name: str = "net_revenue",
    *,
    kind: str = "metric",
    label: str | None = None,
    sql: str = "sum(revenue)",
) -> ExportRecord:
    return ExportRecord(
        name=name,
        table="sales",
        source="sales_db",
        kind=kind,
        type="number",
        expression="SUM(revenue)",
        label=label,
        description=None,
        details=None,
        columns=["revenue"],
        definitions=[],
        sql=sql,
        target="SQL(duckdb)",
        notes=[],
        mixed_grain=False,
    )


def counted() -> dict[str, Any]:
    @measure(description="Count orders in a region.")
    def order_count(
        region: Annotated[str, Field(description="Which region to count.")] = "EMEA",
    ) -> int:
        return len(frame()[frame()["region"] == region])

    found = as_measure(order_count)
    assert found is not None
    return {found.name: found}


def named(tools: list[Tool]) -> list[str]:
    return [tool.name for tool in tools]


def find(tools: list[Tool], name: str) -> Tool:
    return next(tool for tool in tools if tool.name == name)


def invoke(tool: Tool, **kwargs: Any) -> ContentToolResult:
    result = tool.func(**kwargs)
    assert isinstance(result, ContentToolResult)
    return result


def call(tool: Tool, **kwargs: Any) -> str:
    value = invoke(tool, **kwargs).value
    assert isinstance(value, str)
    return value


def parameters(tool: Tool) -> dict[str, Any]:
    schema = tool.schema["function"]["parameters"]
    assert isinstance(schema, dict)
    return schema


def searchable(source: DataSource) -> DataSource:
    source.manifest = Manifest(
        objects={
            "main.finance.orders": Relation(
                id=TableId(table="orders", schema="finance", catalog="main"),
                kind="table",
                description="Booked commercial activity.",
            )
        },
        searchable=True,
    )
    return source


# ---- registration conditions ----------------------------------------------


def test_a_bare_agent_registers_only_the_tools_every_source_earns(
    plain: DataSource,
) -> None:
    tools = build_commons_tools(ToolContext(sources={"sales_db": plain}))

    assert named(tools) == ["search_context", "describe_table", "run_sql"]


def test_measures_earn_the_pool_and_the_measure_call(plain: DataSource) -> None:
    tools = build_commons_tools(
        ToolContext(sources={"sales_db": plain}, measures=counted())
    )

    assert named(tools)[:2] == ["search_pool", "call_measure"]


def test_a_governed_metric_earns_call_metrics(plain: DataSource) -> None:
    tools = build_commons_tools(
        ToolContext(sources={"sales_db": plain}, definitions=Registry([record()]))
    )

    assert "call_metrics" in named(tools)


def test_definitions_that_are_not_metrics_do_not_earn_call_metrics(
    plain: DataSource,
) -> None:
    tools = build_commons_tools(
        ToolContext(
            sources={"sales_db": plain},
            definitions=Registry([record("emea", kind="filter", sql="region = 'x'")]),
        )
    )

    assert "call_metrics" not in named(tools)


def test_a_visible_definition_index_does_not_earn_the_pool(plain: DataSource) -> None:
    # The prompt already carries the index, so searching it would only cost a
    # round trip to confirm what the model can read.
    context = ToolContext(sources={"sales_db": plain}, definitions=Registry([record()]))

    assert not pool_searchable(context.measures, context.definitions)
    assert "search_pool" not in named(build_commons_tools(context))


def test_an_index_past_its_cap_earns_the_pool(plain: DataSource) -> None:
    overflowing = Registry(
        [record(f"metric_{index}", label="x" * 40) for index in range(200)]
    )

    assert pool_searchable({}, overflowing)
    assert "search_pool" in named(
        build_commons_tools(
            ToolContext(sources={"sales_db": plain}, definitions=overflowing)
        )
    )


def test_a_searchable_catalog_earns_the_catalog_search(plain: DataSource) -> None:
    tools = build_commons_tools(ToolContext(sources={"sales_db": searchable(plain)}))

    assert "search_catalog" in named(tools)


def test_a_source_with_no_manifest_is_not_catalog_searchable(
    plain: DataSource,
) -> None:
    assert not catalog_searchable(plain)


def test_registry_has_metrics_reads_the_kind() -> None:
    assert registry_has_metrics(Registry([record()]))
    assert not registry_has_metrics(Registry([record(kind="derived")]))
    assert not registry_has_metrics(Registry())


# ---- the source argument ---------------------------------------------------


def test_one_source_leaves_the_source_argument_out(plain: DataSource) -> None:
    tools = build_commons_tools(ToolContext(sources={"sales_db": plain}))

    assert "source" not in parameters(find(tools, "run_sql"))["properties"]


def test_several_sources_make_the_source_argument_a_required_enum(
    plain: DataSource,
) -> None:
    tools = build_commons_tools(
        ToolContext(sources={"sales_db": plain, "other": data_source(regions=frame())})
    )
    schema = parameters(find(tools, "run_sql"))

    assert schema["properties"]["source"]["enum"] == ["sales_db", "other"]
    assert "source" in schema["required"]


def test_an_unknown_source_names_the_ones_there_are(plain: DataSource) -> None:
    tools = build_commons_tools(
        ToolContext(sources={"sales_db": plain, "other": data_source(regions=frame())})
    )

    with pytest.raises(ValueError, match="Available sources: sales_db, other"):
        find(tools, "run_sql").func(sql="SELECT 1", source="nowhere")


# ---- descriptions ----------------------------------------------------------


def test_run_sql_offers_tokens_only_when_there_are_definitions() -> None:
    assert run_sql_description(Registry()) == (
        "Run a read-only SELECT query against a data source."
    )
    assert "{{table::name}}" in run_sql_description(Registry([record()]))
    assert "no registered measure" in run_sql_description(Registry(), counted())


def test_call_metrics_points_at_the_pool_only_when_there_is_one(
    plain: DataSource,
) -> None:
    alone = build_commons_tools(
        ToolContext(sources={"sales_db": plain}, definitions=Registry([record()]))
    )
    beside = build_commons_tools(
        ToolContext(
            sources={"sales_db": plain},
            definitions=Registry([record()]),
            measures=counted(),
        )
    )

    assert "come from the system prompt;" in tool_description(
        find(alone, "call_metrics")
    )
    assert "the system prompt or search_pool" in tool_description(
        find(beside, "call_metrics")
    )


def test_the_pool_names_the_kinds_it_holds(plain: DataSource) -> None:
    tools = build_commons_tools(
        ToolContext(
            sources={"sales_db": plain},
            measures=counted(),
            definitions=Registry([record()]),
        )
    )

    assert tool_description(find(tools, "search_pool")).startswith(
        "Search the semantic layer's trusted calculations: measures (run with "
        "call_measure) and governed definitions (apply as {{name}} tokens in "
        "run_sql)."
    )


def test_every_tool_is_declared_read_only(plain: DataSource) -> None:
    tools = build_commons_tools(
        ToolContext(
            sources={"sales_db": searchable(plain)},
            measures=counted(),
            definitions=Registry([record()]),
        )
    )

    assert all(tool.annotations == {"readOnlyHint": True} for tool in tools)


# ---- search_context --------------------------------------------------------


def test_search_context_says_when_there_is_no_layer(plain: DataSource) -> None:
    tools = build_commons_tools(ToolContext(sources={"sales_db": plain}))

    assert call(find(tools, "search_context"), query="refunds") == (
        "No context layer is configured for this agent."
    )


def test_search_context_returns_the_chunks_it_finds(plain: DataSource) -> None:
    layer = ContextLayer(["# Refunds\n\nA refund reverses an order line."])
    tools = build_commons_tools(
        ToolContext(sources={"sales_db": plain}, context_layer=layer)
    )

    assert "refund reverses" in call(find(tools, "search_context"), query="refund")


def test_search_context_says_when_nothing_matches(plain: DataSource) -> None:
    layer = ContextLayer(["# Refunds\n\nA refund reverses an order line."])
    tools = build_commons_tools(
        ToolContext(sources={"sales_db": plain}, context_layer=layer)
    )

    assert call(find(tools, "search_context"), query="zzzz") == (
        'No context found for "zzzz".'
    )


def test_a_context_hit_carries_the_turn_citation_request(plain: DataSource) -> None:
    layer = ContextLayer(["# Refunds\n\nA refund reverses an order line."])
    request = CitationRequest()
    tools = build_commons_tools(
        ToolContext(
            sources={"sales_db": plain}, context_layer=layer, citation_request=request
        )
    )

    body = call(find(tools, "search_context"), query="refund")

    assert request.requested
    assert body.endswith(request.reminder)


# ---- describe_table --------------------------------------------------------


def test_describe_table_shows_columns_and_sample_rows(plain: DataSource) -> None:
    tools = build_commons_tools(ToolContext(sources={"sales_db": plain}))

    body = call(find(tools, "describe_table"), table="sales")

    assert "Columns of `sales`:" in body
    assert "| revenue | DOUBLE |" in body
    assert "Sample rows:" in body
    assert "| 500.0 | EMEA |" in body


def test_describe_table_delivers_the_dictionary_entry(documented: DataSource) -> None:
    tools = build_commons_tools(ToolContext(sources={"sales_db": documented}))

    body = call(find(tools, "describe_table"), table="sales")

    assert "One row per order line." in body
    assert "- revenue (number): Line revenue." in body


def test_describe_table_marks_the_table_as_touched(documented: DataSource) -> None:
    context = ToolContext(sources={"sales_db": documented})
    tools = build_commons_tools(context)

    call(find(tools, "describe_table"), table="sales")

    assert context.first_touch.touched("sales_db", "sales")


def test_an_unknown_table_names_the_ones_there_are(plain: DataSource) -> None:
    tools = build_commons_tools(ToolContext(sources={"sales_db": plain}))

    with pytest.raises(ValueError, match="Available tables: sales"):
        find(tools, "describe_table").func(table="nowhere")


# ---- run_sql ---------------------------------------------------------------


def test_run_sql_returns_the_rows_as_a_table(plain: DataSource) -> None:
    tools = build_commons_tools(ToolContext(sources={"sales_db": plain}))

    body = call(find(tools, "run_sql"), sql="SELECT region FROM sales LIMIT 1")

    assert body.startswith("| region |\n|---|\n| EMEA |")


def test_run_sql_carries_the_b_provenance_tag(plain: DataSource) -> None:
    tools = build_commons_tools(ToolContext(sources={"sales_db": plain}))

    result = invoke(find(tools, "run_sql"), sql="SELECT 1 AS n")

    assert result.extra is not None
    assert result.extra[TAG_EXTRA_KEY] is Tag.B


def test_run_sql_expands_a_governed_token_and_reports_it(plain: DataSource) -> None:
    context = ToolContext(sources={"sales_db": plain}, definitions=Registry([record()]))
    tools = build_commons_tools(context)

    body = call(
        find(tools, "run_sql"), sql="SELECT {{net_revenue}} AS total FROM sales"
    )

    assert "| 1700.0 |" in body
    assert "Applied governed definitions:" in body


def test_a_result_is_reachable_as_a_handle(plain: DataSource) -> None:
    context = ToolContext(sources={"sales_db": plain}, handles=HandleStore())
    tools = build_commons_tools(context)

    body = call(find(tools, "run_sql"), sql="SELECT 1 AS n")

    assert "Available to `run_python` as `r1`." in body
    assert context.handles.ids() == ["r1"]


def test_a_read_only_guard_still_stands_in_front_of_run_sql(
    plain: DataSource,
) -> None:
    tools = build_commons_tools(ToolContext(sources={"sales_db": plain}))

    with pytest.raises(ValueError, match="disallowed operation"):
        find(tools, "run_sql").func(sql="DROP TABLE sales")


# ---- the first-touch tracker ------------------------------------------------


def test_a_query_delivers_the_entry_for_a_table_it_touches(
    documented: DataSource,
) -> None:
    context = ToolContext(sources={"sales_db": documented})
    tools = build_commons_tools(context)

    body = call(find(tools, "run_sql"), sql="SELECT region FROM sales")

    assert "Dictionary entry for `sales`:" in body
    assert context.first_touch.touched("sales_db", "sales")


def test_the_entry_is_delivered_once_however_the_table_was_reached(
    documented: DataSource,
) -> None:
    context = ToolContext(sources={"sales_db": documented})
    tools = build_commons_tools(context)

    call(find(tools, "describe_table"), table="sales")
    body = call(find(tools, "run_sql"), sql="SELECT region FROM sales")

    assert "Dictionary entry for `sales`:" not in body


def test_a_query_naming_no_documented_table_delivers_nothing(
    documented: DataSource,
) -> None:
    context = ToolContext(sources={"sales_db": documented})
    tools = build_commons_tools(context)

    body = call(find(tools, "run_sql"), sql="SELECT 1 AS n")

    assert "Dictionary entry" not in body
    assert not context.first_touch.touched("sales_db", "sales")


def test_the_tracker_keeps_two_sources_apart() -> None:
    tracker = FirstTouch()
    tracker.mark("sales_db", "sales")

    assert tracker.touched("sales_db", "sales")
    assert not tracker.touched("other", "sales")


# ---- call_measure ----------------------------------------------------------


def test_call_measure_runs_the_measure(plain: DataSource) -> None:
    tools = build_commons_tools(
        ToolContext(sources={"sales_db": plain}, measures=counted())
    )

    body = call(find(tools, "call_measure"), name="order_count", arguments="{}")

    assert body.startswith("2")


def test_call_measure_validates_the_arguments_it_is_given(plain: DataSource) -> None:
    tools = build_commons_tools(
        ToolContext(sources={"sales_db": plain}, measures=counted())
    )

    with pytest.raises(Exception, match="nope"):
        find(tools, "call_measure").func(name="order_count", arguments='{"nope": 1}')


def test_call_measure_carries_the_a_provenance_tag(plain: DataSource) -> None:
    tools = build_commons_tools(
        ToolContext(sources={"sales_db": plain}, measures=counted())
    )

    result = invoke(find(tools, "call_measure"), name="order_count")

    assert result.extra is not None
    assert result.extra[TAG_EXTRA_KEY] is Tag.A


def test_an_unknown_measure_names_the_registered_ones(plain: DataSource) -> None:
    tools = build_commons_tools(
        ToolContext(sources={"sales_db": plain}, measures=counted())
    )

    with pytest.raises(ValueError, match="Registered measures: order_count"):
        find(tools, "call_measure").func(name="nowhere")


def test_an_injected_argument_comes_from_the_agent(plain: DataSource) -> None:
    from commons import Injected

    @measure(description="Count rows in a source.")
    def row_count(sales_db: Injected[Any]) -> int:
        return len(sales_db.query("SELECT 1 AS n FROM sales"))

    found = as_measure(row_count)
    assert found is not None
    tools = build_commons_tools(
        ToolContext(
            sources={"sales_db": plain},
            measures={found.name: found},
            injections={"row_count": {"sales_db": plain}},
        )
    )

    assert call(find(tools, "call_measure"), name="row_count").startswith("3")


# ---- search_catalog ---------------------------------------------------------


def test_search_catalog_finds_a_relation(plain: DataSource) -> None:
    tools = build_commons_tools(ToolContext(sources={"sales_db": searchable(plain)}))

    body = call(find(tools, "search_catalog"), query="commercial bookings")

    assert body == ("- `main.finance.orders` (table): Booked commercial activity.")


def test_search_catalog_says_when_nothing_matches(plain: DataSource) -> None:
    tools = build_commons_tools(ToolContext(sources={"sales_db": searchable(plain)}))

    assert call(find(tools, "search_catalog"), query="zzzz") == (
        'No catalog objects found for "zzzz".'
    )


def test_search_catalog_filters_by_kind(plain: DataSource) -> None:
    tools = build_commons_tools(ToolContext(sources={"sales_db": searchable(plain)}))

    assert "No catalog objects" in call(
        find(tools, "search_catalog"), query="orders", kinds=["view"]
    )


def _warehouse_source(backend: Any) -> DataSource:
    return DataSource(
        backend=backend,
        tables=[],
        session=session_snapshot(backend),
        manifest=Manifest(
            objects={
                "ANALYTICS.PUBLIC.SALES": Relation(
                    id=TableId(catalog="ANALYTICS", schema="PUBLIC", table="SALES"),
                    kind="table",
                    description="Booked sales activity.",
                )
            },
            searchable=True,
        ),
    )


def test_a_relation_the_principal_may_not_read_is_left_out() -> None:
    backend = FakeWarehouse()
    backend.refuse = {"SALES"}
    tools = build_commons_tools(
        ToolContext(sources={"warehouse": _warehouse_source(backend)})
    )

    assert call(find(tools, "search_catalog"), query="sales") == (
        'No catalog objects found for "sales".'
    )


def test_a_probe_that_could_not_be_read_is_raised_rather_than_hidden() -> None:
    # A refusal is an answer; a timeout is not, and swallowing it would
    # report a relation the agent has as one it does not.
    class TimingOut(FakeWarehouse):
        def _probe(self, sql: str) -> list[dict[str, Any]]:
            raise TimeoutError("the warehouse timed out")

    tools = build_commons_tools(
        ToolContext(sources={"warehouse": _warehouse_source(TimingOut())})
    )

    with pytest.raises(CatalogTransientError):
        find(tools, "search_catalog").func(query="sales")


def test_search_pool_reaches_the_pool(plain: DataSource) -> None:
    tools = build_commons_tools(
        ToolContext(sources={"sales_db": plain}, measures=counted())
    )

    assert "### order_count" in call(find(tools, "search_pool"), query="count orders")


def test_call_metrics_runs_the_governed_query(documented: DataSource) -> None:
    tools = build_commons_tools(
        ToolContext(sources={"sales_db": documented}, definitions=Registry([record()]))
    )

    body = call(
        find(tools, "call_metrics"), metrics=["net_revenue"], dimensions=["region"]
    )

    assert "| EMEA | 800.0 |" in body


def test_describe_table_loads_a_pin_before_reading_its_schema(
    tmp_path: Path,
) -> None:
    # The sample query is what loads the pin, so the column read that follows
    # it has a table to read from.
    pins = pytest.importorskip("pins")
    board = pins.board_folder(str(tmp_path))
    board.pin_write(frame(), "sales-pin", type="csv")
    source = data_source(board, tables={"sales": "sales-pin"})
    tools = build_commons_tools(ToolContext(sources={"sales_db": source}))

    body = call(find(tools, "describe_table"), table="sales")

    assert "| revenue | DOUBLE |" in body
    assert "| 500.0 | EMEA |" in body
