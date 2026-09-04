"""Importing a warehouse catalog into an authored data dictionary.

The rules, which both implementations keep: authored prose wins, warehouse
types are authoritative, identifier case normalizes per backend, and an
ambiguous relative name is an error rather than a guess.

Everything here is a pure function over the rows a warehouse listing returns.
Running the queries that produce those rows belongs to the per-backend
readers, which keeps this testable without a warehouse.
"""

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

__all__ = [
    "Manifest",
    "MergedDictionary",
    "Relation",
    "Selector",
    "check_exclude",
    "excluded",
    "id_type",
    "merge_dictionary",
    "normalize_identifier",
    "search",
    "table_registry",
]
