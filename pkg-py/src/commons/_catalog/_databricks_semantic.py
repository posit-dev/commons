"""Reading Databricks metric views.

A metric view's definition is YAML. The functions here interpret it without
I/O; tests/shared/databricks-metric-views.json pins what they read.
"""

from __future__ import annotations

from typing import Any

from .._data_source import TableId
from .._semantic_models import (
    SemanticMember,
    SemanticModel,
    parameters_from_spec,
    spec_entries,
)

__all__ = [
    "BACKEND",
    "dependencies",
    "model_from_spec",
    "qualified_name_parts",
    "relation_kind",
    "type_text",
]

BACKEND = "databricks_metric_view"


def relation_kind(table_type: Any, object_type: Any = None) -> str:
    """A listed relation's kind, preferring the metadata's object type."""
    kind = str(object_type if object_type else table_type or "").lower()
    if "metric" in kind:
        return "metric_view"
    if "view" in kind:
        return "view"
    return "table"


def qualified_name_parts(value: str) -> list[str]:
    """A dotted name's parts; backticks quote, and a doubled one is literal."""
    parts: list[str] = []
    current: list[str] = []
    quoted = False
    i = 0
    while i < len(value):
        char = value[i]
        if char == "`":
            if quoted and i + 1 < len(value) and value[i + 1] == "`":
                current.append("`")
                i += 2
                continue
            quoted = not quoted
        elif char == "." and not quoted:
            parts.append("".join(current))
            current = []
        elif char.isspace() and not quoted:
            return []
        else:
            current.append(char)
        i += 1
    if quoted:
        return []
    return [*parts, "".join(current)]


def _dependency_id(source: Any) -> TableId | None:
    if not isinstance(source, str) or not source.strip():
        return None
    parts = qualified_name_parts(source.strip())
    if len(parts) != 3 or not all(parts):
        return None
    catalog, schema, table = parts
    return TableId(catalog=catalog, schema=schema, table=table)


def _flatten_joins(joins: Any) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    pending = list(joins or [])
    while pending:
        join = pending.pop(0)
        out.append(join)
        pending = list(join.get("joins") or []) + pending
    return out


def dependencies(spec: dict[str, Any]) -> tuple[list[TableId], bool]:
    """The tables a view reads, and whether every one of them is named."""
    sources = [spec.get("source")] + [
        join.get("source") for join in _flatten_joins(spec.get("joins"))
    ]
    ids = [_dependency_id(source) for source in sources]
    complete = bool(ids) and all(table_id is not None for table_id in ids)
    found: list[TableId] = []
    seen: set[tuple[str, ...]] = set()
    for table_id in ids:
        if table_id is None:
            continue
        key = tuple(part.lower() for part in table_id.parts)
        if key not in seen:
            seen.add(key)
            found.append(table_id)
    return found, complete


def _relationship_text(join: dict[str, Any]) -> str:
    condition = join.get("on")
    using = join.get("using")
    if condition is None and using:
        names = using if isinstance(using, list) else [using]
        condition = "using " + ", ".join(str(name) for name in names)
    text = (
        f"Metric-view relationship `{join.get('name') or 'unnamed'}` joins "
        f"`{join.get('source') or 'unknown'}`"
    )
    if condition is not None:
        text += f" on {condition}"
    if join.get("cardinality") is not None:
        text += f" with {join['cardinality']} cardinality"
    return text + "."


def _context(spec: dict[str, Any], joins: list[dict[str, Any]]) -> list[str]:
    texts = [spec.get("comment"), spec.get("ai_context")]
    if spec.get("filter") is not None:
        texts.append(f"Metric-view filter: {spec['filter']}")
    texts += [_relationship_text(join) for join in joins]
    return list(dict.fromkeys(str(text) for text in texts if text))


def _members(entries: Any, kind: str) -> list[SemanticMember]:
    members = []
    for item in spec_entries(entries):
        name = item.get("name")
        if not isinstance(name, str) or not name:
            continue
        synonyms = item.get("synonyms") or []
        members.append(
            SemanticMember(
                name=name,
                kind=kind,
                label=item.get("display_name"),
                description=item.get("comment"),
                type=item.get("data_type"),
                synonyms=tuple(
                    str(s)
                    for s in (synonyms if isinstance(synonyms, list) else [synonyms])
                ),
            )
        )
    return members


def _has_wildcard(entries: Any) -> bool:
    return any(
        not isinstance(item.get("name"), str) or not item.get("name")
        for item in spec_entries(entries)
    )


def type_text(value: Any) -> str | None:
    """A column type from metadata, as a member's type."""
    if isinstance(value, str):
        return value
    if not isinstance(value, dict) or not isinstance(value.get("name"), str):
        return None
    name = value["name"]
    if name == "decimal":
        return f"decimal({value.get('precision')},{value.get('scale')})"
    if name in ("varchar", "char"):
        return f"{name}({value.get('length')})"
    return name


def _wildcard_members(
    columns: list[dict[str, Any]],
    kind: str,
    explicit: list[SemanticMember],
    entries: Any,
) -> list[SemanticMember]:
    if not _has_wildcard(entries):
        return []
    named = {member.name for member in explicit}
    measure = kind == "metric"
    return [
        SemanticMember(
            name=column["name"],
            kind=kind,
            description=column.get("comment"),
            type=type_text(column.get("type")),
        )
        for column in columns
        if bool(column.get("is_measure")) == measure
        and isinstance(column.get("name"), str)
        and column["name"]
        and column["name"] not in named
    ]


def has_wildcards(spec: dict[str, Any]) -> bool:
    return any(
        _has_wildcard(spec.get(key)) for key in ("fields", "dimensions", "measures")
    )


def model_from_spec(
    view_id: TableId,
    spec: Any,
    description: str | None = None,
    columns: list[dict[str, Any]] | None = None,
) -> SemanticModel:
    """A model from a metric view's parsed YAML definition.

    Raises `UnsupportedSemanticParameter` when a parameter has no bindable
    type, and `ValueError` when a wildcard member has no column metadata to
    expand from.
    """
    spec = spec or {}
    columns = columns or []
    if has_wildcards(spec) and not columns:
        raise ValueError(
            "Databricks wildcard members require concrete column metadata."
        )
    dimension_entries = [
        *spec_entries(spec.get("fields")),
        *spec_entries(spec.get("dimensions")),
    ]
    dimensions = _members(dimension_entries, "dimension")
    metrics = _members(spec.get("measures"), "metric")
    dimensions += _wildcard_members(columns, "dimension", dimensions, dimension_entries)
    metrics += _wildcard_members(columns, "metric", metrics, spec.get("measures"))
    found, complete = dependencies(spec)
    relationships = list(spec.get("joins") or [])
    context = _context(spec, _flatten_joins(relationships))
    comment = spec.get("comment")
    return SemanticModel(
        id=view_id,
        name=view_id.table,
        backend=BACKEND,
        description=comment if comment is not None else description,
        dimensions=dimensions,
        metrics=metrics,
        parameters=parameters_from_spec(spec.get("parameters"), "Databricks"),
        dependencies=found,
        dependencies_complete=complete,
        relationships=relationships,
        first_touch=context,
        retrieval=list(context),
    )
