"""Reading a Databricks catalog.

Unity Catalog is read through `system.information_schema`, which is a plain
query rather than a `SHOW`. The legacy `hive_metastore` is not in there at
all and needs `SHOW TABLES`, which is why the listing forks on the catalog
name.
"""

from __future__ import annotations

from typing import Any

from .._data_source import TableId
from ._core import Relation, Selector, id_type

__all__ = [
    "columns_from_describe",
    "current_namespace",
    "describe_relation",
    "exact_relation",
    "is_databricks",
    "list_relations",
    "relations_from_information_schema",
]

_HIVE = "hive_metastore"


def is_databricks(backend: Any) -> bool:
    return backend.dialect() == "databricks"


def _quote(name: str) -> str:
    """Databricks quotes with backticks and doubles any inside."""
    escaped = str(name).replace("`", "``")
    return f"`{escaped}`"


def _quote_path(parts: list[str]) -> str:
    return ".".join(_quote(part) for part in parts)


def _quote_string(value: str) -> str:
    escaped = str(value).replace("'", "''")
    return f"'{escaped}'"


def _lower_keys(row: dict[str, Any]) -> dict[str, Any]:
    return {str(key).lower(): value for key, value in row.items()}


def _prose(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def current_namespace(backend: Any) -> Selector:
    rows = backend.query(
        "SELECT CURRENT_CATALOG() AS catalog, CURRENT_SCHEMA() AS schema"
    )
    if len(rows) != 1:
        raise ValueError("Databricks returned an invalid current namespace.")
    row = _lower_keys(rows[0])
    catalog, schema = row.get("catalog"), row.get("schema")
    if not catalog or not schema:
        raise ValueError(
            "The Databricks connection has no current catalog and schema. Set "
            "both on the connection, or name them in tables."
        )
    return Selector(catalog=catalog, schema=schema)


def _complete(backend: Any, selector: Selector) -> Selector:
    """Fill in the catalog from the connection when the selection omits it."""
    if selector.catalog:
        return selector
    current = current_namespace(backend)
    return Selector(
        catalog=current.catalog,
        schema=selector.schema if selector.schema else current.schema,
        table=selector.table,
    )


def relations_from_information_schema(
    rows: list[dict[str, Any]],
) -> list[Relation]:
    """Relations from `system.information_schema.tables`.

    A metric view reports as a view here. Telling the two apart needs the ODBC
    object type, which only matters once metric views are supported; see kata
    gcgj.
    """
    out: list[Relation] = []
    for raw in rows:
        row = _lower_keys(raw)
        table_type = str(row.get("table_type") or "")
        kind = "view" if "view" in table_type.lower() else "table"
        out.append(
            Relation(
                id=TableId(
                    catalog=row["table_catalog"],
                    schema=row["table_schema"],
                    table=row["table_name"],
                ),
                kind=kind,
                description=_prose(row.get("comment")),
            )
        )
    return out


def _list_unity_relations(backend: Any, selector: Selector) -> list[Relation]:
    predicates = [
        f"table_catalog = {_quote_string(selector.catalog or '')}",
        # Listing the information schema itself would describe the catalog
        # rather than the data in it.
        "table_schema <> 'information_schema'",
    ]
    if selector.schema:
        predicates.append(f"table_schema = {_quote_string(selector.schema)}")
    if selector.table:
        predicates.append(f"table_name = {_quote_string(selector.table)}")
    rows = backend.query(
        "SELECT table_catalog, table_schema, table_name, table_type, comment "
        "FROM system.information_schema.tables WHERE "
        + " AND ".join(predicates)
        + " ORDER BY table_catalog, table_schema, table_name"
    )
    return relations_from_information_schema(rows)


def _list_hive_relations(backend: Any, selector: Selector) -> list[Relation]:
    if not selector.schema:
        raise ValueError(
            f"Selecting {_HIVE!r} needs a schema: its tables are not in "
            f"system.information_schema, so there is nothing to list a whole "
            f"catalog from."
        )
    rows = backend.query(
        f"SHOW TABLES IN {_quote_path([selector.catalog or _HIVE, selector.schema])}"
    )
    return [
        Relation(
            id=TableId(
                catalog=selector.catalog,
                schema=selector.schema,
                table=_lower_keys(row)["tablename"],
            )
        )
        for row in rows
    ]


def _is_hive(selector: Selector) -> bool:
    return (selector.catalog or "").lower() == _HIVE


def list_relations(backend: Any, selector: Selector) -> list[Relation]:
    selector = _complete(backend, selector)
    if _is_hive(selector):
        return _list_hive_relations(backend, selector)
    return _list_unity_relations(backend, selector)


def exact_relation(backend: Any, selector: Selector) -> Relation | None:
    if id_type(selector) != "relation":
        raise ValueError("exact_relation needs a selector naming a table.")
    complete = _complete(backend, selector)
    if _is_hive(complete):
        relations = _list_hive_relations(
            backend, Selector(complete.catalog, complete.schema)
        )
    else:
        relations = _list_unity_relations(backend, complete)
    requested = TableId(
        table=complete.table or "",
        schema=complete.schema,
        catalog=complete.catalog,
    )
    for relation in relations:
        if relation.id.table == requested.table:
            return Relation(
                id=requested,
                kind=relation.kind,
                description=relation.description,
                identity=relation.id,
            )
    return None


def _column_nullability(backend: Any, table_id: TableId) -> dict[str, bool]:
    """Nullability, which `DESCRIBE TABLE` does not report.

    hive_metastore has no information schema to ask, so its columns keep an
    unknown nullability rather than a guessed one.
    """
    if (table_id.catalog or "").lower() == _HIVE:
        return {}
    predicates = " AND ".join(
        [
            f"table_catalog = {_quote_string(table_id.catalog or '')}",
            f"table_schema = {_quote_string(table_id.schema or '')}",
            f"table_name = {_quote_string(table_id.table)}",
        ]
    )
    rows = backend.query(
        "SELECT column_name, is_nullable "
        f"FROM system.information_schema.columns WHERE {predicates}"
    )
    out: dict[str, bool] = {}
    for raw in rows:
        row = _lower_keys(raw)
        flag = str(row.get("is_nullable") or "").upper()
        if flag in ("YES", "NO"):
            out[row["column_name"]] = flag == "YES"
    return out


def columns_from_describe(
    rows: list[dict[str, Any]], nullable: dict[str, bool] | None = None
) -> list[dict[str, Any]]:
    """Columns from `DESCRIBE TABLE`.

    The reply appends partition and detail sections after a row whose name
    starts with `#`, so reading past that turns section headings into columns.
    """
    nullable = nullable or {}
    out: list[dict[str, Any]] = []
    for raw in rows:
        row = _lower_keys(raw)
        name = row.get("col_name")
        if isinstance(name, str) and name.startswith("#"):
            break
        if not name:
            continue
        out.append(
            {
                "column": name,
                "type": row.get("data_type"),
                "nullable": nullable.get(name),
                "description": _prose(row.get("comment")),
            }
        )
    return out


def describe_relation(backend: Any, table_id: TableId) -> list[dict[str, Any]]:
    rows = backend.query(f"DESCRIBE TABLE {_quote_path(table_id.parts)}")
    return columns_from_describe(rows, _column_nullability(backend, table_id))
