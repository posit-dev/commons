"""The Snowflake semantic view contract both packages consume.

The R suite runs the same cases from the same file. See tests/shared/README.md.
"""

from dataclasses import asdict
from typing import Any

import pytest

from commons._catalog._snowflake_semantic import (
    model_from_spec,
    semantic_views_from_show,
    sql_type,
)
from commons._data_source import TableId
from commons._semantic_models import (
    SemanticMember,
    UnsupportedSemanticParameter,
    load_spec_yaml,
)

from ._shared import load_shared_fixture

SPEC = load_shared_fixture("snowflake-semantic-views")


def cases(section: str) -> list[dict[str, Any]]:
    # An empty section would collect zero cases and the runner would pass.
    found = SPEC[section]["cases"]
    assert found, section
    return found


def _id(value: dict[str, str]) -> TableId:
    return TableId(
        catalog=value.get("catalog"), schema=value.get("schema"), table=value["table"]
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
    identity = _id(case["identity"]) if "identity" in case else None
    spec = load_spec_yaml(case["yaml"])
    expected = case["expected"]
    if "unsupported" in expected:
        with pytest.raises(UnsupportedSemanticParameter) as raised:
            model_from_spec(
                table_id, spec, description=case.get("description"), identity=identity
            )
        # R quotes with double quotes and Python with repr; compare the words.
        assert str(raised.value).replace("'", '"') == expected["unsupported"]
        return
    model = model_from_spec(
        table_id, spec, description=case.get("description"), identity=identity
    )
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


def test_metric_sql() -> None:
    import re

    from commons._catalog._snowflake_semantic import metric_sql
    from commons._semantic_models import (
        TypedParameter,
        resolve_filters,
        resolve_members,
        semantic_registry,
    )

    from ._semantic_fixture import assert_fixture_error, fixture_source

    section = SPEC["metric_sql"]
    spec = section["model"]
    parameters = {
        name: TypedParameter(
            name=name,
            type="string",
            description=None,
            default=None,
            has_default=False,
            sql_type=sql_type(declared),
        )
        for name, declared in spec["parameters"].items()
    }
    source = fixture_source([spec], parameters)
    model = source.semantic_models[spec["label"]]
    members = semantic_registry({"warehouse": source}).members
    assert section["cases"]
    for case in section["cases"]:
        try:
            sql = metric_sql(
                model,
                resolve_members(case["metrics"], members, "metric"),
                resolve_members(case.get("dimensions"), members, "dimension"),
                resolve_filters(case.get("filters"), members),
                case.get("where"),
                members,
                case.get("arguments") or [],
            )
        except ValueError as error:
            assert "error" in case["expected"], (case["name"], error)
            assert_fixture_error(error, case["expected"])
            continue
        assert "sql" in case["expected"], case["name"]
        # The fixture pins positional `?` binds, so the named ones must run
        # `:p0`, `:p1`, ... in argument order before they are compared as `?`.
        arguments = case.get("arguments") or []
        binds = re.findall(r":p(\d+)", sql)
        assert binds == [str(i) for i in range(len(arguments))], case["name"]
        assert re.sub(r":p\d+", "?", sql) == case["expected"]["sql"], case["name"]


@pytest.mark.parametrize("case", cases("selection"), ids=lambda c: c["name"])
def test_selection(case: dict[str, Any], monkeypatch: pytest.MonkeyPatch) -> None:
    from commons._catalog import _core
    from commons._catalog._core import Selector
    from commons._catalog._import import import_catalog

    from ._semantic_fixture import assert_fixture_error
    from ._warehouse import FakeWarehouse

    warehouse = SPEC["selection"]["warehouse"]
    backend = FakeWarehouse(
        relations=warehouse["relations"],
        semantic_views=warehouse["semantic_views"],
        semantic_listing_fails=bool(case.get("semantic_listing_fails")),
    )
    tables = case["tables"]
    if tables is not None:
        tables = [
            entry if isinstance(entry, str) else Selector(**entry) for entry in tables
        ]
    if "object_limit" in case:
        monkeypatch.setattr(_core, "OBJECT_LIMIT", case["object_limit"])
    expected = case["expected"]
    if "error" in expected:
        with pytest.raises(ValueError) as raised:
            import_catalog(backend, tables, case.get("exclude"))
        assert_fixture_error(raised.value, expected)
        if "reads" in expected:
            assert backend.yaml_reads == expected["reads"]
        return
    imported = import_catalog(backend, tables, case.get("exclude"))
    assert imported.tables == expected["tables"]
    assert list(imported.semantic_models) == expected["models"]
    assert list(imported.semantic_stubs) == expected["stubs"]
    if "reads" in expected:
        assert backend.yaml_reads == expected["reads"]


@pytest.mark.parametrize("case", cases("hydration"), ids=lambda c: c["name"])
def test_hydration(case: dict[str, Any]) -> None:
    from commons import DataSource
    from commons._definitions import Registry
    from commons._handles import HandleStore
    from commons._pool import call_metrics
    from commons._semantic_models import describe

    from ._semantic_fixture import assert_fixture_error
    from ._warehouse import FakeWarehouse

    warehouse = SPEC["selection"]["warehouse"]
    backend = FakeWarehouse(
        relations=warehouse["relations"], semantic_views=warehouse["semantic_views"]
    )
    source = DataSource._from_warehouse(backend, None, None, None)

    def run(step: dict[str, Any]) -> None:
        if "describe" in step:
            described = describe(source, step["describe"])
            if described.error is not None:
                raise described.error
            return
        call_metrics(
            Registry(),
            source,
            "warehouse",
            HandleStore(),
            metrics=step["call_metrics"],
        )

    for step in case["steps"]:
        if "error" in step:
            with pytest.raises(ValueError) as raised:
                run(step)
            assert_fixture_error(raised.value, step["error"])
        else:
            run(step)
    assert backend.yaml_reads == case["expected"]["reads"]
    assert list(source.semantic_models) == case["expected"]["models"]


@pytest.mark.parametrize("case", cases("verified_queries"), ids=lambda c: c["name"])
def test_verified_queries(case: dict[str, Any]) -> None:
    from commons._catalog._snowflake_semantic import verified_calculations

    from ._semantic_fixture import assert_fixture_error

    entries = (load_spec_yaml(case["yaml"]) or {}).get("verified_queries")
    if "error" in case["expected"]:
        with pytest.raises(ValueError) as raised:
            verified_calculations(entries)
        assert_fixture_error(raised.value, case["expected"])
        return
    actual = [
        {"name": c.name, "description": c.description, "sql": c.sql}
        for c in verified_calculations(entries)
    ]
    assert actual == case["expected"]["calculations"]


@pytest.mark.parametrize("case", cases("calculation_runs"), ids=lambda c: c["name"])
def test_calculation_runs(case: dict[str, Any]) -> None:
    from commons import DataSource
    from commons._pool import call_calculation

    from ._warehouse import FakeWarehouse

    backend = FakeWarehouse(
        relations=["ORDERS"], semantic_views={"REVENUE_MODEL": case["yaml"]}
    )
    source = DataSource._from_warehouse(backend, None, None, None)
    call_calculation({"warehouse": source}, "warehouse", None, case["calculation"])
    assert backend.queries[-1] == case["expected"]["sent"]
