"""The Databricks metric view contract both packages consume.

The R suite runs the same cases from the same file. See tests/shared/README.md.
"""

from dataclasses import asdict
from typing import Any

import pytest
import yaml

from commons._catalog._databricks import relations_from_information_schema
from commons._catalog._databricks_semantic import (
    model_from_spec,
    qualified_name_parts,
    type_text,
)
from commons._data_source import TableId
from commons._semantic_models import UnsupportedSemanticParameter

from ._semantic_fixture import assert_fixture_error
from ._shared import load_shared_fixture

SPEC = load_shared_fixture("databricks-metric-views")


def cases(section: str) -> list[dict[str, Any]]:
    # An empty section would collect zero cases and the runner would pass.
    found = SPEC[section]["cases"]
    assert found, section
    return found


def _id_dict(table_id: TableId) -> dict[str, str | None]:
    return {
        "catalog": table_id.catalog,
        "schema": table_id.schema,
        "table": table_id.table,
    }


@pytest.mark.parametrize("case", cases("specifications"), ids=lambda c: c["name"])
def test_specification(case: dict[str, Any]) -> None:
    def read():
        return model_from_spec(
            TableId(**case["id"]),
            yaml.safe_load(case["yaml"]),
            description=case.get("description"),
            columns=case.get("columns"),
        )

    expected = case["expected"]
    if "unsupported" in expected:
        with pytest.raises(UnsupportedSemanticParameter) as raised:
            read()
        for mention in expected["unsupported"]:
            assert mention in str(raised.value)
        return
    if "error" in expected:
        with pytest.raises(ValueError) as raised:
            read()
        assert_fixture_error(raised.value, expected)
        return
    model = read()
    actual = {
        "name": model.name,
        "description": model.description,
        **{
            kind: [
                {**asdict(m), "synonyms": list(m.synonyms)}
                for m in getattr(model, kind)
            ]
            for kind in ("dimensions", "metrics", "facts", "filters")
        },
        "parameters": {
            name: {
                "type": p.type,
                "description": p.description,
                "has_default": p.has_default,
                "default": p.default,
                "sql_type": p.sql_type,
            }
            for name, p in model.parameters.items()
        },
        "dependencies": [_id_dict(d) for d in model.dependencies],
        "dependencies_complete": model.dependencies_complete,
        "first_touch": model.first_touch,
        "retrieval": model.retrieval,
    }
    assert actual == expected


@pytest.mark.parametrize("case", cases("qualified_names"), ids=lambda c: c["value"])
def test_qualified_names(case: dict[str, Any]) -> None:
    assert qualified_name_parts(case["value"]) == case["parts"]


@pytest.mark.parametrize("case", cases("type_text"), ids=lambda c: repr(c["type"]))
def test_type_text(case: dict[str, Any]) -> None:
    assert type_text(case["type"]) == case["text"]


@pytest.mark.parametrize(
    "case",
    cases("relation_kinds"),
    ids=lambda c: f"{c['table_type']}-{c.get('object_type')}",
)
def test_relation_kinds(case: dict[str, Any]) -> None:
    row = {
        "table_catalog": "main",
        "table_schema": "sales",
        "table_name": "x",
        "table_type": case["table_type"],
        "comment": None,
    }
    object_types = (
        {("sales", "x"): case["object_type"]} if "object_type" in case else None
    )
    [relation] = relations_from_information_schema([row], object_types)
    assert relation.kind == case["kind"]


@pytest.mark.parametrize("case", cases("selection"), ids=lambda c: c["name"])
def test_selection(case: dict[str, Any]) -> None:
    from commons._catalog._import import import_catalog

    from ._warehouse import FakeDatabricks

    warehouse = SPEC["selection"]["warehouse"]
    backend = FakeDatabricks(
        relations=warehouse["tables"],
        metric_views=warehouse["metric_views"],
        metadata=warehouse["metadata"],
    )
    expected = case["expected"]
    if "error" in expected:
        with pytest.raises(ValueError) as raised:
            import_catalog(backend, case["tables"], case.get("exclude"))
        assert_fixture_error(raised.value, expected)
        return
    imported = import_catalog(backend, case["tables"], case.get("exclude"))
    assert imported.tables == expected["tables"]
    assert list(imported.semantic_models) == expected["models"]
    assert list(imported.semantic_stubs) == expected["stubs"]
