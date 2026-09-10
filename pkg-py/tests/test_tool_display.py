"""How a tool result asks to be shown, read back through shinychat's own reader.

`extra["display"]` is a plain dictionary rather than a `ToolResultDisplay`,
so that core can describe a result's presentation without importing
shinychat. These tests read it back through `get_tool_result_display()`,
which is the code that consumes it, rather than asserting on the dictionary.
"""

from typing import Annotated, Any

import pandas as pd
import pytest
from chatlas import ContentToolRequest, ContentToolResult, Tool
from htmltools import TagList
from pydantic import Field

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


def markup(child: Any) -> str:
    """Any tag child rendered, since a display field may be either shape."""
    return TagList(child).get_html_string()


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


# ---- a measure that builds its own result ---------------------------------


def displaying(display: dict[str, Any], value: Any = "41", data: Any = None) -> Any:
    """A measure that returns a finished tool result, as a measure may."""

    @measure(description="Revenue, already drawn.")
    def revenue() -> ContentToolResult:
        return ContentToolResult(
            value=value, extra={"display": display, "data": data}
        )

    found = as_measure(revenue)
    assert found is not None
    return {found.name: found}


def measure_result(**kwargs: Any) -> ContentToolResult:
    built = tools(measures=displaying(**kwargs))
    result = find(built, "call_measure").func(name="revenue", arguments="{}")
    assert isinstance(result, ContentToolResult)
    return result


def test_a_measures_own_result_still_carries_the_a_tag() -> None:
    result = measure_result(display={"markdown": "**41**"})

    assert result.extra[TAG_EXTRA_KEY] is Tag.A


def test_a_measures_own_result_gets_the_default_title() -> None:
    result = measure_result(display={"markdown": "**41**"})

    assert shown(result).title == "Ran a trusted calculation"


def test_a_measure_keeps_the_title_it_chose() -> None:
    result = measure_result(display={"title": "Drew the revenue curve"})

    assert shown(result).title == "Drew the revenue curve"


def test_a_visible_result_tells_the_model_not_to_repeat_it() -> None:
    result = measure_result(display={"markdown": "**41**"})

    assert "already visible to the user" in str(result.value)


def test_a_result_the_user_cannot_see_carries_no_such_note() -> None:
    result = measure_result(display={"title": "Counted the orders"})

    assert "already visible" not in str(result.value)


def test_a_measures_data_is_reachable_as_a_handle() -> None:
    result = measure_result(display={"title": "Counted"}, data=[1, 2, 3])

    assert "r1" in str(result.value)


def test_the_data_does_not_travel_to_the_model_as_metadata() -> None:
    """`data` is how a measure hands commons the values behind its display."""
    result = measure_result(display={"title": "Counted"}, data=[1, 2, 3])

    assert "data" not in result.extra


def test_a_measure_may_use_shinychats_own_display_class() -> None:
    """shinychat's docs tell tool authors to build a `ToolResultDisplay`."""
    result = measure_result(display=ToolResultDisplay(markdown="**41**"))

    assert shown(result).title == "Ran a trusted calculation"
    assert "already visible to the user" in str(result.value)


def test_a_measure_cannot_turn_the_request_back_on() -> None:
    """The arguments commons sends a tool are its own plumbing."""
    result = measure_result(display={"markdown": "**41**", "show_request": True})

    assert shown(result).show_request is False


def test_authored_html_is_framed_inside_the_measure_card() -> None:
    """Custom HTML sits in the standard card, after metadata and arguments."""

    @measure(description="Summarize adverse events.", title="Adverse events")
    def events(
        population: Annotated[str, Field(description="Analysis population.")],
    ) -> ContentToolResult:
        return ContentToolResult(
            value="Headache: 7",
            extra={
                "display": {
                    "html": "<table><tr><td>Headache</td></tr></table>",
                    "open": True,
                    "full_screen": True,
                }
            },
        )

    found = as_measure(events)
    assert found is not None
    built = tools(measures={found.name: found})

    result = find(built, "call_measure").func(
        name="events", arguments='{"population": "ITT"}'
    )
    assert isinstance(result, ContentToolResult)
    display = shown(result)
    html = markup(display.html)

    assert "commons-measure-display" in html
    assert "Adverse events" in html
    assert "Summarize adverse events." in html
    assert "Population:" in html
    assert "ITT" in html
    assert "<strong>Result</strong>" in html
    assert "commons-measure-result-value-authored" in html
    # Authored markup is rendered, not escaped.
    assert "<table>" in html
    assert display.open is True
    assert display.full_screen is True
    assert display.show_request is False


def test_authored_html_keeps_the_dependencies_attached_to_it() -> None:
    from htmltools import HTMLDependency, TagList, tags
    from htmltools import Tag as HtmlTag

    dependency = HTMLDependency(
        "measure-table",
        "1.0.0",
        source={"href": "measure-table"},
        stylesheet={"href": "table.css"},
    )
    table = TagList(tags.table(tags.tr(tags.td("Headache"))), dependency)

    display = shown(measure_result(display={"html": table}))

    assert isinstance(display.html, HtmlTag)
    assert [d.name for d in display.html.get_dependencies()] == ["measure-table"]


def test_authored_html_on_shinychats_display_class_is_framed() -> None:
    result = measure_result(display=ToolResultDisplay(html="<p>custom</p>"))

    display = shown(result)

    assert "commons-measure-result-value-authored" in markup(display.html)
    assert display.show_request is False


def test_a_long_measure_description_can_be_expanded() -> None:
    @measure(description="A detailed description of the measure. " * 8)
    def orders() -> int:
        return 1

    found = as_measure(orders)
    assert found is not None
    built = tools(measures={found.name: found})

    html = markup(ran(built, "call_measure", name="orders", arguments="{}").html)

    assert "commons-measure-description-summary" in html
    assert "commons-measure-details-more" in html
    assert "commons-measure-details-less" in html


# ---- the card behind a trusted calculation --------------------------------


def sourced() -> dict[str, Any]:
    @measure(
        description="Count orders in a region.",
        provenance=["https://example.com/handbook"],
    )
    def order_count(
        region: Annotated[str, Field(description="Which region.")] = "EMEA",
    ) -> int:
        return 2

    found = as_measure(order_count)
    assert found is not None
    return {found.name: found}


def test_a_measure_result_draws_the_arguments_it_ran_with() -> None:
    built = tools(measures=sourced())

    display = ran(built, "call_measure", name="order_count", arguments='{"region": "AMER"}')

    assert display.html is not None
    assert "AMER" in markup(display.html)


def test_a_measure_result_names_the_measure_that_ran() -> None:
    built = tools(measures=sourced())

    display = ran(built, "call_measure", name="order_count", arguments="{}")

    assert display.html is not None
    assert "Count orders in a region." in markup(display.html)


def test_a_measures_provenance_becomes_a_source_link() -> None:
    built = tools(measures=sourced())

    display = ran(built, "call_measure", name="order_count", arguments="{}")

    assert display.footer is not None
    assert "https://example.com/handbook" in markup(display.footer)


def test_a_metrics_result_draws_the_metrics_it_computed() -> None:
    built = build_commons_tools(
        ToolContext(
            sources={"sales_db": source()}, definitions=Registry([_net_revenue()])
        )
    )

    display = ran(built, "call_metrics", metrics=["net_revenue"])

    assert display.html is not None
    assert "net_revenue" in markup(display.html)


def test_a_metrics_result_shows_the_query_it_ran() -> None:
    built = build_commons_tools(
        ToolContext(
            sources={"sales_db": source()}, definitions=Registry([_net_revenue()])
        )
    )

    display = ran(built, "call_metrics", metrics=["net_revenue"])

    assert display.markdown is not None
    assert display.markdown.startswith("```sql\n")


def failing(display: dict[str, Any]) -> Any:
    """A measure whose own result reports that the calculation failed."""

    @measure(description="Revenue, when it can be had.")
    def revenue() -> ContentToolResult:
        return ContentToolResult(
            value=None, error=RuntimeError("no rows"), extra={"display": display}
        )

    found = as_measure(revenue)
    assert found is not None
    return {found.name: found}


def test_a_failed_calculation_is_not_trusted() -> None:
    """A tag here would let a failure promote the answer that follows it."""
    built = tools(measures=failing({"markdown": "**no rows**"}))

    result = find(built, "call_measure").func(name="revenue", arguments="{}")

    assert isinstance(result, ContentToolResult)
    assert TAG_EXTRA_KEY not in (result.extra or {})


def test_a_failed_calculation_keeps_the_error_the_measure_reported() -> None:
    built = tools(measures=failing({"markdown": "**no rows**"}))

    result = find(built, "call_measure").func(name="revenue", arguments="{}")

    assert isinstance(result, ContentToolResult)
    assert result.value is None


def test_a_display_that_names_no_title_still_gets_the_default() -> None:
    result = measure_result(display={"title": None, "markdown": "**41**"})

    assert shown(result).title == "Ran a trusted calculation"


def displaying_sourced(display: dict[str, Any]) -> Any:
    """A measure that draws its own result and records where it came from."""

    @measure(
        description="Revenue, already drawn.",
        provenance=["https://example.com/handbook"],
    )
    def revenue() -> ContentToolResult:
        return ContentToolResult(value="41", extra={"display": display})

    found = as_measure(revenue)
    assert found is not None
    return {found.name: found}


def test_a_measures_own_result_still_links_back_to_its_source() -> None:
    built = tools(measures=displaying_sourced({"markdown": "**41**"}))

    result = find(built, "call_measure").func(name="revenue", arguments="{}")

    assert isinstance(result, ContentToolResult)
    assert "https://example.com/handbook" in markup(shown(result).footer)


def test_a_measure_keeps_the_footer_it_chose() -> None:
    built = tools(measures=displaying_sourced({"footer": "Ask the finance team."}))

    result = find(built, "call_measure").func(name="revenue", arguments="{}")

    assert isinstance(result, ContentToolResult)
    assert "Ask the finance team." in markup(shown(result).footer)


def test_a_failed_calculation_cannot_claim_the_trusted_tag_itself() -> None:
    """The tag is commons' to set, so a measure does not get to keep one."""

    @measure(description="Revenue, when it can be had.")
    def revenue() -> ContentToolResult:
        return ContentToolResult(
            value=None,
            error=RuntimeError("no rows"),
            extra={TAG_EXTRA_KEY: Tag.A, "display": {"markdown": "**no rows**"}},
        )

    found = as_measure(revenue)
    assert found is not None
    built = tools(measures={found.name: found})

    result = find(built, "call_measure").func(name="revenue", arguments="{}")

    assert isinstance(result, ContentToolResult)
    assert TAG_EXTRA_KEY not in (result.extra or {})


def test_a_metrics_card_shows_only_the_arguments_the_model_gave() -> None:
    built = build_commons_tools(
        ToolContext(
            sources={"sales_db": source()}, definitions=Registry([_net_revenue()])
        )
    )

    display = ran(built, "call_metrics", metrics=["net_revenue"])

    assert "Dimensions" not in markup(display.html)
