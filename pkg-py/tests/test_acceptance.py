"""M5's acceptance bar: one agent, all three layers, through the public API.

The pieces underneath have their own tests. What this file asserts is that
they agree once assembled: a question the measures cover comes back verified,
a question they do not comes back untrusted or cited, and a citation reaches
the consumer as server-rendered HTML rather than as the model's own markup.

The conversation is scripted rather than answered by a live model, as the R
suite's agent tests are. That makes this a regression guard on the assembly,
not evidence that a real model picks the right tool; kata `j9dq` under M9
holds the live-model question for both packages.
"""

from pathlib import Path
from typing import Annotated, Any

import pandas as pd
import pytest
from chatlas import ContentToolRequest, ContentToolResult
from chatlas.types import ContentText
from pydantic import Field

import commons
from commons import (
    Commons,
    Tag,
    context_layer,
    data_source,
    measure,
    semantic_layer,
)
from commons._provenance import provenance_aside

from ._provider import scripted_chat, text

DICTIONARY = """
name: sales
description: What the shop sold.
tables:
  - name: sales
    description: One row per order line.
    columns:
      - name: revenue
        type: number
        description: Line revenue, in dollars.
      - name: region
        type: string
        description: Sales region the order line belongs to.
"""

# Prose no measure covers, so the only way to it is the context layer.
QUOTE = "Bookings are recognised in the region the order shipped from."


def frame() -> pd.DataFrame:
    return pd.DataFrame(
        {"revenue": [500.0, 900.0, 300.0], "region": ["EMEA", "Americas", "EMEA"]}
    )


@pytest.fixture
def agent_layers(tmp_path: Path) -> dict[str, Any]:
    """A documented DuckDB source, a measure over it, and prose beside it."""
    dictionary = tmp_path / "data-dict.yaml"
    dictionary.write_text(DICTIONARY, encoding="utf-8")
    notes = tmp_path / "policy.md"
    notes.write_text(QUOTE, encoding="utf-8")

    @measure(description="Total revenue for one region.")
    def region_revenue(
        region: Annotated[str, Field(description="Which region to total.")] = "EMEA",
    ) -> float:
        rows = frame()
        return float(rows[rows["region"] == region]["revenue"].sum())

    return {
        "data_sources": data_source(sales=frame(), dictionary=dictionary),
        "semantic_layer": semantic_layer(region_revenue),
        "context_layer": context_layer(files=[notes]),
    }


def agent(*responses: Any, **layers: Any) -> Commons:
    return Commons(scripted_chat(responses), **layers)


def call(tool: str, /, **arguments: Any) -> list[Any]:
    return [ContentToolRequest(id=f"call-{tool}", name=tool, arguments=arguments)]


async def stream(built: Commons, question: str) -> list[Any]:
    return [chunk async for chunk in await built.stream_async(question)]


def tool_results(built: Commons) -> list[str]:
    """Which tools the conversation actually ran, in order."""
    return [
        content.name
        for turn in built.get_turns()
        for content in turn.contents
        if isinstance(content, ContentToolResult)
    ]


# ---- the public surface ----------------------------------------------------


def test_the_package_exports_the_agent() -> None:
    assert commons.Commons is Commons
    assert commons.Tag is Tag


def test_every_exported_name_resolves() -> None:
    for name in commons.__all__:
        assert getattr(commons, name, None) is not None, name


# ---- the acceptance bar ----------------------------------------------------


async def test_a_measure_covered_question_comes_back_verified(
    agent_layers: dict[str, Any],
) -> None:
    built = agent(
        call("call_measure", name="region_revenue", arguments='{"region": "EMEA"}'),
        text("EMEA revenue is $800."),
        **agent_layers,
    )

    streamed = await stream(built, "What is EMEA revenue?")

    assert streamed[-1] == provenance_aside(Tag.A)


async def test_a_question_the_measures_do_not_cover_comes_back_untrusted(
    agent_layers: dict[str, Any],
) -> None:
    built = agent(
        call("run_sql", sql="SELECT count(*) AS n FROM sales"),
        text("Three order lines."),
        **agent_layers,
    )

    streamed = await stream(built, "How many order lines are there?")

    assert streamed[-1] == provenance_aside(Tag.C)


async def test_a_cited_fallback_answer_renders_its_citation_server_side(
    agent_layers: dict[str, Any],
) -> None:
    built = agent(
        call("search_context", query="revenue recognition"),
        [
            ContentText(
                text="Shipped-from region.\n\n<commons-citation>\n\n"
                f"The policy says so.\n\n> {QUOTE}\n\n</commons-citation>"
            )
        ],
        **agent_layers,
    )

    streamed = "".join(
        chunk
        for chunk in await stream(built, "Which region books revenue?")
        if isinstance(chunk, str)
    )

    # Without this the rest passes on an answer that reached no tool at all,
    # since an untagged answer has no marker to look for either.
    assert tool_results(built) == ["search_context"]
    assert "<commons-citation>" not in streamed
    assert "<shiny-aside" in streamed
    assert QUOTE in streamed
    # The citation's own aside says the answer is cited, so no second marker.
    assert provenance_aside(Tag.C) not in streamed
