"""The semantic model registry and resolution contract both packages consume.

The R suite runs the same cases from the same file. See tests/shared/README.md.
"""

from dataclasses import asdict
from typing import Any

import pytest

from commons._definitions import ExportRecord
from commons._semantic_models import (
    member_key,
    metric_origin,
    resolve_filters,
    resolve_members,
    semantic_registry,
)

from ._semantic_fixture import assert_fixture_error, fixture_source
from ._shared import load_shared_fixture

SPEC = load_shared_fixture("semantic-models")


def cases(section: str) -> list[dict[str, Any]]:
    # An empty section would collect zero cases and the runner would pass.
    found = SPEC[section]["cases"]
    assert found, section
    return found


def _members():
    source = fixture_source(SPEC["models"]["values"])
    return semantic_registry({"warehouse": source}).members


def _definition(spec: dict[str, Any]) -> ExportRecord:
    return ExportRecord(
        name=spec["name"],
        table=spec["table"],
        source="warehouse",
        kind=spec["kind"],
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


def test_registry_lists_the_members() -> None:
    expected = SPEC["registry"]["members"]
    assert expected
    assert [asdict(row) for row in _members()] == expected


@pytest.mark.parametrize(
    "case", cases("resolution"), ids=lambda c: f"{c['kind']}-{','.join(c['names'])}"
)
def test_resolution(case: dict[str, Any]) -> None:
    members = _members()

    def resolve():
        if case["kind"] == "filter":
            return resolve_filters(case["names"], members)
        return resolve_members(case["names"], members, case["kind"])

    if "error" in case["expected"]:
        with pytest.raises(ValueError) as raised:
            resolve()
        assert_fixture_error(raised.value, case["expected"])
        return
    assert [member_key(row) for row in resolve()] == case["expected"]["keys"]


@pytest.mark.parametrize("case", cases("metric_origin"), ids=lambda c: c["name"])
def test_metric_origin(case: dict[str, Any]) -> None:
    definitions = [_definition(spec) for spec in SPEC["models"]["definitions"]]
    if "error" in case["expected"]:
        with pytest.raises(ValueError) as raised:
            metric_origin(case["name"], definitions, _members())
        assert_fixture_error(raised.value, case["expected"])
        return
    assert (
        metric_origin(case["name"], definitions, _members())
        == case["expected"]["origin"]
    )


@pytest.mark.parametrize("case", cases("pool_text"), ids=lambda c: c["query"])
def test_pool_text(case: dict[str, Any]) -> None:
    from commons._definitions import Registry
    from commons._pool import search_pool_text

    source = fixture_source(SPEC["models"]["values"], stubs=SPEC["models"]["stubs"])
    semantic = semantic_registry({"warehouse": source})
    text = search_pool_text(
        {}, Registry(), case["query"], tuple(case["source_names"]), semantic=semantic
    )
    assert text == case["text"]


def test_pool_text_for_an_empty_pool() -> None:
    from commons._definitions import Registry
    from commons._pool import search_pool_text

    empty = semantic_registry({"warehouse": fixture_source([])})
    assert (
        search_pool_text({}, Registry(), "revenue", semantic=empty)
        == SPEC["pool_text"]["empty"]
    )


@pytest.mark.parametrize("case", cases("call_metrics"), ids=lambda c: c["name"])
def test_refused_call_metrics(case: dict[str, Any]) -> None:
    import json

    from commons._definitions import Registry
    from commons._pool import call_metrics

    source = fixture_source(SPEC["models"]["values"])
    registry = Registry([_definition(spec) for spec in SPEC["models"]["definitions"]])
    with pytest.raises(ValueError) as raised:
        call_metrics(
            registry,
            source,
            "warehouse",
            None,
            metrics=case["metrics"],
            dimensions=case.get("dimensions"),
            arguments=json.loads(case.get("arguments", "{}")),
        )
    assert_fixture_error(raised.value, case["expected"])
