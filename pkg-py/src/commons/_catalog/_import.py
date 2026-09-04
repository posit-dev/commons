"""Turning a warehouse connection into the tables a data source exposes.

The order is what matters here. The session identity is read first, because
every access answer that follows was decided for it; explicitly named
relations are checked before anything is described, so a name the caller got
wrong fails at construction rather than mid-conversation; and the session is
read again at the end, because a role that moved during discovery invalidates
what was just learned.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .._data_source import TableId
from . import _databricks, _snowflake
from ._core import (
    Manifest,
    Relation,
    Selector,
    check_exclude,
    id_type,
    merge_dictionary,
    table_registry,
)
from ._security import (
    SessionSnapshot,
    check_session,
    require_queryable,
    require_queryable_relations,
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

    registry = table_registry(
        _selectors(backend, reader, tables),
        exact_relation=lambda selector: reader.exact_relation(backend, selector),
        list_relations=lambda selector: reader.list_relations(backend, selector),
        exclude=exclude,
    )
    if registry.validate:
        require_queryable_relations(backend, registry.validate, registry.relations)
    if not registry.relations:
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
        merged.relations, namespace_selected=registry.namespace_selected
    )
    return ImportedCatalog(
        tables=list(merged.relations),
        table_ids={label: item.id for label, item in merged.relations.items()},
        relations=merged.relations,
        manifest=manifest,
        dictionary=merged.dictionary,
        definition_bindings=merged.definition_bindings,
        session=session,
    )


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
