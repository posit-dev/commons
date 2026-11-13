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
    members = _members()
    if case.get("empty"):
        definitions, members = [], []
    unread = case.get("unread", [stub["label"] for stub in SPEC["models"]["stubs"]])
    if "error" in case["expected"]:
        with pytest.raises(ValueError) as raised:
            metric_origin(case["name"], definitions, members, unread)
        assert_fixture_error(raised.value, case["expected"])
        return
    assert (
        metric_origin(case["name"], definitions, members, unread)
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


@pytest.mark.parametrize("case", cases("description_text"), ids=lambda c: c["model"])
def test_description_text(case: dict[str, Any]) -> None:
    from commons._semantic_models import SemanticDescription, description_text

    models = fixture_source(SPEC["models"]["values"]).semantic_models
    model = models.get(case["model"])
    stubs = {stub["label"]: stub for stub in SPEC["models"]["stubs"]}
    described = SemanticDescription(
        name=case["model"],
        kind="snowflake_semantic_view",
        description=(
            model.description
            if model is not None
            else stubs[case["model"]]["description"]
        ),
        model=model,
        error=ValueError(case["error"]) if "error" in case else None,
    )
    assert description_text(described) == case["text"]


@pytest.mark.parametrize("case", cases("first_touch"), ids=lambda c: c["table"])
def test_first_touch(case: dict[str, Any]) -> None:
    from commons._catalog import Relation
    from commons._data_source import TableId
    from commons._semantic_models import SemanticModel, semantic_first_touch

    section = SPEC["first_touch"]
    source = fixture_source([])
    source.relations = {
        label: Relation(
            id=TableId(**relation["id"]),
            identity=TableId(**relation["identity"])
            if "identity" in relation
            else None,
        )
        for label, relation in section["relations"].items()
    }
    source.semantic_models = {
        model["label"]: SemanticModel(
            id=TableId(catalog="ANALYTICS", schema="PUBLIC", table=model["label"]),
            name=model["label"],
            backend="snowflake_semantic_view",
            dependencies=[TableId(**d) for d in model["dependencies"]],
            first_touch=model["context"],
        )
        for model in section["models"]
    }
    assert semantic_first_touch(source, case["table"]) == case["expected"]


def test_calculation_keys() -> None:
    from commons._semantic_models import calculations_registry

    source = fixture_source(SPEC["models"]["values"])
    keys = [c.key for c in calculations_registry({"warehouse": source})]
    assert keys == SPEC["calculations"]["keys"]


@pytest.mark.parametrize(
    "case", cases("calculations"), ids=lambda c: f"{c['source']}-{c['name']}"
)
def test_calculation_resolution(case: dict[str, Any]) -> None:
    from commons._semantic_models import calculations_registry, resolve_calculation

    source = fixture_source(SPEC["models"]["values"])
    calculations = calculations_registry({"warehouse": source})
    if "error" in case["expected"]:
        with pytest.raises(ValueError) as raised:
            resolve_calculation(calculations, case["name"], case["source"])
        assert_fixture_error(raised.value, case["expected"])
        return
    found = resolve_calculation(calculations, case["name"], case["source"])
    assert found.key == case["expected"]["key"]
