"""The in-process DuckDB commons owns, and the lockdown that makes it safe.

``lock_down`` is a security control. Every test here is an attempt, not an
assertion about configuration: configuration that looks right but does not
stop the attempt is worth nothing.
"""

from pathlib import Path

import duckdb
import pytest

from commons._duckdb import connect, lock_down


def test_a_locked_down_connection_cannot_read_the_filesystem(tmp_path: Path) -> None:
    secret = tmp_path / "secret.csv"
    secret.write_text("a\n1\n", encoding="utf-8")
    con = connect()
    lock_down(con)

    with pytest.raises(duckdb.Error):
        con.execute(f"SELECT * FROM read_csv_auto('{secret}')").fetchall()


def test_a_locked_down_connection_cannot_reopen_external_access() -> None:
    con = connect()
    lock_down(con)

    with pytest.raises(duckdb.Error):
        con.execute("SET enable_external_access = true")


def test_a_locked_down_connection_cannot_install_extensions() -> None:
    con = connect()
    lock_down(con)

    with pytest.raises(duckdb.Error):
        con.execute("INSTALL httpfs")


def test_registering_a_frame_still_works_after_lockdown() -> None:
    # lock_configuration() freezes SET statements only, so a table written
    # after the lockdown still lands. The board path depends on this.
    con = connect()
    lock_down(con)
    con.execute("CREATE TABLE t AS SELECT 1 AS x UNION ALL SELECT 2")

    assert con.execute("SELECT count(*) AS n FROM t").fetchone() == (2,)


def test_two_connections_coexist_in_one_process() -> None:
    # home_directory is a process-global option; setting it on a second
    # connection must not fail once the first instance exists.
    first = connect()
    second = connect()

    home = second.execute("SELECT current_setting('home_directory') AS h").fetchone()
    assert home is not None
    assert home[0].endswith("duckdb")
    first.close()
    second.close()
