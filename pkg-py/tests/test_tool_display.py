"""How a tool result asks to be shown, read back through shinychat's own reader.

`extra["display"]` is a plain dictionary rather than a `ToolResultDisplay`,
so that core can describe a result's presentation without importing
shinychat. These tests read it back through `get_tool_result_display()`,
which is the code that consumes it, rather than asserting on the dictionary.
"""

from typing import Any

import pandas as pd
import pytest
from chatlas import ContentToolRequest, ContentToolResult, Tool

from commons import DataSource, data_source, measure
from commons._citations import tool_result
from commons._definitions import ExportRecord, Registry
from commons._measures import as_measure
from commons._provenance import TAG_EXTRA_KEY, Tag
from commons._tools import ToolContext, build_commons_tools

pytest.importorskip("shinychat")

# From the private module rather than `shinychat.types`, whose public name
# resolves to an import-error stub when chatlas is absent.
from shinychat._chat_normalize_chatlas import (
    ToolResultDisplay,
    get_tool_result_display,
)


def shown(result: ContentToolResult) -> ToolResultDisplay:
    """The display shinychat builds for `result`, as it would when rendering."""
    request = ContentToolRequest(id="1", name="run_sql", arguments={})
    return get_tool_result_display(result, request)


def test_a_result_with_no_title_asks_for_nothing() -> None:
    assert shown(tool_result("6 rows")).title is None


def test_a_title_reaches_the_reader() -> None:
    result = tool_result("chunks", title="Searched context")
    assert shown(result).title == "Searched context"


def test_a_tag_stays_out_of_the_title() -> None:
    """The tag is provenance the reader classifies by, not a caption.

    R has a `show_tag` argument that would append "SQL query (B)", but every
    call site passes `show_tag = FALSE`, so no R title carries one either.
    """
    result = tool_result("6 rows", title="Retrieved data", tag=Tag.B)
    assert shown(result).title == "Retrieved data"


def test_a_display_does_not_cost_a_result_its_tag() -> None:
    result = tool_result("41", title="Ran a trusted calculation", tag=Tag.A)
    assert result.extra[TAG_EXTRA_KEY] is Tag.A


def test_markdown_is_what_the_reader_sees_in_the_card() -> None:
    result = tool_result("6 rows", title="Retrieved data", markdown="| a |\n|---|")
    assert shown(result).markdown == "| a |\n|---|"


# ---- the titles a reader sees ---------------------------------------------


def source() -> DataSource:
    return data_source(
        sales=pd.DataFrame({"revenue": [500.0, 900.0], "region": ["EMEA", "AMER"]})
    )


def tools(**kwargs: Any) -> list[Tool]:
    return build_commons_tools(ToolContext(sources={"sales_db": source()}, **kwargs))


def find(built: list[Tool], name: str) -> Tool:
    return next(tool for tool in built if tool.name == name)


def ran(built: list[Tool], tool: str, **kwargs: Any) -> ToolResultDisplay:
    result = find(built, tool).func(**kwargs)
    assert isinstance(result, ContentToolResult)
    return shown(result)


def _net_revenue() -> ExportRecord:
    return ExportRecord(
        name="net_revenue",
        table="sales",
        source="sales_db",
        kind="metric",
        type="number",
        expression="SUM(revenue)",
        label=None,
        description=None,
        details=None,
        columns=["revenue"],
        definitions=[],
        sql="sum(revenue)",
        target="SQL(duckdb)",
        notes=[],
        mixed_grain=False,
    )


def measures() -> dict[str, Any]:
    @measure(description="Count orders in a region.")
    def order_count() -> int:
        return 2

    found = as_measure(order_count)
    assert found is not None
    return {found.name: found}


@pytest.mark.parametrize(
    ("name", "kwargs", "title"),
    [
        ("run_sql", {"sql": "SELECT 1 AS n"}, "Retrieved data"),
        ("describe_table", {"table": "sales"}, "Inspected a table"),
    ],
)
def test_a_settled_result_is_titled_in_the_past_tense(
    name: str, kwargs: dict[str, Any], title: str
) -> None:
    assert ran(tools(), name, **kwargs).title == title


def test_a_measure_result_says_the_calculation_was_trusted() -> None:
    built = tools(measures=measures())

    display = ran(built, "call_measure", name="order_count", arguments="{}")

    assert display.title == "Ran a trusted calculation"


def test_a_pool_search_is_titled_for_what_it_searched() -> None:
    built = tools(measures=measures())

    assert ran(built, "search_pool", query="orders").title == (
        "Searched for a trusted calculation"
    )


def test_a_running_tool_is_titled_in_the_present_tense() -> None:
    """shinychat shows the definition title until the result arrives."""
    annotations = find(tools(), "run_sql").annotations

    assert annotations is not None
    assert annotations["title"] == "Retrieving data"


def test_a_metrics_result_says_the_calculation_was_trusted() -> None:
    built = build_commons_tools(
        ToolContext(
            sources={"sales_db": source()},
            definitions=Registry([_net_revenue()]),
        )
    )

    display = ran(built, "call_metrics", metrics=["net_revenue"])

    assert display.title == "Ran a trusted calculation"
