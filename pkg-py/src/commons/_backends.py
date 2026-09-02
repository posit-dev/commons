"""What a data source needs from whatever holds its tables.

Two implementations: a SQLAlchemy `Engine` for connections a caller supplies
(D2 makes the engine the connection currency), and a raw DuckDB connection for
the in-process database commons builds from frames and pins. The raw path is
not routed through SQLAlchemy because the lockdown and the deferred pin writes
are DuckDB-specific and gain nothing from it.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import TYPE_CHECKING, Any, Protocol

import duckdb
import sqlalchemy

from ._duckdb import quote_identifier

if TYPE_CHECKING:
    from ._data_source import TableId

__all__ = ["Backend", "DuckDBBackend", "EngineBackend"]


class Backend(Protocol):
    def query(self, sql: str) -> list[dict[str, Any]]: ...

    def list_tables(self) -> list[str]: ...

    def quote(self, table_id: TableId) -> str: ...

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

    def query(self, sql: str) -> list[dict[str, Any]]:
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
        parts = [table_id.schema, table_id.table] if table_id.schema else [table_id.table]
        return ".".join(quote_identifier(part) for part in parts)

    def dialect(self) -> str:
        return "duckdb"

    def inspector(self) -> Callable[[TableId], bool] | None:
        # Frame and pin sources build their own tables, so nothing reaches
        # the existence check by this route.
        return None


class EngineBackend:
    def __init__(self, engine: sqlalchemy.Engine) -> None:
        self._engine = engine

    @property
    def engine(self) -> sqlalchemy.Engine:
        return self._engine

    def query(self, sql: str) -> list[dict[str, Any]]:
        with self._engine.connect() as connection:
            result = connection.execute(sqlalchemy.text(sql))
            return [dict(row) for row in result.mappings()]

    def list_tables(self) -> list[str]:
        return list(sqlalchemy.inspect(self._engine).get_table_names())

    def quote(self, table_id: TableId) -> str:
        preparer = self._engine.dialect.identifier_preparer
        quoted = preparer.quote(table_id.table)
        if table_id.schema:
            return f"{preparer.quote_schema(table_id.schema)}.{quoted}"
        return quoted

    def dialect(self) -> str:
        return self._engine.dialect.name

    def inspector(self) -> Callable[[TableId], bool] | None:
        inspector = sqlalchemy.inspect(self._engine)

        def exists(table_id: TableId) -> bool:
            return inspector.has_table(table_id.table, schema=table_id.schema)

        return exists
