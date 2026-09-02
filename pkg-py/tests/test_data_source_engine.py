"""Data sources over a SQLAlchemy engine."""

from pathlib import Path

import pytest
import sqlalchemy

from commons import data_source, list_tables
from commons._data_source import TableId, normalize_table_registry


@pytest.fixture
def engine(tmp_path: Path) -> sqlalchemy.Engine:
    engine = sqlalchemy.create_engine(f"sqlite:///{tmp_path / 'db.sqlite'}")
    with engine.begin() as connection:
        connection.execute(
            sqlalchemy.text("CREATE TABLE sales (id INTEGER, revenue REAL)")
        )
        connection.execute(
            sqlalchemy.text("INSERT INTO sales VALUES (1, 100.0), (2, 250.0)")
        )
        connection.execute(sqlalchemy.text("CREATE TABLE regions (name TEXT)"))
    return engine


def test_a_string_becomes_an_unqualified_table_id() -> None:
    assert normalize_table_registry(["sales"]) == {"sales": TableId(table="sales")}


def test_a_dotted_string_is_read_as_schema_qualified() -> None:
    registry = normalize_table_registry(["analytics.sales"])

    assert registry == {"analytics.sales": TableId(table="sales", schema="analytics")}


def test_an_explicit_table_id_bypasses_dot_splitting() -> None:
    # A literal table name containing a dot is spelled as a TableId, which is
    # why the dispatcher accepts them alongside strings.
    literal = TableId(table="a.b")

    assert normalize_table_registry([literal]) == {"a.b": literal}


def test_an_empty_name_component_is_rejected() -> None:
    with pytest.raises(ValueError, match="empty name components"):
        normalize_table_registry(["analytics."])


def test_duplicate_labels_are_rejected() -> None:
    with pytest.raises(ValueError, match="duplicate labels"):
        normalize_table_registry(["sales", "sales"])


def test_a_bare_string_is_accepted_as_one_table() -> None:
    assert normalize_table_registry("sales") == {"sales": TableId(table="sales")}


def test_a_non_name_entry_is_rejected() -> None:
    with pytest.raises(TypeError, match="table name or a TableId"):
        normalize_table_registry([42])


def test_an_engine_is_queried_without_copying(engine: sqlalchemy.Engine) -> None:
    source = data_source(engine, tables=["sales"])

    assert list_tables(source) == ["sales"]
    assert source.query("SELECT count(*) AS n FROM sales") == [{"n": 2}]


def test_leaving_tables_unset_discovers_every_table(engine: sqlalchemy.Engine) -> None:
    source = data_source(engine)

    assert sorted(list_tables(source)) == ["regions", "sales"]


def test_default_discovery_is_not_validated(engine: sqlalchemy.Engine) -> None:
    # Discovery returns what the backend reports, so there is nothing to check
    # and nothing to pay a round trip for.
    source = data_source(engine)

    assert source.table_ids["sales"] == TableId(table="sales")


def test_a_table_absent_from_the_connection_errors(engine: sqlalchemy.Engine) -> None:
    with pytest.raises(ValueError, match="nope"):
        data_source(engine, tables=["sales", "nope"])


def test_the_error_names_what_is_available(engine: sqlalchemy.Engine) -> None:
    with pytest.raises(ValueError, match="regions"):
        data_source(engine, tables=["nope"])


def test_the_dialect_comes_from_the_engine(engine: sqlalchemy.Engine) -> None:
    assert data_source(engine, tables=["sales"]).dialect() == "sqlite"


def test_the_guard_applies_to_engine_sources_too(engine: sqlalchemy.Engine) -> None:
    source = data_source(engine, tables=["sales"])

    with pytest.raises(ValueError, match="disallowed operation"):
        source.query("DELETE FROM sales")
    assert source.query("SELECT count(*) AS n FROM sales") == [{"n": 2}]


def test_an_engine_and_frames_together_are_rejected(engine: sqlalchemy.Engine) -> None:
    with pytest.raises(TypeError, match="not both"):
        data_source(engine, sales=object())


def test_two_positional_arguments_are_rejected(engine: sqlalchemy.Engine) -> None:
    with pytest.raises(TypeError, match="one positional argument"):
        data_source(engine, engine)


def test_an_unsupported_positional_argument_is_named(engine: sqlalchemy.Engine) -> None:
    with pytest.raises(TypeError, match="int"):
        data_source(42)


def test_a_probe_failure_that_is_not_absence_is_not_blamed_on_the_tables(
    engine: sqlalchemy.Engine, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Every table exists, so a failing probe means something else is wrong and
    # that error is more informative than a missing-table message.
    import commons._backends as backends

    def broken(self: object, sql: str) -> list[dict[str, object]]:
        raise RuntimeError("connection reset by peer")

    monkeypatch.setattr(backends.EngineBackend, "query", broken)

    with pytest.raises(RuntimeError, match="connection reset"):
        data_source(engine, tables=["sales"])
