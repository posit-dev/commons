"""Turning a warehouse connection into the tables a data source exposes.

The order is what matters here. The session identity is read first, because
every access answer that follows was decided for it; explicitly named
relations are checked before anything is described, so a name the caller got
wrong fails at construction rather than mid-conversation; and the session is
read again at the end, because a role that moved during discovery invalidates
what was just learned.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .._data_source import TableId
from .._semantic_models import SemanticModel, SemanticStub
from . import _databricks, _snowflake, _snowflake_semantic
from ._core import (
    Manifest,
    Relation,
    Selector,
    check_exclude,
    check_object_limit,
    excluded,
    id_type,
    merge_dictionary,
    table_registry,
)
from ._security import (
    SessionSnapshot,
    check_session,
    require_queryable,
    require_queryable_relations,
    require_queryable_semantic_models,
    session_snapshot,
)

__all__ = ["ImportedCatalog", "import_catalog", "is_warehouse"]

# Each warehouse's reader, and the case its identifiers fold to.
_READERS = {
    "snowflake": (_snowflake, "upper"),
    "databricks": (_databricks, "lower"),
}


@dataclass
class ImportedCatalog:
    """What a warehouse listing contributes to a data source."""

    tables: list[str]
    table_ids: dict[str, TableId]
    relations: dict[str, Relation]
    manifest: Manifest
    dictionary: Any | None
    definition_bindings: dict[str, Any] | None
    session: SessionSnapshot | None
    semantic_models: dict[str, SemanticModel] = field(default_factory=dict)
    semantic_stubs: dict[str, SemanticStub] = field(default_factory=dict)


def is_warehouse(backend: Any) -> bool:
    return backend.dialect() in _READERS


def import_catalog(
    backend: Any,
    tables: Any = None,
    exclude: list[str] | None = None,
    dictionary: Any = None,
) -> ImportedCatalog:
    """Resolve a selection against a warehouse and fold it into a dictionary."""
    reader, identifier_case = _READERS[backend.dialect()]
    check_exclude(exclude)
    session = session_snapshot(backend)

    selectors = _selectors(backend, reader, tables)
    semantic = None
    if reader is _snowflake:
        semantic = _snowflake_semantic.select_semantic_views(
            backend, selectors, exclude
        )
        selectors = semantic.relation_selectors

    registry = table_registry(
        selectors,
        exact_relation=lambda selector: reader.exact_relation(backend, selector),
        list_relations=lambda selector: reader.list_relations(backend, selector),
        exclude=exclude,
    )
    models: dict[str, SemanticModel] = {}
    stubs: dict[str, SemanticStub] = {}
    if semantic is not None:
        # A namespace listing reports a semantic view among its objects too.
        for label in semantic.views:
            registry.relations.pop(label, None)
            registry.validate.pop(label, None)
        check_object_limit(len(registry.relations) + len(semantic.views))
    if registry.validate:
        require_queryable_relations(backend, registry.validate, registry.relations)
    if semantic is not None:
        models = _semantic_models(
            backend, semantic, registry.relations, registry.validate, exclude
        )
        stubs = {
            label: view
            for label, view in semantic.views.items()
            if label not in semantic.validate and label not in models
        }
        check_object_limit(len(registry.relations) + len(models) + len(stubs))
        require_queryable_semantic_models(backend, models, semantic.validate)
    if not registry.relations and not models and not stubs:
        if registry.dropped:
            raise ValueError(
                "The resolved catalog selection contains no objects: exclude "
                f"dropped every relation it resolved to. Narrow {exclude!r}."
            )
        raise ValueError("The resolved catalog selection contains no objects.")

    # A relation named in the selection has just been probed, so the merge
    # only has to check the ones the listing brought in.
    queryable = set(registry.validate)

    def access_check(table_id: TableId, label: str) -> None:
        if label in queryable:
            return
        require_queryable(backend, table_id, label)
        queryable.add(label)

    merged = merge_dictionary(
        dictionary,
        registry.relations,
        describe_relation=lambda table_id: reader.describe_relation(backend, table_id),
        identifier_case=identifier_case,
        access_check=access_check,
    )
    check_session(backend, session)

    # The manifest starts with every relation unknown, including the ones
    # just probed. Carrying the construction-time answer forward would save a
    # round trip on first touch at the cost of serving a grant revoked in
    # between, and the sibling implementation re-probes for the same reason.
    manifest = Manifest.build(
        merged.relations,
        namespace_selected=registry.namespace_selected,
        semantic_stubs={
            label: Relation(
                id=stub.id, kind="semantic_view", description=stub.description
            )
            for label, stub in stubs.items()
        },
    )
    return ImportedCatalog(
        tables=list(merged.relations),
        table_ids={label: item.id for label, item in merged.relations.items()},
        relations=merged.relations,
        manifest=manifest,
        dictionary=merged.dictionary,
        definition_bindings=merged.definition_bindings,
        session=session,
        semantic_models=models,
        semantic_stubs=stubs,
    )


def _semantic_models(
    backend: Any,
    semantic: _snowflake_semantic.SemanticSelection,
    relations: dict[str, Relation],
    validate: dict[str, TableId],
    exclude: list[str] | None,
) -> dict[str, SemanticModel]:
    """The models read up front: those named exactly, and those they cover.

    A namespace's views stay stubs until they are inspected or used, so a
    broad selection costs one listing rather than a read per view.
    """
    models: dict[str, SemanticModel] = {}
    unsupported: list[str] = []
    for label in semantic.validate:
        model = _snowflake_semantic.read_semantic_model(backend, semantic.views[label])
        if isinstance(model, _snowflake_semantic.Unsupported):
            unsupported.append(f"{label}: {model.reason}")
        elif not (model.metrics or model.dimensions or model.facts):
            unsupported.append(f"{label}: {_snowflake_semantic.NO_PUBLIC_MEMBER}")
        else:
            models[label] = model
    if unsupported:
        raise ValueError(
            "Some selected Snowflake semantic views are not supported:\n"
            + "\n".join(f"* {line}" for line in unsupported)
        )
    associated = _snowflake_semantic.associated_models(
        backend, relations, list(validate), models, exclude
    )
    for label, model in associated.items():
        models.setdefault(label, model)
    hidden = excluded(
        [(model.identity or model.id).table for model in models.values()], exclude
    )
    return {
        label: model for (label, model), drop in zip(models.items(), hidden) if not drop
    }


def _selectors(backend: Any, reader: Any, tables: Any) -> list[Selector]:
    """Read a `tables` selection, defaulting to the connection's namespace.

    With nothing named, the schema the connection already points at is the
    selection: it is the one namespace the caller has already chosen.
    """
    if tables is None:
        return [reader.current_namespace(backend)]
    entries = list(tables) if isinstance(tables, (list, tuple)) else [tables]
    if not entries:
        raise ValueError("tables must name at least one relation or namespace.")
    return [_selector(entry) for entry in entries]


def _selector(entry: Any) -> Selector:
    """One selection entry as a `Selector`, whatever it was spelled as.

    A string or a `TableId` is read the way it is everywhere else, as a
    relation whose dots qualify it, so the spelling rules and their wording
    come from the one place that owns them. A namespace has to be a
    `Selector`, because `ANALYTICS.PUBLIC` on its own does not say whether
    PUBLIC is a schema or a table.
    """
    if isinstance(entry, Selector):
        # Raises unless the selector names a relation or a namespace.
        id_type(entry)
        return entry
    from .._data_source import _table_entry_id

    table_id = _table_entry_id(entry)
    return Selector(
        catalog=table_id.catalog, schema=table_id.schema, table=table_id.table
    )
