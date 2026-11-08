"""The Snowflake semantic view contract both packages consume.

The R suite runs the same cases from the same file. See tests/shared/README.md.
"""

from dataclasses import asdict
from typing import Any

import pytest
import yaml

from commons._catalog._snowflake_semantic import (
    model_from_spec,
    semantic_views_from_show,
    sql_type,
)
from commons._data_source import TableId
from commons._semantic_models import SemanticMember, UnsupportedSemanticParameter

from ._shared import load_shared_fixture

SPEC = load_shared_fixture("snowflake-semantic-views")


def cases(section: str) -> list[dict[str, Any]]:
    # An empty section would collect zero cases and the runner would pass.
    found = SPEC[section]["cases"]
    assert found, section
    return found


def _id(value: dict[str, str]) -> TableId:
    return TableId(
        catalog=value["catalog"], schema=value["schema"], table=value["table"]
    )


def _id_dict(table_id: TableId) -> dict[str, str | None]:
    return {
        "catalog": table_id.catalog,
        "schema": table_id.schema,
        "table": table_id.table,
    }


def _member(member: SemanticMember) -> dict[str, Any]:
    return {**asdict(member), "synonyms": list(member.synonyms)}


@pytest.mark.parametrize("case", cases("show_rows"), ids=lambda c: c["name"])
def test_show_rows(case: dict[str, Any]) -> None:
    views = [
        {"id": _id_dict(view.id), "description": view.description}
        for view in semantic_views_from_show(case["rows"])
    ]
    assert views == case["views"]


@pytest.mark.parametrize("case", cases("specifications"), ids=lambda c: c["name"])
def test_specification(case: dict[str, Any]) -> None:
    table_id = _id(case["id"])
    spec = yaml.safe_load(case["yaml"])
    expected = case["expected"]
    if "unsupported" in expected:
        with pytest.raises(UnsupportedSemanticParameter) as raised:
            model_from_spec(table_id, spec, description=case.get("description"))
        # R quotes with double quotes and Python with repr; compare the words.
        assert str(raised.value).replace("'", '"') == expected["unsupported"]
        return
    model = model_from_spec(table_id, spec, description=case.get("description"))
    actual = {
        "name": model.name,
        "description": model.description,
        "dimensions": [_member(m) for m in model.dimensions],
        "metrics": [_member(m) for m in model.metrics],
        "facts": [_member(m) for m in model.facts],
        "filters": [_member(m) for m in model.filters],
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


@pytest.mark.parametrize("case", cases("sql_types"), ids=lambda c: c["declared"])
def test_sql_type(case: dict[str, Any]) -> None:
    assert sql_type(case["declared"]) == case["sql_type"]
