"""Reading Snowflake semantic views.

`SHOW SEMANTIC VIEWS` lists them and `SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW`
returns each one's specification. The functions here interpret those replies
without I/O; tests/shared/snowflake-semantic-views.json pins what they read.
"""

from __future__ import annotations

import re
from dataclasses import replace
from typing import Any

from .._data_source import TableId
from .._semantic_models import (
    SemanticMember,
    SemanticModel,
    SemanticStub,
    members_context,
    parameters_from_spec,
    spec_entries,
)

__all__ = [
    "BACKEND",
    "dependencies",
    "model_from_spec",
    "relationship_text",
    "semantic_context",
    "semantic_views_from_show",
    "sql_type",
    "yaml_identifier",
]

BACKEND = "snowflake_semantic_view"

_PRIVATE = {"private", "private_access"}
_SQL_TYPE = re.compile(r"[A-Za-z_]+( *\( *[0-9]+( *, *[0-9]+)? *\))?")


def _first(entry: dict[str, Any], *keys: str) -> Any:
    """The first of `keys` present with a non-null value."""
    for key in keys:
        if entry.get(key) is not None:
            return entry[key]
    return None


def _strings(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return [str(item) for item in value if item is not None]
    return [str(value)]


def semantic_views_from_show(rows: list[dict[str, Any]]) -> list[SemanticStub]:
    views = []
    for raw in rows:
        row = {str(key).lower(): value for key, value in raw.items()}
        comment = row.get("comment")
        views.append(
            SemanticStub(
                id=TableId(
                    catalog=row["database_name"],
                    schema=row["schema_name"],
                    table=row["name"],
                ),
                backend=BACKEND,
                description=comment if isinstance(comment, str) and comment else None,
            )
        )
    return views


def yaml_identifier(name: Any) -> str | None:
    """A base-table name as SQL reads it: quoted is exact, unquoted upper-cased."""
    if not isinstance(name, str):
        return None
    if len(name) >= 2 and name.startswith('"') and name.endswith('"'):
        return name[1:-1].replace('""', '"')
    return name.upper()


def dependencies(view_id: TableId, spec: dict[str, Any]) -> tuple[list[TableId], bool]:
    """The tables a view reads, and whether every one of them is known."""
    found: list[TableId] = []
    complete = True
    for table in spec_entries(spec.get("tables")):
        base = table.get("base_table") or {}
        name = yaml_identifier(base.get("table"))
        catalog = yaml_identifier(_first(base, "database", "catalog"))
        schema = yaml_identifier(base.get("schema"))
        catalog = view_id.catalog if catalog is None else catalog
        schema = view_id.schema if schema is None else schema
        if name is None or catalog is None or schema is None:
            complete = False
            continue
        dependency = TableId(catalog=catalog, schema=schema, table=name)
        if dependency not in found:
            found.append(dependency)
    return found, complete and bool(found)


def _members(
    entries: Any, kind: str, parent: str | None = None
) -> list[SemanticMember]:
    members = []
    for item in spec_entries(entries):
        modifier = str(item.get("access_modifier") or "public_access").lower()
        if modifier in _PRIVATE:
            continue
        name = item.get("name")
        if not isinstance(name, str) or not name:
            continue
        labels = [label.lower() for label in _strings(item.get("labels"))]
        members.append(
            SemanticMember(
                name=name,
                kind=kind,
                parent=parent,
                label=item.get("label"),
                description=_first(item, "description", "comment"),
                type=item.get("data_type"),
                synonyms=tuple(_strings(item.get("synonyms"))),
                filter="filter" in labels,
            )
        )
    return members


def relationship_text(relationship: dict[str, Any]) -> str:
    name = _first(relationship, "name") or "unnamed"
    left = _first(relationship, "left_table", "from_table") or "unknown"
    right = _first(relationship, "right_table", "to_table") or "unknown"
    columns = [
        f"{_first(column, 'left_column', 'from_column') or '?'} = "
        f"{_first(column, 'right_column', 'to_column') or '?'}"
        for column in relationship.get("relationship_columns") or []
    ]
    on = f" on {', '.join(columns)}" if columns else ""
    return f"Semantic relationship `{name}` links `{left}` to `{right}`{on}."


def semantic_context(
    spec: dict[str, Any],
    dimensions: list[SemanticMember],
    facts: list[SemanticMember],
    filters: list[SemanticMember],
    relationships: list[Any],
) -> list[str]:
    instructions = _strings(spec.get("custom_instructions")) + _strings(
        spec.get("module_custom_instructions")
    )
    entity_filters = [m for m in dimensions if m.filter] + [
        m for m in facts if m.filter
    ]
    return [
        *dict.fromkeys(text for text in instructions if text),
        *(relationship_text(relationship) for relationship in relationships),
        *members_context(facts, "Native semantic facts"),
        *members_context(entity_filters + filters, "Native semantic filters"),
    ]


def sql_type(declared: Any) -> str | None:
    """The type a bound variable is cast to, if the text is safe to splice."""
    if not isinstance(declared, str) or not _SQL_TYPE.fullmatch(declared):
        return None
    return declared.replace(" ", "").upper()


def model_from_spec(
    view_id: TableId, spec: Any, description: str | None = None
) -> SemanticModel:
    """A model from a view's YAML specification, already parsed.

    Raises `UnsupportedSemanticParameter` when a variable has no bindable type.
    """
    spec = spec or {}
    dimensions: list[SemanticMember] = []
    facts: list[SemanticMember] = []
    filters: list[SemanticMember] = []
    metrics: list[SemanticMember] = []
    for table in spec_entries(spec.get("tables")):
        parent = table.get("name")
        dimensions += _members(table.get("dimensions"), "dimension", parent)
        dimensions += _members(table.get("time_dimensions"), "dimension", parent)
        facts += _members(table.get("facts"), "fact", parent)
        filters += _members(table.get("filters"), "filter", parent)
        metrics += _members(table.get("metrics"), "metric", parent)
    metrics += _members(spec.get("metrics"), "metric")

    parameters = parameters_from_spec(spec.get("variables"), "Snowflake")
    for entry in spec_entries(spec.get("variables")):
        declared = _first(entry, "data_type", "type")
        parameters[entry["name"]] = replace(
            parameters[entry["name"]], sql_type=sql_type(declared)
        )

    relationships = list(spec.get("relationships") or [])
    found, complete = dependencies(view_id, spec)
    context = semantic_context(spec, dimensions, facts, filters, relationships)
    name = spec.get("name")
    own_description = spec.get("description")
    return SemanticModel(
        id=view_id,
        name=name if name is not None else view_id.table,
        backend=BACKEND,
        description=own_description if own_description is not None else description,
        dimensions=dimensions,
        metrics=metrics,
        facts=facts,
        filters=filters,
        parameters=parameters,
        dependencies=found,
        dependencies_complete=complete,
        relationships=relationships,
        first_touch=context,
        retrieval=list(context),
    )
