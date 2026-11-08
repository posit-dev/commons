"""What a data source needs from whatever holds its tables.

Two implementations: a SQLAlchemy `Engine` for connections a caller supplies
(D2 makes the engine the connection currency), and a raw DuckDB connection for
the in-process database commons builds from frames and pins. The raw path is
not routed through SQLAlchemy because the lockdown and the deferred pin writes
are DuckDB-specific and gain nothing from it.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from typing import TYPE_CHECKING, Any, Protocol

import duckdb
import sqlalchemy

from ._duckdb import quote_identifier

if TYPE_CHECKING:
    from ._data_source import TableId

__all__ = ["Backend", "DuckDBBackend", "EngineBackend"]


class Backend(Protocol):
    def query(
        self, sql: str, params: Mapping[str, Any] | None = None
    ) -> list[dict[str, Any]]:
        """Run one statement; `params` binds named values written `:name`."""
        ...

    def list_tables(self) -> list[str]: ...

    def quote(self, table_id: TableId) -> str: ...

    def columns(self, table_id: TableId) -> list[dict[str, Any]]:
        """A relation's columns, in the shape a catalog listing reports them.

        For the backends a warehouse catalog never describes, since there the
        listing itself already carries the columns.
        """
        ...

    def dialect(self) -> str: ...

    def inspector(self) -> Callable[[TableId], bool] | None:
        """A predicate answering whether a table exists, if the backend can.

        Used to tell a table that is genuinely absent from one that a failing
        query only made look absent. A backend that cannot answer returns
        None, and the caller re-raises the original error rather than guessing.
        """
        ...


class DuckDBBackend:
    def __init__(self, con: duckdb.DuckDBPyConnection) -> None:
        self._con = con

    @property
    def connection(self) -> duckdb.DuckDBPyConnection:
        return self._con

    def query(
        self, sql: str, params: Mapping[str, Any] | None = None
    ) -> list[dict[str, Any]]:
        if params:
            raise ValueError("The DuckDB backend does not bind parameters.")
        cursor = self._con.execute(sql)
        if cursor.description is None:
            return []
        columns = [column[0] for column in cursor.description]
        return [dict(zip(columns, row)) for row in cursor.fetchall()]

    def list_tables(self) -> list[str]:
        rows = self._con.execute(
            "SELECT table_name FROM information_schema.tables "
            "WHERE table_schema = 'main' ORDER BY table_name"
        ).fetchall()
        return [row[0] for row in rows]

    def quote(self, table_id: TableId) -> str:
        return ".".join(quote_identifier(part) for part in table_id.parts)

    def columns(self, table_id: TableId) -> list[dict[str, Any]]:
        # A zero-row select, because the cursor description carries DuckDB's
        # own type names and no round trip to a metadata table is needed.
        cursor = self._con.execute(f"SELECT * FROM {self.quote(table_id)} LIMIT 0")
        description = cursor.description or ()
        return [{"column": name, "type": str(kind)} for name, kind, *_ in description]

    def dialect(self) -> str:
        return "duckdb"

    def inspector(self) -> Callable[[TableId], bool] | None:
        # Frame and pin sources build their own tables, so nothing reaches
        # the existence check by this route.
        return None


def escape_colons(sql: str, params: Mapping[str, Any] | None = None) -> str:
    """Escape the colons SQLAlchemy's `text()` must not read as binds.

    `text()` reads `:name` as a bind wherever it appears, quotes and comments
    included, and drops the backslash of a `\\:` it finds. It also removes
    each escape it reads, so an escaped colon reaches the warehouse as it
    was written. Without `params` every colon is escaped, which needs no
    reading of the SQL at all. With them, only colons inside quotes are:
    values are bound only in SQL commons compiles for Snowflake, which has
    no comments, and whose literals escape with a backslash and a doubled
    quote.
    """
    if not params:
        return sql.replace(":", "\\:")
    out: list[str] = []
    quote: str | None = None
    i = 0
    while i < len(sql):
        char = sql[i]
        if quote is None:
            if char in "'\"":
                quote = char
            out.append(char)
        elif char == ":":
            out.append("\\:")
        elif char == "\\" and quote == "'" and i + 1 < len(sql):
            out.append(sql[i : i + 2])
            i += 1
        elif char == quote:
            if sql[i + 1 : i + 2] == quote:
                out.append(char * 2)
                i += 1
            else:
                quote = None
                out.append(char)
        else:
            out.append(char)
        i += 1
    return "".join(out)


def _databricks_rows(
    connection: sqlalchemy.Connection,
    sql: str,
    params: Mapping[str, Any] | None = None,
) -> list[dict[str, Any]]:
    # The Databricks connector builds rows through pandas' nullable floats,
    # which read NaN as missing, so the connector returns None to SQLAlchemy
    # for a NaN double.
    # The connector's Arrow table keeps NaN.
    cursor = connection.connection.cursor()
    try:
        if params:
            cursor.execute(sql, dict(params))
        else:
            cursor.execute(sql)
        if cursor.description is None:
            return []
        return cursor.fetchall_arrow().to_pylist()
    finally:
        cursor.close()


class EngineBackend:
    def __init__(self, engine: sqlalchemy.Engine) -> None:
        self._engine = engine

    @property
    def engine(self) -> sqlalchemy.Engine:
        return self._engine

    def query(
        self, sql: str, params: Mapping[str, Any] | None = None
    ) -> list[dict[str, Any]]:
        with self._engine.connect() as connection:
            if self.dialect() == "databricks":
                return _databricks_rows(connection, sql, params)
            result = connection.execute(
                sqlalchemy.text(escape_colons(sql, params)), dict(params or {})
            )
            return [dict(row) for row in result.mappings()]

    def list_tables(self) -> list[str]:
        return list(sqlalchemy.inspect(self._engine).get_table_names())

    def quote(self, table_id: TableId) -> str:
        # Quote every part of the table name. Required because Snowflake converts unquoted
        # names to upper case, which would cause a table name with lowercase to not be found.
        preparer = self._engine.dialect.identifier_preparer
        return ".".join(preparer.quote_identifier(part) for part in table_id.parts)

    def columns(self, table_id: TableId) -> list[dict[str, Any]]:
        inspector = sqlalchemy.inspect(self._engine)
        # SQLAlchemy takes every level above the table as one dotted
        # `schema`, so a catalog is joined onto it rather than dropped.
        outer = ".".join(table_id.parts[:-1])
        return [
            {
                "column": column["name"],
                "type": str(column["type"]),
                "nullable": column.get("nullable"),
                "description": column.get("comment"),
            }
            for column in inspector.get_columns(table_id.table, schema=outer or None)
        ]

    def dialect(self) -> str:
        return self._engine.dialect.name

    def table_types(self, catalog: str, schema: str | None) -> dict[tuple[str, str], str] | None:
        """Each table's type as Databricks' table metadata reports it.

        `information_schema` can report a metric view as a plain view; the
        connector's table metadata names it. None off Databricks, or when the
        metadata cannot be read.
        """
        if self.dialect() != "databricks":
            return None
        try:
            with self._engine.connect() as connection:
                cursor = connection.connection.cursor()
                try:
                    cursor.tables(catalog_name=catalog, schema_name=schema)
                    rows = cursor.fetchall()
                finally:
                    cursor.close()
        except Exception:  # noqa: BLE001 - the table type is the fallback
            return None
        return {(str(row[1]), str(row[2])): str(row[3]) for row in rows}

    def inspector(self) -> Callable[[TableId], bool] | None:
        inspector = sqlalchemy.inspect(self._engine)

        def exists(table_id: TableId) -> bool:
            # SQLAlchemy takes every level above the table as one dotted
            # `schema`, so a catalog is joined onto it rather than dropped.
            outer = ".".join(table_id.parts[:-1])
            return inspector.has_table(table_id.table, schema=outer or None)

        return exists
