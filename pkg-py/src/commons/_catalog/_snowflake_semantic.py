"""Reading Snowflake semantic views.

`SHOW SEMANTIC VIEWS` lists them and `SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW`
returns each one's specification. The functions here interpret those replies
without I/O; tests/shared/snowflake-semantic-views.json pins what they read.
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, replace
from typing import Any

import yaml

from .._data_source import TableId
from .._semantic_models import (
    MemberRow,
    SemanticMember,
    SemanticModel,
    SemanticStub,
    TrustedCalculation,
    UnsupportedSemanticParameter,
    members_context,
    new_trusted_calculation,
    parameters_from_spec,
    spec_entries,
    where_conditions,
)
from ._core import Relation, Selector, check_object_limit, excluded, id_type
from ._snowflake import (
    _namespace_target,
    _quote,
    _quote_path,
    _quote_string,
    check_show_complete,
    current_namespace,
)

__all__ = [
    "BACKEND",
    "NO_PUBLIC_MEMBER",
    "SemanticSelection",
    "Unsupported",
    "associated_models",
    "dependencies",
    "exact_semantic_view",
    "list_semantic_views",
    "member_reference",
    "metric_sql",
    "model_from_spec",
    "probe_statement",
    "read_semantic_model",
    "relationship_text",
    "select_semantic_views",
    "semantic_context",
    "semantic_views_from_show",
    "sql_type",
    "variables_clause",
    "verified_calculations",
    "yaml_identifier",
]

BACKEND = "snowflake_semantic_view"
NO_PUBLIC_MEMBER = "The view has no public metric, dimension, or fact."

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


def verified_calculations(entries: Any) -> list[TrustedCalculation]:
    """The view's verified queries, which run exactly as written."""
    calculations = []
    for entry in spec_entries(entries):
        name, sql = entry.get("name"), entry.get("sql")
        question = entry.get("question", name)
        if question is None:
            question = name
        if (
            not isinstance(name, str)
            or not name
            or not isinstance(sql, str)
            or not sql
            or not isinstance(question, str)
        ):
            raise ValueError("Snowflake declares an invalid verified query.")
        calculations.append(new_trusted_calculation(name, question, sql))
    names = [calculation.name for calculation in calculations]
    if len(set(names)) != len(names):
        raise ValueError("Snowflake verified query names must be unique.")
    return calculations


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
    view_id: TableId,
    spec: Any,
    description: str | None = None,
    identity: TableId | None = None,
) -> SemanticModel:
    """A model from a view's YAML specification, already parsed.

    `identity` is the view's warehouse id when `view_id` is the label a caller
    wrote, which need not spell out the namespace a base table inherits.
    Raises `UnsupportedSemanticParameter` when a variable cannot be bound.
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

    relationships = spec_entries(spec.get("relationships"))
    calculations = verified_calculations(spec.get("verified_queries"))
    found, complete = dependencies(identity or view_id, spec)
    context = semantic_context(spec, dimensions, facts, filters, relationships)
    name = spec.get("name")
    own_description = spec.get("description")
    return SemanticModel(
        id=view_id,
        name=name if name is not None else view_id.table,
        backend=BACKEND,
        description=own_description if own_description is not None else description,
        identity=identity,
        dimensions=dimensions,
        metrics=metrics,
        facts=facts,
        filters=filters,
        parameters=parameters,
        dependencies=found,
        dependencies_complete=complete,
        relationships=relationships,
        calculations=calculations,
        first_touch=context,
        retrieval=list(context),
    )


@dataclass(frozen=True)
class Unsupported:
    """A view whose specification commons cannot use, and why."""

    id: TableId
    reason: str


def list_semantic_views(
    backend: Any, selector: Selector, name: str | None = None
) -> list[SemanticStub]:
    """The views in a namespace, or none when the listing itself fails.

    Missing semantic metadata, or a role without the privilege to list it,
    must not block ordinary relation discovery.
    """
    like = f"LIKE {_quote_string(name)} " if name is not None else ""
    try:
        rows = backend.query(f"SHOW SEMANTIC VIEWS {like}{_namespace_target(selector)}")
    except Exception:  # noqa: BLE001 - an unreadable listing lists nothing
        return []
    check_show_complete(rows, "semantic views")
    return semantic_views_from_show(rows)


def exact_semantic_view(backend: Any, selector: Selector) -> SemanticStub | None:
    """The view a relation entry names, if it names one.

    The stub keeps the id the caller wrote, which is its label, and the
    warehouse's own id as its identity.
    """
    catalog, schema = selector.catalog, selector.schema
    if catalog is None or schema is None:
        current = current_namespace(backend)
        catalog = catalog if catalog is not None else current.catalog
        schema = schema if schema is not None else current.schema
    for view in list_semantic_views(
        backend, Selector(catalog=catalog, schema=schema), name=selector.table
    ):
        if view.id.table == selector.table:
            return replace(view, id=_selector_id(selector), identity=view.id)
    return None


def read_semantic_model(
    backend: Any, view: SemanticStub
) -> SemanticModel | Unsupported:
    """Read a view's specification. Raises when it cannot be read at all."""
    label = _quote_path(view.id.parts)
    sql = (
        f"SELECT SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW({_quote_string(label)}) "
        "AS specification"
    )
    try:
        rows = backend.query(sql)
        text = next(iter(rows[0].values()))
    except Exception as error:
        raise ValueError(
            f"Failed to read Snowflake semantic view {label!r}."
        ) from error
    try:
        spec = yaml.safe_load(text)
    except yaml.YAMLError as error:
        raise ValueError(
            f"Snowflake semantic view {label!r} returned invalid YAML."
        ) from error
    try:
        return model_from_spec(
            view.id, spec, description=view.description, identity=view.identity
        )
    except UnsupportedSemanticParameter as error:
        return Unsupported(view.id, str(error))


def member_reference(member: Any) -> str:
    """A member as SEMANTIC_VIEW names it: its logical table, then its name.

    Takes anything with `name` and `parent`, so a model's member and a
    registry row both qualify.
    """
    if not member.parent:
        return _quote(member.name)
    return _quote_path([member.parent, member.name])


def variables_clause(
    model: SemanticModel, names: list[str]
) -> tuple[str, dict[str, str]]:
    """`VARIABLES` for the named parameters, and the bind name each takes.

    Snowflake rejects a value of the wrong type, so each bind is cast to the
    type the view declares when that type is safe to splice.
    """
    binds: dict[str, str] = {}
    entries = []
    for index, name in enumerate(names):
        bind = f"p{index}"
        binds[name] = bind
        declared = model.parameters[name].sql_type
        value = f"CAST(:{bind} AS {declared})" if declared else f":{bind}"
        entries.append(f"{_quote(name)} => {value}")
    return "VARIABLES " + ", ".join(entries), binds


def probe_statement(model: SemanticModel, names: list[str]) -> str | None:
    """A zero-row query over the view's first public member, if it has one."""
    for role, members in (
        ("METRICS", model.metrics),
        ("DIMENSIONS", model.dimensions),
        ("FACTS", model.facts),
    ):
        if members:
            break
    else:
        return None
    variables = ""
    if names:
        clause, _ = variables_clause(model, names)
        variables = f"\n  {clause}"
    return (
        f"SELECT * FROM SEMANTIC_VIEW(\n  {_quote_path(model.id.parts)}"
        f"\n  {role} {member_reference(members[0])}{variables}\n)\nLIMIT 0"
    )


@dataclass
class SemanticSelection:
    """What a `tables` selection says about semantic views."""

    # Every view the selection reaches, by label.
    views: dict[str, SemanticStub]
    # The views an entry named exactly, which are read and probed up front.
    validate: list[str]
    # The selection without the entries that named a view.
    relation_selectors: list[Selector]


def _selector_id(selector: Selector) -> TableId:
    return TableId(
        table=selector.table or "", schema=selector.schema, catalog=selector.catalog
    )


def select_semantic_views(
    backend: Any, selectors: list[Selector], exclude: list[str] | None
) -> SemanticSelection:
    views: list[SemanticStub] = []
    for selector in selectors:
        if id_type(selector) == "namespace":
            views += list_semantic_views(backend, selector)
        else:
            view = exact_semantic_view(backend, selector)
            if view is not None:
                views.append(view)
    hidden = excluded([view.id.table for view in views], exclude)
    views = [view for view, drop in zip(views, hidden) if not drop]
    labels = [view.id.label for view in views]
    # A view named exactly keeps the label it was named by, so the same view
    # reached through its namespace too is found by its warehouse identity.
    keys = [view.identity or view.id for view in views]
    label_counts = Counter(labels)
    key_counts = Counter(keys)
    duplicated = list(
        dict.fromkeys(
            label
            for label, key in zip(labels, keys)
            if label_counts[label] > 1 or key_counts[key] > 1
        )
    )
    if duplicated:
        listed = ", ".join(repr(label) for label in duplicated)
        raise ValueError(f"tables must not select duplicate semantic models: {listed}.")
    exact = {
        _selector_id(selector).label
        for selector in selectors
        if id_type(selector) == "relation"
    }
    return SemanticSelection(
        views=dict(zip(labels, views)),
        validate=[label for label in labels if label in exact],
        relation_selectors=[
            selector
            for selector in selectors
            if id_type(selector) == "namespace"
            or _selector_id(selector).label not in labels
        ],
    )


def _seed(relation: Relation) -> bool:
    identity = relation.identity
    return (
        relation.kind is not None
        and identity is not None
        and all((identity.catalog, identity.schema, identity.table))
    )


def associated_models(
    backend: Any,
    relations: dict[str, Relation],
    validate: list[str],
    loaded: dict[str, SemanticModel],
    exclude: list[str] | None,
) -> dict[str, SemanticModel]:
    """The views over the exactly named relations that those relations cover.

    A view is brought in only when every table it reads is selected, so a
    model never reaches a table the caller left out. One that cannot be read
    or used is skipped rather than failing a selection that never named it.
    """
    seeds = [relations[label] for label in validate if label in relations]
    namespaces = list(
        dict.fromkeys(
            (relation.identity.catalog, relation.identity.schema)
            for relation in seeds
            if _seed(relation) and relation.identity is not None
        )
    )
    if not namespaces:
        return {}
    views = [
        view
        for catalog, schema in namespaces
        for view in list_semantic_views(
            backend, Selector(catalog=catalog, schema=schema)
        )
    ]
    hidden = excluded([view.id.table for view in views], exclude)
    taken = {model.identity or model.id for model in loaded.values()}
    unique: dict[TableId, SemanticStub] = {}
    for view, drop in zip(views, hidden):
        key = view.identity or view.id
        if not drop and key not in taken and key not in unique:
            unique[key] = view
    check_object_limit(len(relations) + len(loaded) + len(unique))

    selected = {relation.identity or relation.id for relation in relations.values()}
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
        if all(dependency in selected for dependency in model.dependencies):
            models[model.id.label] = model
    return models


def metric_sql(
    model: SemanticModel,
    metrics: list[MemberRow],
    dimensions: list[MemberRow],
    filters: list[MemberRow],
    where: Any,
    members: list[MemberRow],
    arguments: list[str],
) -> str:
    """The `SEMANTIC_VIEW` query for native metrics, binding `arguments`.

    Each argument is bound as `:p0`, `:p1`, ... in the order given.
    """
    parts = [_quote_path(model.id.parts)]
    if dimensions:
        parts.append(
            "DIMENSIONS " + ", ".join(member_reference(row) for row in dimensions)
        )
    parts.append("METRICS " + ", ".join(member_reference(row) for row in metrics))
    if arguments:
        clause, _ = variables_clause(model, list(arguments))
        parts.append(clause)
    conditions = [member_reference(row) for row in filters]
    conditions += where_conditions(where, members, member_reference, _quote_string)
    if conditions:
        parts.append("WHERE " + " AND ".join(conditions))
    return "SELECT * FROM SEMANTIC_VIEW(\n  " + "\n  ".join(parts) + "\n)"
