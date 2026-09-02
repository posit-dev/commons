"""The set of tables available to a commons agent.

``DataSource`` is a dataclass rather than a pydantic model (D8): its checks run
against live external state, which pydantic cannot express. Validation lives in
the constructor functions, which is where a bad argument can still be named.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import sqlalchemy

from . import _duckdb
from ._backends import Backend, DuckDBBackend, EngineBackend
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

    @classmethod
    def from_engine(cls, engine: sqlalchemy.Engine, tables: Any = None) -> DataSource:
        """Query a caller's database directly. Nothing is copied.

        With `tables` unset the backend's own listing is taken as given: it
        reports what exists, so there is nothing to check and no round trip
        worth paying for.
        """
        backend = EngineBackend(engine)
        if tables is None:
            discovered = backend.list_tables()
            return cls(
                backend=backend,
                tables=discovered,
                table_ids={name: TableId(table=name) for name in discovered},
            )

        registry = normalize_table_registry(tables)
        _check_tables_exist(backend, registry)
        return cls(backend=backend, tables=list(registry), table_ids=registry)

    def query(self, sql: str) -> list[dict[str, Any]]:
        """Run one read-only statement, rejecting anything else first."""
        check_query(sql, dialect=self.backend.dialect())
        return self.backend.query(sql)

    def dialect(self) -> str:
        """A hint for the system prompt, not a contract."""
        return self.backend.dialect()


def data_source(*args: Any, tables: Any = None, **frames: Any) -> DataSource:
    """Create a data source from an engine, a pins board, or named frames.

    A thin dispatcher over the constructors, which are the documented way in.
    """
    if args and frames:
        raise TypeError(
            "Pass either a connection or named data frames, not both. "
            f"Got a positional argument and the frames {sorted(frames)}."
        )
    if len(args) > 1:
        raise TypeError(
            f"data_source() accepts one positional argument, got {len(args)}."
        )
    if args:
        return _from_positional(args[0], tables)
    return DataSource.from_frames(**frames)


def _from_positional(value: Any, tables: Any) -> DataSource:
    if isinstance(value, sqlalchemy.Engine):
        return DataSource.from_engine(value, tables=tables)
    raise TypeError(
        "data_source() takes a SQLAlchemy Engine, a pins board, or named data "
        f"frames. Got {type(value).__name__}."
    )


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


def normalize_table_registry(tables: Any) -> dict[str, TableId]:
    """Turn a `tables` argument into label -> `TableId`.

    Strings containing dots are read as schema-qualified. A literal table name
    containing a dot is spelled as a `TableId`.
    """
    if isinstance(tables, (str, TableId)):
        entries: list[Any] = [tables]
    elif isinstance(tables, (list, tuple)):
        entries = list(tables)
    else:
        raise TypeError(
            "tables must be a string, a TableId, or a list of them, got "
            f"{type(tables).__name__}."
        )

    registry: dict[str, TableId] = {}
    for entry in entries:
        table_id = _table_entry_id(entry)
        if table_id.label in registry:
            raise ValueError(
                f"tables must not contain duplicate labels: {table_id.label}."
            )
        registry[table_id.label] = table_id
    return registry


def _table_entry_id(entry: Any) -> TableId:
    if isinstance(entry, TableId):
        if not entry.table or (entry.schema is not None and not entry.schema):
            raise ValueError("TableId entries must not contain empty name components.")
        return entry
    if not isinstance(entry, str) or not entry:
        raise TypeError(
            f"Each entry in tables must be a table name or a TableId, got {entry!r}."
        )

    parts = entry.split(".")
    if any(part == "" for part in parts):
        raise ValueError(
            "Schema-qualified entries in tables must not contain empty name "
            f"components: {entry!r}."
        )
    if len(parts) == 1:
        return TableId(table=entry)
    return TableId(table=parts[-1], schema=".".join(parts[:-1]))


def _check_tables_exist(backend: Backend, registry: dict[str, TableId]) -> None:
    """Fail construction naming every table the connection does not have."""
    # One zero-row probe per table costs a round trip each, which dominates
    # startup against a remote warehouse. Probe them all in one statement and
    # fall back to per-table probes only to name the ones that are missing.
    probe = " UNION ALL ".join(
        f"SELECT 1 FROM {backend.quote(table_id)} WHERE 1 = 0"
        for table_id in registry.values()
    )
    try:
        backend.query(probe)
    except Exception as error:
        missing = _missing_tables(backend, registry)
        if not missing:
            # The probe failed for some other reason, and that error is more
            # informative than anything this function could say.
            raise
        available = ", ".join(sorted(backend.list_tables()))
        raise ValueError(
            f"tables names tables that are missing from the connection: "
            f"{', '.join(missing)}. Available tables: {available}."
        ) from error


def _missing_tables(backend: Backend, registry: dict[str, TableId]) -> list[str]:
    missing = []
    for label, table_id in registry.items():
        try:
            backend.query(f"SELECT 1 FROM {backend.quote(table_id)} WHERE 1 = 0")
        except Exception:  # noqa: BLE001 - absence is the answer, not the error
            missing.append(label)
    return missing
