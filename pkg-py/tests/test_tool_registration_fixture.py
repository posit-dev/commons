"""The tool registration and description contract both packages consume.

The R suite runs the same cases from the same file. See tests/shared/README.md.
"""

from typing import Any

import pandas as pd
import pytest
from chatlas import Tool

from commons import DataSource, data_source, measure
from commons._catalog import Manifest, Relation
from commons._definitions import ExportRecord, Registry
from commons._measures import Measure, as_measure
from commons._tools import ToolContext, build_commons_tools, tool_description

from ._shared import load_shared_fixture

SPEC = load_shared_fixture("tool-registration")
SHAPES = SPEC["shapes"]["values"]
EXECUTION_TOOLS = set(SPEC["execution_tools"])


def cases(section: str) -> list[dict[str, Any]]:
    # An empty section would collect zero cases and the runner would pass.
    found = SPEC[section]["cases"]
    assert found, section
    return found


def _measure(spec: dict[str, Any]) -> Measure:
    @measure(name=spec["name"], description=spec["description"])
    def fixture_measure() -> int:
        return 0

    found = as_measure(fixture_measure)
    assert found is not None
    return found


def _records(spec: dict[str, Any], source: str) -> list[ExportRecord]:
    names = (
        [f"{spec['name']}{index}" for index in range(1, spec["count"] + 1)]
        if "count" in spec
        else [spec["name"]]
    )
    return [
        ExportRecord(
            name=name,
            table=spec["table"],
            source=source,
            kind=spec["kind"],
            type="number",
            expression="SUM(revenue)",
            label=spec.get("label"),
            description=None,
            details=None,
            columns=["revenue"],
            definitions=[],
            sql="sum(revenue)",
            target="SQL(duckdb)",
            notes=[],
            mixed_grain=False,
        )
        for name in names
    ]


def _source(searchable: bool) -> DataSource:
    source = data_source(sales=pd.DataFrame({"revenue": [500.0], "region": ["EMEA"]}))
    if searchable:
        source.manifest = Manifest(
            objects={
                "sales": Relation(
                    id=source.table_ids["sales"],
                    kind="table",
                    description="Booked sales activity.",
                )
            },
            searchable=True,
        )
    return source


def _tools(shape_name: str) -> list[Tool]:
    shape = SHAPES[shape_name]
    broad = set(shape["catalog_searchable"])
    sources = {name: _source(name in broad) for name in shape["sources"]}
    first = shape["sources"][0]
    return build_commons_tools(
        ToolContext(
            sources=sources,
            measures={spec["name"]: _measure(spec) for spec in shape["measures"]},
            definitions=Registry(
                [
                    record
                    for spec in shape["definitions"]
                    for record in _records(spec, first)
                ]
            ),
        )
    )


def registered(shape_name: str) -> list[str]:
    """The tool names to compare, with each package's execution tool dropped.

    `run_python` is built by its own owner rather than by
    `build_commons_tools()`, so it is never in this list; the filter is what
    lets the R suite compare the same expectation while registering `run_r`.
    """
    return [
        tool.name for tool in _tools(shape_name) if tool.name not in EXECUTION_TOOLS
    ]


@pytest.mark.parametrize("case", cases("registration"), ids=lambda c: c["name"])
def test_registration_matches_the_shared_contract(case: dict[str, Any]) -> None:
    assert registered(case["shape"]) == case["tools"]


@pytest.mark.parametrize("case", cases("descriptions"), ids=lambda c: c["name"])
def test_descriptions_match_the_shared_contract(case: dict[str, Any]) -> None:
    found = {tool.name: tool for tool in _tools(case["shape"])}

    assert tool_description(found[case["tool"]]) == case["text"]


def test_every_shape_is_used() -> None:
    used = {
        case["shape"]
        for section in ("registration", "descriptions")
        for case in cases(section)
    }

    assert used == set(SHAPES)


def test_the_cases_pin_both_sides_of_every_condition() -> None:
    # A fixture where a tool is always registered would pass against an
    # implementation that registers it unconditionally.
    gated = {"search_pool", "call_measure", "call_metrics", "search_catalog"}
    registrations = [set(case["tools"]) for case in cases("registration")]

    for tool in gated:
        assert any(tool in tools for tools in registrations), tool
        assert any(tool not in tools for tools in registrations), tool
