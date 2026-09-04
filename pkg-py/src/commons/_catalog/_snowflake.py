"""Reading a Snowflake catalog.

The queries live here; interpreting their rows is separated out into pure
functions, so the row handling can be tested against real `SHOW OBJECTS` and
`DESC TABLE` output without a warehouse.
"""

from __future__ import annotations

from typing import Any

from .._data_source import TableId
from ._core import Relation, Selector, id_type

__all__ = [
    "SHOW_ROW_LIMIT",
    "check_show_complete",
    "columns_from_desc",
    "current_namespace",
    "describe_relation",
    "exact_relation",
    "is_snowflake",
    "list_relations",
    "relations_from_show",
]

# SHOW caps its output, and a full page cannot be told apart from a page that
# happened to fill, so a full page is refused rather than silently truncated.
SHOW_ROW_LIMIT = 10_000

_RELATION_KINDS = {"TABLE", "VIEW"}


def is_snowflake(backend: Any) -> bool:
    return backend.dialect() == "snowflake"


def _quote(name: str) -> str:
    """Snowflake quotes with double quotes and doubles any inside."""
    escaped = str(name).replace('"', '""')
    return f'"{escaped}"'


def _quote_path(parts: list[str]) -> str:
    return ".".join(_quote(part) for part in parts)


def _quote_string(value: str) -> str:
    escaped = str(value).replace("'", "''")
    return f"'{escaped}'"


def _lower_keys(row: dict[str, Any]) -> dict[str, Any]:
    """Some drivers return Snowflake's column names upper-cased."""
    return {str(key).lower(): value for key, value in row.items()}


def _prose(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def check_show_complete(rows: list[Any], objects: str) -> None:
    if len(rows) >= SHOW_ROW_LIMIT:
        raise ValueError(
            f"Snowflake returned {SHOW_ROW_LIMIT} {objects}, so the catalog "
            f"selection might be truncated. Narrow tables to a smaller "
            f"database or schema prefix."
        )


def relations_from_show(rows: list[dict[str, Any]]) -> list[Relation]:
    """Tables and views from `SHOW OBJECTS`, ignoring stages and the rest."""
    out: list[Relation] = []
    for raw in rows:
        row = _lower_keys(raw)
        if str(row.get("kind", "")).upper() not in _RELATION_KINDS:
            continue
        out.append(
            Relation(
                id=TableId(
                    catalog=row["database_name"],
                    schema=row["schema_name"],
                    table=row["name"],
                ),
                kind=str(row["kind"]).lower(),
                description=_prose(row.get("comment")),
            )
        )
    return out


def columns_from_desc(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Columns from `DESC TABLE`, which also reports expressions and keys."""
    out: list[dict[str, Any]] = []
    for raw in rows:
        row = _lower_keys(raw)
        if str(row.get("kind", "")).upper() != "COLUMN":
            continue
        out.append(
            {
                "column": row["name"],
                "type": row["type"],
                "nullable": row.get("null?") == "Y",
                "description": _prose(row.get("comment")),
            }
        )
    return out


def current_namespace(backend: Any) -> Selector:
    """The database and schema the connection is already pointed at."""
    rows = backend.query(
        "SELECT CURRENT_DATABASE() AS catalog, CURRENT_SCHEMA() AS schema"
    )
    if len(rows) != 1:
        raise ValueError("Snowflake returned an invalid current namespace.")
    row = _lower_keys(rows[0])
    catalog, schema = row.get("catalog"), row.get("schema")
    if not catalog or not schema:
        raise ValueError(
            "The Snowflake connection has no current database and schema. Set "
            "both on the connection, or name them in tables."
        )
    return Selector(catalog=catalog, schema=schema)


def _namespace_target(selector: Selector) -> str:
    if selector.schema is None:
        return f"IN DATABASE {_quote(selector.catalog or '')}"
    parts = [part for part in (selector.catalog, selector.schema) if part]
    return f"IN SCHEMA {_quote_path(parts)}"


def list_relations(backend: Any, selector: Selector) -> list[Relation]:
    rows = backend.query(f"SHOW OBJECTS {_namespace_target(selector)}")
    check_show_complete(rows, "relations")
    return relations_from_show(rows)


def exact_relation(backend: Any, selector: Selector) -> Relation | None:
    """One named relation, matched within the schema that holds it.

    `SHOW OBJECTS LIKE` matches without regard to case, so the reply is
    filtered by name. The returned relation keeps the identity the warehouse
    reported while taking the label the caller asked for.
    """
    if id_type(selector) != "relation":
        raise ValueError("exact_relation needs a selector naming a table.")
    namespace = selector
    if selector.schema is None:
        namespace = current_namespace(backend)
    requested = TableId(
        table=selector.table or "",
        schema=namespace.schema,
        catalog=namespace.catalog,
    )
    rows = backend.query(
        f"SHOW OBJECTS LIKE {_quote_string(selector.table or '')} "
        f"{_namespace_target(Selector(namespace.catalog, namespace.schema))}"
    )
    for relation in relations_from_show(rows):
        if relation.id.table == requested.table:
            return Relation(
                id=requested,
                kind=relation.kind,
                description=relation.description,
                identity=relation.id,
            )
    return None


def describe_relation(backend: Any, table_id: TableId) -> list[dict[str, Any]]:
    rows = backend.query(f"DESC TABLE {_quote_path(table_id.parts)}")
    return columns_from_desc(rows)
