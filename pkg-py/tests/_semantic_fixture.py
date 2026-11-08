"""Building the semantic models a shared fixture declares."""

from typing import Any

import pandas as pd

from commons import DataSource, data_source
from commons._data_source import TableId
from commons._semantic_models import (
    SemanticMember,
    SemanticModel,
    SemanticStub,
    TypedParameter,
)


def _members(entries: list[dict[str, Any]], kind: str) -> list[SemanticMember]:
    return [
        SemanticMember(
            name=entry["name"],
            kind=kind,
            parent=entry.get("parent"),
            label=entry.get("label"),
            description=entry.get("description"),
            filter=bool(entry.get("filter")),
        )
        for entry in entries
    ]


def fixture_model(
    spec: dict[str, Any], parameters: dict[str, TypedParameter] | None = None
) -> SemanticModel:
    table_id = spec.get("id") or {
        "catalog": "ANALYTICS",
        "schema": "PUBLIC",
        "table": spec["label"],
    }
    return SemanticModel(
        id=TableId(**table_id),
        name=spec["label"],
        backend="snowflake_semantic_view",
        dimensions=_members(spec.get("dimensions", []), "dimension"),
        metrics=_members(spec.get("metrics", []), "metric"),
        facts=_members(spec.get("facts", []), "fact"),
        filters=_members(spec.get("filters", []), "filter"),
        parameters=parameters or _parameters(spec.get("parameters")),
    )


def _parameters(specs: Any) -> dict[str, TypedParameter]:
    if not isinstance(specs, list):
        return {}
    return {
        spec["name"]: TypedParameter(
            name=spec["name"],
            type=spec["type"],
            description=spec.get("description"),
            default=spec.get("default"),
            has_default=bool(spec.get("has_default")),
        )
        for spec in specs
    }


def fixture_source(
    models: list[dict[str, Any]],
    parameters: dict[str, TypedParameter] | None = None,
    stubs: list[dict[str, Any]] | None = None,
) -> DataSource:
    source = data_source(sales=pd.DataFrame({"revenue": [1.0]}))
    source.semantic_models = {
        spec["label"]: fixture_model(spec, parameters) for spec in models
    }
    source.semantic_stubs = {}
    for stub in stubs or []:
        catalog, schema, table = stub["label"].split(".")
        source.semantic_stubs[stub["label"]] = SemanticStub(
            id=TableId(catalog=catalog, schema=schema, table=table),
            backend="snowflake_semantic_view",
            description=stub.get("description"),
        )
    return source


def assert_fixture_error(error: BaseException, expected: dict[str, Any]) -> None:
    message = str(error)
    for mention in expected["mentions"]:
        assert mention in message, (mention, message)
