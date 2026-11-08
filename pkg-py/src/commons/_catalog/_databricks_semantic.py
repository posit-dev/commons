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
    UnsupportedSemanticParameter,
    parameters_from_spec,
    semantic_key,
    spec_entries,
)
from ._databricks import _quote, _quote_path, _quote_string
from ._snowflake_semantic import Unsupported

__all__ = [
    "BACKEND",
    "associated_models",
    "dependencies",
    "model_from_spec",
    "probe_sql",
    "qualified_name_parts",
    "read_semantic_model",
    "relation_kind",
    "relation_reference",
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


# ---- reading from the warehouse --------------------------------------------

# A definition longer than this is read from the table metadata instead.
VIEW_DEFINITION_MAX_SIZE = 200_000


def _view_definition(backend: Any, table_id: TableId) -> str | None:
    where = " AND ".join(
        [
            f"table_catalog = {_quote_string(table_id.catalog or '')}",
            f"table_schema = {_quote_string(table_id.schema or '')}",
            f"table_name = {_quote_string(table_id.table)}",
        ]
    )
    try:
        rows = backend.query(
            "SELECT length(view_definition) AS definition_length, view_definition "
            f"FROM system.information_schema.views WHERE {where}"
        )
    except Exception:  # noqa: BLE001 - the metadata is read instead
        return None
    if not rows:
        return None
    row = {str(key).lower(): value for key, value in rows[0].items()}
    length = row.get("definition_length")
    if length is None or int(length) > VIEW_DEFINITION_MAX_SIZE:
        return None
    text = row.get("view_definition")
    return text if isinstance(text, str) else None


def _metadata(backend: Any, table_id: TableId) -> dict[str, Any]:
    import json

    try:
        rows = backend.query(
            f"DESCRIBE TABLE EXTENDED {_quote_path(table_id.parts)} AS JSON"
        )
        parsed = json.loads(next(iter(rows[0].values())))
    except Exception:  # noqa: BLE001 - metadata is optional
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _complete_id(backend: Any, table_id: TableId) -> TableId:
    if table_id.catalog and table_id.schema:
        return table_id
    from ._databricks import current_namespace

    current = current_namespace(backend)
    return TableId(
        table=table_id.table,
        schema=table_id.schema or current.schema,
        catalog=table_id.catalog or current.catalog,
    )


def read_semantic_model(backend: Any, view: Any) -> SemanticModel | Unsupported:
    """Read a metric view's definition. Raises when it cannot be read at all.

    `view` is anything with `id`, `description`, and `identity`: a listed
    relation or a stub.
    """
    import yaml

    table_id = _complete_id(backend, view.id)
    label = table_id.label
    metadata: dict[str, Any] | None = None
    text = _view_definition(backend, table_id)
    if text is None:
        metadata = _metadata(backend, table_id)
        text = metadata.get("view_text") or metadata.get("viewText")
    if text is None:
        raise ValueError(f"Failed to read Databricks metric view {label!r}.")
    try:
        spec = yaml.safe_load(text)
    except yaml.YAMLError as error:
        raise ValueError(
            f"Databricks metric view {label!r} returned invalid YAML."
        ) from error
    if (
        not isinstance(spec, dict)
        or spec.get("version") is None
        or all(spec.get(key) is None for key in ("fields", "dimensions", "measures"))
    ):
        raise ValueError(
            f"Databricks metric view {label!r} returned an invalid specification."
        )
    if has_wildcards(spec):
        metadata = metadata if metadata is not None else _metadata(backend, table_id)
        if not metadata.get("columns"):
            return Unsupported(
                view.id, "wildcard members could not be expanded from column metadata"
            )
    try:
        model = model_from_spec(
            view.id,
            spec,
            description=view.description,
            columns=(metadata or {}).get("columns") or [],
        )
    except UnsupportedSemanticParameter as error:
        return Unsupported(view.id, str(error))
    model.identity = view.identity or view.id
    return model


def relation_reference(model: SemanticModel, names: list[str]) -> str:
    """The view, called with a bind for each named parameter."""
    relation = _quote_path(model.id.parts)
    if names:
        binds = ", ".join(f"{_quote(name)} => :p{i}" for i, name in enumerate(names))
        relation += f"({binds})"
    return relation


def probe_sql(model: SemanticModel, names: list[str]) -> str | None:
    """A zero-row query over the view's first measure or dimension."""
    relation = relation_reference(model, names)
    if model.metrics:
        return (
            f"SELECT MEASURE({_quote(model.metrics[0].name)}) FROM {relation} LIMIT 0"
        )
    if model.dimensions:
        return f"SELECT {_quote(model.dimensions[0].name)} FROM {relation} LIMIT 0"
    return None


def associated_models(
    backend: Any,
    relations: dict[str, Any],
    validate: list[str],
    loaded: dict[str, SemanticModel],
    exclude: list[str] | None,
) -> dict[str, SemanticModel]:
    """The metric views over the exactly named relations that those cover.

    Databricks identifiers compare without regard to case.
    """
    from ._core import Selector, check_object_limit, excluded
    from ._databricks import list_relations

    seeds = [relations[label] for label in validate if label in relations]
    namespaces = list(
        dict.fromkeys(
            (r.identity.catalog, r.identity.schema)
            for r in seeds
            if r.kind is not None
            and r.identity is not None
            and all((r.identity.catalog, r.identity.schema, r.identity.table))
        )
    )
    if not namespaces:
        return {}
    candidates = [
        relation
        for catalog, schema in namespaces
        for relation in list_relations(
            backend, Selector(catalog=catalog, schema=schema)
        )
        if relation.kind == "metric_view"
    ]
    hidden = excluded([c.id.table for c in candidates], exclude)
    taken = {semantic_key(m.identity or m.id, BACKEND) for m in loaded.values()}
    unique: dict[tuple[str, ...], Any] = {}
    for candidate, drop in zip(candidates, hidden):
        key = semantic_key(candidate.id, BACKEND)
        if not drop and key not in taken and key not in unique:
            unique[key] = candidate
    check_object_limit(len(relations) + len(loaded) + len(unique))

    selected = {semantic_key(r.identity or r.id, BACKEND) for r in relations.values()}
    models: dict[str, SemanticModel] = {}
    for view in unique.values():
        try:
            model = read_semantic_model(backend, view)
        except Exception:  # noqa: BLE001, S112 - an unreadable view is left out
            continue
        if isinstance(model, Unsupported):
            continue
        if not model.dependencies_complete or not model.dependencies:
            continue
        if all(semantic_key(d, BACKEND) in selected for d in model.dependencies):
            models[model.id.label] = model
    return models
