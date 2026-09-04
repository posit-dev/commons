"""Selection, search, and the dictionary merge, independent of any backend."""

from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass, field, replace
from typing import Any

from .._data_source import TableId

__all__ = [
    "Manifest",
    "MergedDictionary",
    "Relation",
    "Selector",
    "check_exclude",
    "excluded",
    "id_type",
    "matched_relation",
    "merge_dictionary",
    "normalize_identifier",
    "search",
    "table_registry",
]

# A selection resolving to more objects than this is a mistake rather than an
# intent, and hydrating them would cost a round trip each.
OBJECT_LIMIT = 25_000

# Past this many bytes of labels, the listing stops being useful in a prompt
# and the agent is given search instead.
PROMPT_LIMIT = 3_000

# Bounds the zero-row access checks when many high-ranking metadata matches
# turn out to be unauthorized.
SEARCH_PROBE_LIMIT = 100

_WORDS = re.compile(r"[^0-9a-z_]+")
_GLOB_SPECIAL = re.compile(r"([][{}()+.^$|\\])")


@dataclass(frozen=True)
class Selector:
    """One entry of a `tables` selection, naming a relation or a namespace.

    Separate from `TableId` because a selection may stop at a catalog or a
    schema, and a `TableId` always names a table.
    """

    catalog: str | None = None
    schema: str | None = None
    table: str | None = None


@dataclass
class Relation:
    """One object a warehouse listing reported."""

    id: TableId
    kind: str | None = None
    description: str | None = None
    columns: list[dict[str, Any]] = field(default_factory=list)
    # Set when an exact selection matched a discovered relation, so the
    # authored spelling can be kept while the warehouse identity is retained.
    identity: TableId | None = None
    discovered: bool = True

    @property
    def name(self) -> str:
        return self.id.table


@dataclass
class TableRegistry:
    relations: dict[str, Relation]
    validate: dict[str, TableId]
    namespace_selected: bool
    # The relations the listing reported and exclude then removed, so a
    # caller left with nothing, or with a dictionary entry that now matches
    # nothing, can say which it was. A name the warehouse never had is not in
    # here: exclude is not what made it absent.
    dropped: list[Relation] = field(default_factory=list)


@dataclass
class MergedDictionary:
    dictionary: Any
    relations: dict[str, Relation]
    definition_bindings: dict[str, Any] | None


def matched_relation(relation: Relation, requested: TableId) -> Relation:
    """An exact selection's match, under the label it was asked for.

    `requested` is the authored name qualified with the namespace the lookup
    ran in. The warehouse's own id is kept as the identity, since it carries
    that backend's casing and is what later metadata queries name. A relation
    the warehouse reports without a namespace has none to be labelled with,
    and none to be queried under either: a Databricks temporary view answers
    only to its bare name.
    """
    qualified = relation.id.schema is not None or relation.id.catalog is not None
    return Relation(
        id=requested if qualified else relation.id,
        kind=relation.kind,
        description=relation.description,
        identity=relation.id,
    )


def normalize_identifier(value: Any, identifier_case: str | None) -> Any:
    """Fold an identifier the way the backend does, or leave it alone."""
    if isinstance(value, list):
        return [normalize_identifier(item, identifier_case) for item in value]
    if identifier_case == "upper":
        return str(value).upper()
    if identifier_case == "lower":
        return str(value).lower()
    return value


def _glob_regex(pattern: str) -> re.Pattern[str]:
    """A shell glob as an anchored regex, with everything else literal."""
    escaped = _GLOB_SPECIAL.sub(r"\\\1", pattern)
    escaped = escaped.replace("*", ".*").replace("?", ".")
    return re.compile(f"^{escaped}$")


def excluded(names: list[str], patterns: list[str] | None) -> list[bool]:
    """Which names an exclude list hides.

    Matching is against the bare table name, case-sensitively: a pattern
    cannot exclude by catalog or schema, and it must use the warehouse's
    own spelling even on a case-folding backend.
    """
    if not patterns:
        return [False] * len(names)
    compiled = [_glob_regex(pattern) for pattern in patterns]
    return [any(matcher.match(name) for matcher in compiled) for name in names]


def check_exclude(exclude: Any) -> Any:
    if exclude is None:
        return exclude
    if not isinstance(exclude, list) or not all(
        isinstance(item, str) and item for item in exclude
    ):
        raise ValueError("exclude must contain non-empty glob patterns.")
    return exclude


def id_type(selector: Selector) -> str:
    """Whether a selection entry names a relation or a namespace.

    The components have to read outermost first with nothing skipped:
    a catalog and a table with no schema between them does not say which
    schema was meant.
    """
    roles = tuple(
        role
        for role in ("catalog", "schema", "table")
        if getattr(selector, role) is not None
    )
    valid = {
        ("catalog",),
        ("schema",),
        ("catalog", "schema"),
        ("table",),
        ("schema", "table"),
        ("catalog", "schema", "table"),
    }
    empty = any(
        getattr(selector, role) == "" for role in ("catalog", "schema", "table")
    )
    if roles not in valid or empty:
        raise ValueError(
            "Entries in tables must name catalog, schema, and table in that "
            "order, without skipped or empty components."
        )
    return "relation" if selector.table is not None else "namespace"


def _selector_id(selector: Selector) -> TableId:
    assert selector.table is not None
    return TableId(
        table=selector.table, schema=selector.schema, catalog=selector.catalog
    )


def table_registry(
    selectors: list[Selector],
    exact_relation: Callable[[Selector], Relation | None],
    list_relations: Callable[[Selector], list[Relation]],
    exclude: list[str] | None = None,
    object_limit: int = OBJECT_LIMIT,
) -> TableRegistry:
    """Resolve a `tables` selection into labelled relations.

    Raises when the selection resolves to more than `object_limit`
    objects, and when two entries label the same relation.
    """
    check_exclude(exclude)
    relations: list[Relation] = []
    validate: list[TableId] = []
    namespace_selected = False
    for selector in selectors:
        if id_type(selector) == "relation":
            # An entry naming a table is kept whether or not the warehouse
            # has it, and is always validated. Dropping a missing one turns
            # "that table is not there" into a quietly smaller selection.
            found = exact_relation(selector)
            # Keyed by the relation's own id rather than the selector's: an
            # entry naming a bare table is qualified with the connection's
            # namespace once the warehouse answers, and the two lists have to
            # agree on the label or the access check cannot pair them up.
            relation = (
                found
                if found is not None
                else Relation(id=_selector_id(selector), discovered=False)
            )
            relations.append(relation)
            validate.append(relation.id)
            continue
        namespace_selected = True
        relations.extend(list_relations(selector))

    keep = excluded([item.name for item in relations], exclude)
    dropped = [
        item for item, hidden in zip(relations, keep) if hidden and item.discovered
    ]
    relations = [item for item, hidden in zip(relations, keep) if not hidden]
    validate = [
        table_id
        for table_id, hidden in zip(
            validate, excluded([item.table for item in validate], exclude)
        )
        if not hidden
    ]
    if len(relations) > object_limit:
        raise ValueError(
            f"The selection resolves to {len(relations)} objects, above the "
            f"supported limit of {object_limit}. Narrow tables to fewer "
            f"catalog or schema prefixes."
        )

    labelled: dict[str, Relation] = {}
    duplicated: list[str] = []
    for item in relations:
        label = item.id.label
        if label in labelled:
            if label not in duplicated:
                duplicated.append(label)
            continue
        labelled[label] = item
    if duplicated:
        listed = ", ".join(repr(label) for label in duplicated)
        raise ValueError(f"tables must not select duplicate labels: {listed}.")
    return TableRegistry(
        relations=labelled,
        validate={table_id.label: table_id for table_id in validate},
        namespace_selected=namespace_selected,
        dropped=dropped,
    )


@dataclass
class Manifest:
    """What the agent is told about, and whether it must search for it."""

    objects: dict[str, Relation]
    searchable: bool = False
    access: dict[str, str] = field(default_factory=dict)
    # The driver's own failure, kept for the relations whose refusal is
    # cached, so a later refusal can still be raised from what caused it.
    access_errors: dict[str, BaseException] = field(default_factory=dict)

    @classmethod
    def build(
        cls,
        relations: dict[str, Relation],
        namespace_selected: bool = False,
        semantic_stubs: dict[str, Relation] | None = None,
        prompt_limit: int = PROMPT_LIMIT,
    ) -> Manifest:
        objects = {**relations, **(semantic_stubs or {})}
        listing = "\n".join(objects).encode("utf-8")
        return cls(
            objects=objects,
            # Only a namespace selection can be large enough to be worth
            # searching: naming the tables is already the narrowing.
            searchable=namespace_selected and len(listing) > prompt_limit,
            access=dict.fromkeys(relations, "unknown"),
        )


def _terms(text: str) -> list[str]:
    lowered = text.lower()
    return list(dict.fromkeys(part for part in _WORDS.split(lowered) if part))


def search(
    manifest: Manifest,
    query: str,
    kinds: list[str] | None = None,
    limit: int = 10,
    queryable: Callable[[str], bool] | None = None,
) -> dict[str, Relation]:
    """Rank catalog objects against a query, most relevant first.

    Scores a whole-word hit and a substring hit separately, so `finance`
    matches both a schema named finance and a description mentioning
    financing.

    `limit` must be a positive whole number. With `queryable` set, at most
    `SEARCH_PROBE_LIMIT` candidates are probed, so no more than that many
    results can come back however large `limit` is.
    """
    # `bool` is an `int`, so `True` would otherwise be accepted as `1`.
    if not isinstance(limit, int) or isinstance(limit, bool) or limit < 1:
        raise ValueError("limit must be a positive whole number.")
    objects = manifest.objects
    if kinds is not None:
        if not isinstance(kinds, list) or not all(
            isinstance(kind, str) for kind in kinds
        ):
            raise TypeError("kinds must be a list of strings.")
        objects = {label: item for label, item in objects.items() if item.kind in kinds}
    query_terms = _terms(query)
    if not query_terms or not objects:
        return {}

    scored: list[tuple[float, str, Relation]] = []
    for label, item in objects.items():
        text = f"{label} {item.name} {item.description or ''}"
        terms = _terms(text)
        score = sum(term in terms for term in query_terms) + sum(
            term in text.lower() for term in query_terms
        )
        if score > 0:
            scored.append((score, label, item))
    scored.sort(key=lambda entry: entry[0], reverse=True)

    if queryable is None:
        return {label: item for _, label, item in scored[:limit]}
    results: dict[str, Relation] = {}
    for _, label, item in scored[:SEARCH_PROBE_LIMIT]:
        if queryable(label):
            results[label] = item
        if len(results) >= limit:
            break
    return results


def merge_dictionary(
    dictionary: Any,
    relations: dict[str, Relation],
    describe_relation: Callable[[TableId], list[dict[str, Any]]],
    identifier_case: str | None,
    access_check: Callable[[TableId, str], None] | None = None,
) -> MergedDictionary:
    """Fold a warehouse listing into an authored dictionary.

    The dictionary is re-keyed to the labels the agent will use, and each
    authored table records which relation it matched so definitions can be
    bound to physical names later.

    Raises when an authored table matches more than one selected relation,
    or two authored tables match the same one: the author has to say which
    they meant.
    """
    if dictionary is None or not dictionary.tables:
        return MergedDictionary(dictionary, relations, None)

    matches = _dictionary_matches(dictionary, relations, identifier_case)
    dictionary = dictionary.model_copy(deep=True)
    dictionary.relationships = _scope_relationships(dictionary, matches)

    tables: dict[str, Any] = {}
    column_matches: dict[str, dict[str, str | None]] = {}
    relations = dict(relations)
    for authored_name, label in matches.items():
        if label is None:
            continue
        relation = relations[label]
        if access_check is not None:
            access_check(relation.id, label)
        columns = describe_relation(relation.id)
        relations[label] = replace(relation, columns=columns)
        table, matched = _merge_table(
            dictionary.tables[authored_name],
            authored_name,
            label,
            relations[label],
            columns,
            identifier_case,
        )
        tables[label] = table
        column_matches[authored_name] = matched
    dictionary.tables = tables

    return MergedDictionary(
        dictionary=dictionary,
        relations=relations,
        definition_bindings={"tables": matches, "columns": column_matches},
    )


def _scope_relationships(dictionary: Any, matches: dict[str, str | None]) -> list[Any]:
    """Drop relationships that mention a table the selection left out."""
    dropped = [name for name, label in matches.items() if label is None]
    if not dropped:
        return dictionary.relationships
    kept = []
    for relationship in dictionary.relationships:
        text = " ".join(
            part for part in (relationship.join, relationship.description) if part
        )
        if not any(_mentions(text, name) for name in dropped):
            kept.append(relationship)
    return kept


def _mentions(text: str, name: str) -> bool:
    return (
        re.search(rf"(?<!\w){re.escape(name)}(?!\w)", text, re.IGNORECASE) is not None
    )


def _dictionary_matches(
    dictionary: Any, relations: dict[str, Relation], identifier_case: str | None
) -> dict[str, str | None]:
    matches: dict[str, str | None] = {}
    claimed: dict[str, str] = {}
    for authored_name in dictionary.tables:
        label = _match_one(authored_name, relations, identifier_case)
        matches[authored_name] = label
        if label is None:
            continue
        if label in claimed:
            raise ValueError(
                f"Authored tables {claimed[label]!r} and {authored_name!r} "
                f"both match selected relation {label!r}."
            )
        claimed[label] = authored_name
    return matches


def _match_one(
    authored_name: str, relations: dict[str, Relation], identifier_case: str | None
) -> str | None:
    """Match an authored table name to a selected relation, or nothing.

    Exact first, then case-folded, then the relation's own name, then a
    qualified suffix. More than one candidate at any step is an error: the
    author has to say which they meant.
    """
    labels = list(relations)
    if authored_name in labels:
        return authored_name

    authored = normalize_identifier(authored_name, identifier_case)
    folded = [
        label
        for label in labels
        if normalize_identifier(label, identifier_case) == authored
    ]
    if len(folded) == 1:
        return folded[0]
    if len(folded) > 1:
        _abort_ambiguous(authored_name, folded)

    relative = [
        label
        for label in labels
        if normalize_identifier(relations[label].name, identifier_case) == authored
    ]
    if not relative and "." in authored_name:
        suffix = authored_name.split(".")
        relative = [
            label
            for label in labels
            if has_suffix(relations[label], suffix, identifier_case)
        ]
    if len(relative) > 1:
        _abort_ambiguous(authored_name, relative)
    return relative[0] if relative else None


def has_suffix(
    relation: Relation, suffix: list[str], identifier_case: str | None
) -> bool:
    path = relation.id.parts
    if len(suffix) > len(path):
        return False
    return normalize_identifier(path[-len(suffix) :], identifier_case) == (
        normalize_identifier(suffix, identifier_case)
    )


def _abort_ambiguous(authored_name: str, candidates: list[str]) -> None:
    listed = ", ".join(repr(item) for item in sorted(candidates))
    raise ValueError(
        f"Authored table {authored_name!r} matches more than one selected "
        f"relation: {listed}. Use its fully qualified name in the data "
        f"dictionary."
    )


def _merge_table(
    authored: Any,
    authored_name: str,
    selected_name: str,
    relation: Relation,
    columns: list[dict[str, Any]],
    identifier_case: str | None,
) -> tuple[Any, dict[str, str | None]]:
    table = authored.model_copy(deep=True)
    table.description = _authored_prose(table.description, relation.description)
    # The warehouse's kind wins; an authored one survives when it has none.
    table.kind = relation.kind or table.kind
    merged, matches = _merge_columns(table.columns, columns, identifier_case)
    table.columns = merged
    if authored_name != selected_name:
        # Kept so first touch and relationship matching can still find the
        # name the author wrote, after re-keying to the warehouse label.
        table.authored_name = authored_name
    return table, matches


def _merge_columns(
    authored: dict[str, Any],
    discovered: list[dict[str, Any]],
    identifier_case: str | None,
) -> tuple[dict[str, Any], dict[str, str | None]]:
    """Warehouse columns first in their own order, then authored-only ones."""
    from .._data_dictionary import Column

    out: dict[str, Any] = {}
    for row in discovered:
        description = row.get("description") or None
        out[row["column"]] = Column(
            type=row.get("type"),
            nullable=row.get("nullable"),
            description=description,
        )
    matches: dict[str, str | None] = dict.fromkeys(authored, None)

    for authored_name, authored_column in authored.items():
        if authored_name in out:
            candidates = [authored_name]
        else:
            authored_key = normalize_identifier(authored_name, identifier_case)
            candidates = [
                name
                for name in out
                if normalize_identifier(name, identifier_case) == authored_key
            ]
        if len(candidates) > 1:
            listed = ", ".join(repr(name) for name in candidates)
            raise ValueError(
                f"Authored column {authored_name!r} matches more than one "
                f"discovered column: {listed}."
            )
        if not candidates:
            out[authored_name] = authored_column
            continue

        discovered_name = candidates[0]
        matches[authored_name] = discovered_name
        found = out[discovered_name]
        merged = found.model_copy(
            update={
                key: value
                for key, value in authored_column.model_dump().items()
                if value is not None
            }
        )
        # The warehouse is authoritative about shape, the author about prose.
        merged.type = found.type
        merged.nullable = found.nullable
        merged.description = _authored_prose(
            authored_column.description, found.description
        )
        out[discovered_name] = merged
    return out, matches


def _authored_prose(authored: str | None, discovered: str | None) -> str | None:
    return authored if authored else discovered
