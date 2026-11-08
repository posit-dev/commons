"""Binding values through the backend query seam."""

from pathlib import Path

import duckdb
import pytest
import sqlalchemy

from commons import data_source
from commons._backends import DuckDBBackend, EngineBackend


@pytest.fixture
def engine(tmp_path: Path) -> sqlalchemy.Engine:
    engine = sqlalchemy.create_engine(f"sqlite:///{tmp_path / 'db.sqlite'}")
    with engine.begin() as connection:
        connection.execute(sqlalchemy.text("CREATE TABLE sales (region TEXT, n INT)"))
        connection.execute(
            sqlalchemy.text("INSERT INTO sales VALUES ('EMEA', 1), ('APAC', 2)")
        )
    return engine


def test_engine_query_binds_named_params(engine: sqlalchemy.Engine) -> None:
    assert EngineBackend(engine).query("SELECT :p0 AS x", {"p0": 3}) == [{"x": 3}]


def test_duckdb_query_refuses_params() -> None:
    with pytest.raises(ValueError, match="does not bind"):
        DuckDBBackend(duckdb.connect()).query("SELECT 1", {"p0": 1})


def test_data_source_query_passes_params(engine: sqlalchemy.Engine) -> None:
    source = data_source(engine, tables=["sales"])
    rows = source.query("SELECT n FROM sales WHERE region = :p0", {"p0": "APAC"})
    assert rows == [{"n": 2}]


def test_read_only_check_still_applies_with_params(engine: sqlalchemy.Engine) -> None:
    source = data_source(engine, tables=["sales"])
    with pytest.raises(ValueError):
        source.query("DELETE FROM sales WHERE region = :p0", {"p0": "APAC"})


def test_compiled_query_skips_the_read_only_parse(engine: sqlalchemy.Engine) -> None:
    source = data_source(engine, tables=["sales"])
    # SQLite has no SEMANTIC_VIEW; a parse failure from the guard would raise
    # ValueError first, so reaching the driver proves the guard was skipped.
    with pytest.raises(sqlalchemy.exc.OperationalError):
        source.query(
            "SELECT * FROM SEMANTIC_VIEW(x VARIABLES y => :p0)",
            {"p0": 1},
            compiled=True,
        )
