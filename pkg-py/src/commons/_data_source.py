"""The set of tables available to a commons agent.

``DataSource`` is a dataclass rather than a pydantic model (D8): its checks run
against live external state, which pydantic cannot express. Validation lives in
the constructor functions, which is where a bad argument can still be named.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from . import _duckdb
from ._backends import Backend, DuckDBBackend
from ._sql_guard import check_query

__all__ = ["DataSource", "TableId", "data_source", "list_tables"]


@dataclass(frozen=True)
class TableId:
    """A table's identity, schema-qualified where the backend has schemas."""

    table: str
    schema: str | None = None

    @property
    def label(self) -> str:
        """The name the agent uses for this table."""
        return f"{self.schema}.{self.table}" if self.schema else self.table


@dataclass
class DataSource:
    """Tables an agent can query, and the dictionary that describes them."""

    backend: Backend
    tables: list[str]
    table_ids: dict[str, TableId] = field(default_factory=dict)

    @classmethod
    def from_frames(cls, **frames: Any) -> DataSource:
        """Load named data frames into a locked-down in-process DuckDB."""
        _check_named_frames(frames)
        con = _duckdb.connect()
        for position, (name, frame) in enumerate(frames.items()):
            # The registered relation gets a generated name rather than one
            # derived from the caller's, so nothing user-supplied is ever
            # spliced into SQL unquoted.
            staging = f"_commons_input_{position}"
            con.register(staging, frame)
            con.execute(
                f"CREATE TABLE {_duckdb.quote_identifier(name)} AS SELECT * FROM {staging}"
            )
            con.unregister(staging)
        _duckdb.lock_down(con)

        tables = list(frames)
        return cls(
            backend=DuckDBBackend(con),
            tables=tables,
            table_ids={name: TableId(table=name) for name in tables},
        )

    def query(self, sql: str) -> list[dict[str, Any]]:
        """Run one read-only statement, rejecting anything else first."""
        check_query(sql, dialect=self.backend.dialect())
        return self.backend.query(sql)

    def dialect(self) -> str:
        """A hint for the system prompt, not a contract."""
        return self.backend.dialect()


def data_source(*args: Any, **frames: Any) -> DataSource:
    """Create a data source from named data frames.

    A thin dispatcher over the constructors, which are the documented way in.
    Engine and pins-board sources land alongside `DataSource.from_engine` and
    `DataSource.from_board`.
    """
    if args:
        raise TypeError(
            "data_source() takes named data frames. Got a positional "
            f"{type(args[0]).__name__}."
        )
    return DataSource.from_frames(**frames)


def list_tables(source: DataSource) -> list[str]:
    """The table names an agent can query on `source`."""
    if not isinstance(source, DataSource):
        raise TypeError(f"Expected a DataSource, got {type(source).__name__}.")
    return list(source.tables)


def _check_named_frames(frames: dict[str, Any]) -> None:
    if not frames:
        raise TypeError(
            "data_source() needs at least one named data frame, a connection, "
            "or a pins board."
        )
    for name, frame in frames.items():
        if not _is_frame(frame):
            raise TypeError(
                f"{name} must be a pandas or polars data frame, got "
                f"{type(frame).__name__}."
            )


def _is_frame(value: Any) -> bool:
    # Duck-typed rather than imported: pandas and polars are both optional at
    # this boundary, and DuckDB accepts either through the same registration.
    return hasattr(value, "__dataframe__") or hasattr(value, "columns")
