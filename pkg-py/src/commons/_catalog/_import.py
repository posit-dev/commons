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
    MergedDictionary,
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
    _check_definitions_bound(merged)

    manifest = Manifest.build(
        merged.relations, namespace_selected=registry.namespace_selected
    )
    # What was probed on the way in is known to be readable, and a first
    # touch of it should not pay for the same round trip again.
    for label in queryable:
        if label in manifest.access:
            manifest.access[label] = "queryable"

    return ImportedCatalog(
        tables=list(merged.relations),
        table_ids={label: item.id for label, item in merged.relations.items()},
        relations=merged.relations,
        manifest=manifest,
        dictionary=merged.dictionary,
        definition_bindings=merged.definition_bindings,
        session=session,
    )


def _check_definitions_bound(merged: MergedDictionary) -> None:
    """Refuse definitions the merge renamed out from under.

    The merge re-keys an authored dictionary to the warehouse's own labels
    and column spellings, but a definition's expression still names what the
    author wrote. Lowering it as written would emit SQL against identifiers
    the warehouse does not have, so it is refused until the compiler can bind
    the two together.
    """
    bindings = merged.definition_bindings
    exports = getattr(merged.dictionary, "definition_exports", None) or {}
    if not bindings or not exports:
        return
    for authored_table, definitions in exports.items():
        if not definitions:
            continue
        # An authored table that matched nothing is dropped by the merge, so
        # its definitions would go with it and the agent would never be told.
        if bindings["tables"].get(authored_table) is None:
            raise ValueError(
                f"Authored table {authored_table!r} declares definitions, and "
                f"does not match an exposed relation. Name it as the data "
                f"source selects it, or drop it from the data dictionary."
            )
        # Every authored column is checked, not only the ones a definition
        # reads: which columns an expression touches is in the compiler's
        # parse tree, and the refusal is temporary either way. A column the
        # warehouse never reported is caught here too, since a definition
        # over it would lower to SQL naming nothing at all.
        columns = bindings["columns"].get(authored_table) or {}
        unbound = [name for name, discovered in columns.items() if discovered != name]
        if unbound:
            raise NotImplementedError(
                f"Table {authored_table!r} declares definitions, and the "
                f"warehouse does not have column {unbound[0]!r} under that "
                f"name. Binding a definition to the discovered spelling is "
                f"not available yet."
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

    A string is read the way it is everywhere else, as a relation whose dots
    qualify it. A namespace has to be a `Selector`, because `ANALYTICS.PUBLIC`
    on its own does not say whether PUBLIC is a schema or a table.
    """
    if isinstance(entry, Selector):
        id_type(entry)
        return entry
    if isinstance(entry, TableId):
        return Selector(catalog=entry.catalog, schema=entry.schema, table=entry.table)
    if isinstance(entry, str) and entry:
        parts = entry.split(".")
        if len(parts) > 3 or any(part == "" for part in parts):
            raise ValueError(
                "A relation is named catalog.schema.table, with no empty or "
                f"skipped components, got {entry!r}."
            )
        padded = [None] * (3 - len(parts)) + parts
        return Selector(catalog=padded[0], schema=padded[1], table=padded[2])
    raise TypeError(
        "Each entry in tables must be a relation name, a TableId, or a "
        f"Selector naming a namespace, got {entry!r}."
    )
