"""Importing a warehouse catalog into an authored data dictionary.

The rules, which both implementations keep: authored prose wins, warehouse
types are authoritative, identifier case normalizes per backend, and an
ambiguous relative name is an error rather than a guess.

Interpreting a warehouse listing is kept to pure functions over the rows it
returns, and running the queries that produce them belongs to the per-backend
readers, which keeps the interpretation testable without a warehouse. The
session and access checks in `_security` are the exception, since asking the
warehouse is the whole point of them.
"""

from . import _databricks, _snowflake
from ._core import (
    Manifest,
    MergedDictionary,
    Relation,
    Selector,
    check_exclude,
    excluded,
    id_type,
    merge_dictionary,
    normalize_identifier,
    search,
    table_registry,
)
from ._security import (
    CatalogAccessError,
    CatalogAuthorizationError,
    CatalogSessionChangedError,
    CatalogTransientError,
    SessionSnapshot,
    check_session,
    ensure_queryable,
    require_queryable,
    require_queryable_relations,
    session_snapshot,
)

__all__ = [
    "CatalogAccessError",
    "CatalogAuthorizationError",
    "CatalogSessionChangedError",
    "CatalogTransientError",
    "Manifest",
    "MergedDictionary",
    "Relation",
    "Selector",
    "SessionSnapshot",
    "_databricks",
    "_snowflake",
    "check_exclude",
    "check_session",
    "ensure_queryable",
    "excluded",
    "id_type",
    "merge_dictionary",
    "normalize_identifier",
    "require_queryable",
    "require_queryable_relations",
    "search",
    "session_snapshot",
    "table_registry",
]
