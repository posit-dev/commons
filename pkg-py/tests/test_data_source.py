"""``data_source()`` and the frames path."""

from pathlib import Path

import duckdb
import pandas as pd
import pytest

from commons import DataSource, data_source, list_tables


def sales_frame() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "order_id": ["o01", "o02", "o03"],
            "revenue": [100.0, 250.0, 700.0],
            "region": ["EMEA", "APAC", "EMEA"],
        }
    )


def test_frames_become_queryable_tables() -> None:
    source = data_source(sales=sales_frame())

    assert list_tables(source) == ["sales"]
    assert source.query("SELECT count(*) AS n FROM sales") == [{"n": 3}]


def test_several_frames_all_register() -> None:
    source = data_source(sales=sales_frame(), regions=pd.DataFrame({"region": ["EMEA"]}))

    assert sorted(list_tables(source)) == ["regions", "sales"]


def test_a_frames_source_cannot_read_the_host_filesystem(tmp_path: Path) -> None:
    # M2's acceptance criterion, written as the attempt rather than as an
    # assertion about configuration.
    secret = tmp_path / "secret.csv"
    secret.write_text("a\n1\n", encoding="utf-8")
    source = data_source(sales=sales_frame())

    with pytest.raises(duckdb.Error):
        source.query(f"SELECT * FROM read_csv_auto('{secret}')")


def test_the_guard_runs_before_the_database_sees_the_query() -> None:
    source = data_source(sales=sales_frame())

    with pytest.raises(ValueError, match="disallowed operation"):
        source.query("DROP TABLE sales")
    assert source.query("SELECT count(*) AS n FROM sales") == [{"n": 3}]


def test_unnamed_input_is_rejected() -> None:
    with pytest.raises(TypeError, match="named"):
        data_source(sales_frame())


def test_a_non_frame_value_is_rejected() -> None:
    with pytest.raises(TypeError, match="sales"):
        data_source(sales=1)


def test_a_polars_frame_registers_too() -> None:
    polars = pytest.importorskip("polars")
    source = data_source(sales=polars.DataFrame({"revenue": [1.0, 2.0]}))

    assert source.query("SELECT count(*) AS n FROM sales") == [{"n": 2}]


def test_the_dialect_of_a_frames_source_is_duckdb() -> None:
    assert data_source(sales=sales_frame()).dialect() == "duckdb"


@pytest.mark.parametrize("name", ["my sales", 'we"ird', "order-lines", "2024"])
def test_a_table_name_that_is_not_a_bare_identifier_still_registers(name: str) -> None:
    source = data_source(**{name: sales_frame()})

    assert list_tables(source) == [name]
    quoted = '"' + name.replace('"', '""') + '"'
    assert source.query(f"SELECT count(*) AS n FROM {quoted}") == [{"n": 3}]


def test_a_frame_name_cannot_inject_sql_before_the_lockdown(tmp_path: Path) -> None:
    # Names reach DuckDB as identifiers, and the tables are written before
    # lock_down() runs, so an unescaped name would be an injection point that
    # the lockdown never gets to close.
    secret = tmp_path / "secret.csv"
    secret.write_text("a\n42\n", encoding="utf-8")
    hostile = f"""x" AS SELECT * FROM read_csv_auto('{secret}'); --"""

    source = data_source(**{hostile: sales_frame()})

    assert list_tables(source) == [hostile]
    assert source.backend.list_tables() == [hostile]


def test_the_guard_is_given_the_sources_dialect() -> None:
    # Dialect syntax only parses when the guard knows the dialect, so a
    # DuckDB-only construct reaching the database proves it was passed.
    source = data_source(sales=sales_frame())

    assert source.query("SELECT * EXCLUDE (order_id, region) FROM sales")[0] == {
        "revenue": 100.0
    }


def test_tables_is_reserved_in_the_dispatcher() -> None:
    # `tables` is a keyword-only option, so the dispatcher rejects it as a
    # frame name rather than silently consuming the frame.
    with pytest.raises(TypeError, match="`tables` selects tables"):
        data_source(tables=sales_frame())


def test_a_frame_may_be_named_tables_via_from_frames() -> None:
    source = DataSource.from_frames(tables=sales_frame())

    assert list_tables(source) == ["tables"]
    assert source.query("SELECT count(*) AS n FROM tables") == [{"n": 3}]


def test_frame_names_colliding_only_by_case_are_rejected() -> None:
    # DuckDB resolves quoted identifiers case-insensitively, so these are one
    # table. Without a check the second write raises a raw DuckDB error.
    with pytest.raises(ValueError, match="differ only by case"):
        data_source(sales=sales_frame(), SALES=sales_frame())


def test_non_ascii_names_that_duckdb_keeps_distinct_are_allowed() -> None:
    # DuckDB folds ASCII only, so these are two tables. Python's casefold()
    # maps "ß" to "ss" and would have rejected them as one.
    source = data_source(straße=sales_frame(), STRASSE=sales_frame())

    assert sorted(list_tables(source)) == ["STRASSE", "straße"]
    assert source.query('SELECT count(*) AS n FROM "straße"') == [{"n": 3}]
