"""What a data source needs from whatever holds its tables.

The protocol exists so the in-process DuckDB commons builds from frames can
hold a raw connection while a caller-supplied connection stays a SQLAlchemy
engine (D2 makes the engine the connection currency). The raw path is not
routed through SQLAlchemy because the lockdown and the deferred pin writes are
DuckDB-specific and gain nothing from it.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any, Protocol

import duckdb

from ._duckdb import quote_identifier

if TYPE_CHECKING:
    from ._data_source import TableId

__all__ = ["Backend", "DuckDBBackend"]


class Backend(Protocol):
    def query(self, sql: str) -> list[dict[str, Any]]: ...

    def list_tables(self) -> list[str]: ...

    def quote(self, table_id: TableId) -> str: ...

    def dialect(self) -> str: ...


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
