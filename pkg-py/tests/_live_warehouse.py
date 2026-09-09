"""Reaching a real Snowflake or Databricks, when one is configured.

Every other warehouse test in this suite drives a fake that replays canned
rows, which checks how commons reads a listing but not what a warehouse
actually returns. This module is the other half: it builds a SQLAlchemy
engine from the environment and loads the same rows into DuckDB, so the two
engines' answers can be compared.

The variable names come from `tests/shared/live-warehouse-env.json` rather
than being written here, because the R suite reads the same contract and a
name spelled twice is a name that can drift. Nothing here fails when a
warehouse is absent: an unconfigured backend, or a missing driver package,
skips.

Bring a warehouse to the expected state with
`scripts/provision-live-warehouse.py`.
"""

from __future__ import annotations

import datetime as dt
import math
import os
from dataclasses import dataclass
from typing import Any

import pytest
import sqlalchemy

from commons._backends import EngineBackend
from commons._catalog import _databricks, _snowflake
from commons._data_source import TableId
from tests._shared import load_shared_fixture

__all__ = [
    "LiveWarehouse",
    "comparable",
    "duckdb_fixture_connection",
    "matches",
    "require_live_warehouse",
]

_ENV = load_shared_fixture("live-warehouse-env")
_ROWS = load_shared_fixture("live-warehouse-rows")

_READER_QUOTING = {
    "databricks": _databricks._quote_path,
    "snowflake": _snowflake._quote_path,
}

# Doubles JSON cannot spell. The fixture carries them as strings.
_SPECIAL_DOUBLES = {"NaN": math.nan, "Infinity": math.inf, "-Infinity": -math.inf}


@dataclass
class LiveWarehouse:
    """A configured live backend and the identifiers it was pointed at."""

    backend: str
    engine: sqlalchemy.Engine
    namespace: tuple[str, ...]
    fixtures: dict[str, str]

    @property
    def engine_backend(self) -> EngineBackend:
        return EngineBackend(self.engine)

    def table_id(self, table: str) -> TableId:
        catalog, schema = self.namespace
        return TableId(table=table, schema=schema, catalog=catalog)

    def quoted(self, table: str) -> str:
        """A fixture table, quoted the way the backend's own reader quotes it.

        Joining the parts raw is wrong on both backends for different reasons:
        `values` is a reserved word on Databricks, and Snowflake folds an
        unquoted identifier to upper case while the fixture tables are created
        under the authored spelling. SQLAlchemy's preparer does not solve
        either, because it quotes only when it judges quoting necessary, and
        it judged `main.commons_live.values` safe on Databricks and lowercase
        Snowflake names safe as well. The readers quote unconditionally, and
        they are what production uses.
        """
        return _READER_QUOTING[self.backend](self.table_id(table).parts)

    def quoted_namespace(self) -> str:
        return _READER_QUOTING[self.backend](list(self.namespace))

    def fixture_table_id(self, name: str) -> TableId:
        """A fixture variable's dotted value as a TableId.

        Spelled out rather than passed positionally: TableId takes the table
        first and the catalog last, so `TableId(*value.split("."))` reverses a
        `catalog.schema.table` value and probes something else entirely.
        """
        parts = self.fixtures[name].split(".")
        if len(parts) != 3:
            raise ValueError(
                f"{name} must name catalog.schema.table, got {self.fixtures[name]!r}."
            )
        catalog, schema, table = parts
        return TableId(table=table, schema=schema, catalog=catalog)


def _missing(names: list[str]) -> list[str]:
    return [name for name in names if not os.environ.get(name)]


def require_live_warehouse(backend: str, *needs: str) -> LiveWarehouse:
    """A live backend, or a skip naming what is unset.

    `needs` lists optional fixtures the caller cannot run without, such as
    `denied_table`. The required ones are always checked.
    """
    spec = _ENV["backends"][backend]
    connection = spec["connection"]

    absent = _missing(connection["required"])
    fixtures: dict[str, str] = {}
    for name, fixture in spec["fixtures"].items():
        value = os.environ.get(fixture["variable"], "")
        if value:
            fixtures[name] = value
        elif fixture["required"] or name in needs:
            absent.append(fixture["variable"])
    if absent:
        pytest.skip(f"live {backend} needs {', '.join(sorted(set(absent)))}")

    namespace = tuple(fixtures["schema"].split("."))
    expected = spec["fixtures"]["schema"]["arity"]
    if len(namespace) != expected:
        raise ValueError(
            f"{spec['fixtures']['schema']['variable']} must name "
            f"{expected} identifier parts, got {fixtures['schema']!r}."
        )

    engine = _engine(backend, connection, namespace)
    return LiveWarehouse(
        backend=backend, engine=engine, namespace=namespace, fixtures=fixtures
    )


def _engine(
    backend: str, connection: dict[str, Any], namespace: tuple[str, ...]
) -> sqlalchemy.Engine:
    if backend == "databricks":
        pytest.importorskip(
            "databricks.sqlalchemy", reason="pip install databricks-sqlalchemy"
        )
        host = os.environ["DATABRICKS_HOST"].removeprefix("https://").rstrip("/")
        token = os.environ.get(connection["token"], "")
        catalog, schema = namespace
        query = {"http_path": os.environ["DATABRICKS_HTTP_PATH"]}
        url = sqlalchemy.engine.URL.create(
            "databricks",
            username="token" if token else None,
            password=token or None,
            host=host,
            database=schema,
            query={**query, "catalog": catalog},
        )
        # Without a token the connector runs the OAuth user-to-machine flow,
        # which opens a browser and reuses the SSO session. That is what makes
        # an SSO-only account usable without minting a long-lived secret.
        connect_args = {} if token else {"auth_type": "databricks-oauth"}
        return sqlalchemy.create_engine(url, connect_args=connect_args)

    pytest.importorskip(
        "snowflake.sqlalchemy", reason="pip install snowflake-sqlalchemy"
    )
    database, schema = namespace
    url = sqlalchemy.engine.URL.create(
        "snowflake",
        username=os.environ["SNOWFLAKE_USER"],
        password=os.environ.get(connection["token"]) or None,
        host=os.environ["SNOWFLAKE_ACCOUNT"],
        database=f"{database}/{schema}",
        query={"warehouse": os.environ["SNOWFLAKE_WAREHOUSE"]},
    )
    return sqlalchemy.create_engine(url)


def _duckdb_value(value: Any, type_name: str) -> Any:
    """A fixture value as the Python object DuckDB should store."""
    if value is None:
        return None
    if type_name == "double" and isinstance(value, str):
        return _SPECIAL_DOUBLES[value]
    if type_name in ("date", "timestamp"):
        # Left as the fixture's ISO text and cast in the INSERT. Binding a
        # tz-aware datetime makes DuckDB reach for pytz, and the loader should
        # not pull a dependency in for a fixture it can hand over as a string.
        return value
    if type_name == "profile_struct":
        return {
            "zip": value["zip"],
            "geo": {"latitude": value["geo"]["latitude"]} if value["geo"] else None,
            "nick names": value["nick names"],
        }
    return value


def duckdb_fixture_connection():
    """The fixture rows in DuckDB, as the reference the warehouse is read against.

    Loaded from the same file the provisioning SQL is generated from, so a row
    cannot differ between the two engines and turn a mismatch into a pass.
    """
    import duckdb

    con = duckdb.connect()
    types = _ROWS["types"]
    for table, spec in _ROWS["tables"].items():
        columns = ", ".join(
            f'"{column["name"]}" {types[column["type"]]["duckdb"]}'
            for column in spec["columns"]
        )
        con.execute(f'CREATE TABLE "{table}" ({columns})')
        placeholders = ", ".join(
            f"CAST(? AS {types[column['type']]['duckdb']})"
            for column in spec["columns"]
        )
        con.executemany(
            f'INSERT INTO "{table}" VALUES ({placeholders})',
            [
                [
                    _duckdb_value(row[column["name"]], column["type"])
                    for column in spec["columns"]
                ]
                for row in spec["rows"]
            ],
        )
    return con


def comparable(value: Any) -> Any:
    """One engine's value in a form the other's can be compared against.

    Drivers disagree about the Python type a column arrives as without
    disagreeing about the value: a warehouse double may come back as a
    Decimal, and a timestamp's offset may be expressed against a different
    zone. Type is not what these tests are about, so it is normalized away
    and the value is what remains.
    """
    if isinstance(value, dt.datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=dt.UTC)
        return value.astimezone(dt.UTC)
    if isinstance(value, bool) or value is None:
        return value
    if isinstance(value, (int, float)) or type(value).__name__ == "Decimal":
        return float(value)
    if isinstance(value, (list, tuple)):
        return [comparable(item) for item in value]
    if isinstance(value, dict):
        return {key: comparable(item) for key, item in value.items()}
    return value


def _sort_key(value: Any) -> tuple[str, str]:
    return (type(value).__name__, repr(value))


def matches(left: list[Any], right: list[Any]) -> bool:
    """Whether two engines produced the same values for one definition.

    Compared as multisets. The fixture tables carry no key, and no ordering
    column can be added to them, because the corpus dictionary defines their
    columns and a definition asking about every column (`anything missing`)
    would then be asking about the key as well.
    """
    if len(left) != len(right):
        return False
    for a, b in zip(
        sorted((comparable(v) for v in left), key=_sort_key),
        sorted((comparable(v) for v in right), key=_sort_key),
    ):
        if isinstance(a, float) and isinstance(b, float):
            if math.isnan(a) and math.isnan(b):
                continue
            if math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-12):
                continue
            return False
        if a != b:
            return False
    return True
