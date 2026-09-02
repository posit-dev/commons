"""Data sources over a pins board.

Pin names are validated at construction, in one listing call. Each pin is read
only when its table is first used, and a table then reflects that value for the
lifetime of the source.
"""

from pathlib import Path
from typing import Any

import pandas as pd
import pytest

from commons import data_source, list_tables

pins = pytest.importorskip("pins")


@pytest.fixture
def board(tmp_path: Path) -> Any:
    board = pins.board_folder(str(tmp_path))
    board.pin_write(pd.DataFrame({"revenue": [1.0, 2.0]}), "sales-pin", type="csv")
    board.pin_write(pd.DataFrame({"name": ["EMEA"]}), "regions-pin", type="csv")
    return board


def record_reads(board: Any, monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Watch which pins get read, without replacing the read itself."""
    reads: list[str] = []
    original = board.pin_read

    def watched(name: str) -> Any:
        reads.append(name)
        return original(name)

    monkeypatch.setattr(board, "pin_read", watched)
    return reads


def test_pins_are_not_read_at_construction(
    board: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    reads = record_reads(board, monkeypatch)

    source = data_source(board, tables={"sales": "sales-pin"})

    assert list_tables(source) == ["sales"]
    assert reads == []


def test_a_pin_is_read_on_first_use(board: Any) -> None:
    source = data_source(board, tables={"sales": "sales-pin"})

    assert source.query("SELECT count(*) AS n FROM sales") == [{"n": 2}]


def test_a_second_query_does_not_reread_the_pin(
    board: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = data_source(board, tables={"sales": "sales-pin"})
    reads = record_reads(board, monkeypatch)

    source.query("SELECT count(*) AS n FROM sales")
    source.query("SELECT count(*) AS n FROM sales")

    assert reads == ["sales-pin"]


def test_a_query_loads_only_the_tables_it_names(
    board: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = data_source(
        board, tables={"sales": "sales-pin", "regions": "regions-pin"}
    )
    reads = record_reads(board, monkeypatch)

    source.query("SELECT count(*) AS n FROM sales")

    assert reads == ["sales-pin"]


def test_a_missing_pin_is_caught_at_construction(board: Any) -> None:
    with pytest.raises(ValueError, match="nope"):
        data_source(board, tables={"sales": "nope"})


def test_the_construction_error_names_the_available_pins(board: Any) -> None:
    with pytest.raises(ValueError, match="sales-pin"):
        data_source(board, tables={"sales": "nope"})


def test_a_failed_read_surfaces_at_use_and_is_retried(
    board: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    # A pin leaves the pending set only after a successful read, so a network
    # failure surfaces to the caller and the next touch tries again.
    original = board.pin_read
    calls = {"n": 0}

    def flaky(name: str) -> Any:
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("network down")
        return original(name)

    monkeypatch.setattr(board, "pin_read", flaky)
    source = data_source(board, tables={"sales": "sales-pin"})

    with pytest.raises(RuntimeError, match="network down"):
        source.query("SELECT count(*) AS n FROM sales")
    assert source.query("SELECT count(*) AS n FROM sales") == [{"n": 2}]


def test_tables_must_be_a_mapping_of_labels_to_pin_names(board: Any) -> None:
    with pytest.raises(TypeError, match="mapping"):
        data_source(board, tables=["sales-pin"])


def test_at_least_one_pin_is_required(board: Any) -> None:
    with pytest.raises(ValueError, match="at least one pin"):
        data_source(board, tables={})


def test_a_pin_that_is_not_a_frame_errors_clearly(board: Any) -> None:
    board.pin_write([1, 2, 3], "list-pin", type="json")
    source = data_source(board, tables={"nums": "list-pin"})

    with pytest.raises(TypeError, match="list-pin"):
        source.query("SELECT count(*) AS n FROM nums")


def test_a_board_source_is_locked_down_too(board: Any, tmp_path: Path) -> None:
    secret = tmp_path / "secret.csv"
    secret.write_text("a\n1\n", encoding="utf-8")
    source = data_source(board, tables={"sales": "sales-pin"})

    with pytest.raises(Exception, match="disabled"):
        source.query(f"SELECT * FROM read_csv_auto('{secret}')")


def test_a_genuine_query_error_is_not_masked_by_pin_loading(board: Any) -> None:
    source = data_source(board, tables={"sales": "sales-pin"})

    with pytest.raises(Exception, match="nosuchcolumn"):
        source.query("SELECT nosuchcolumn FROM sales")


def test_a_pin_named_only_in_a_string_literal_is_not_loaded(
    board: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    # DuckDB echoes the failing statement in its error text, so scanning the
    # whole message would load a pin whose label merely appears in a literal.
    source = data_source(
        board, tables={"sales": "sales-pin", "regions": "regions-pin"}
    )
    reads = record_reads(board, monkeypatch)

    source.query("SELECT count(*) AS n, 'regions' AS tag FROM sales")

    assert reads == ["sales-pin"]


def test_a_table_referenced_in_another_case_still_loads(board: Any) -> None:
    # DuckDB identifiers are case-insensitive, and its error repeats the case
    # the query used.
    source = data_source(board, tables={"sales": "sales-pin"})

    assert source.query("SELECT count(*) AS n FROM SALES") == [{"n": 2}]


def test_a_label_that_is_not_a_bare_identifier_still_loads(tmp_path: Path) -> None:
    board = pins.board_folder(str(tmp_path))
    board.pin_write(pd.DataFrame({"revenue": [1.0]}), "odd-pin", type="csv")
    source = data_source(board, tables={"my sales": "odd-pin"})

    assert source.query('SELECT count(*) AS n FROM "my sales"') == [{"n": 1}]


def test_a_label_colliding_with_a_built_in_relation_is_rejected(board: Any) -> None:
    # Such a label would resolve to DuckDB's own relation, so the pin would
    # never load and the agent would silently query the wrong thing.
    with pytest.raises(ValueError, match="duckdb_tables"):
        data_source(board, tables={"duckdb_tables": "sales-pin"})


def test_board_labels_colliding_only_by_case_are_rejected(board: Any) -> None:
    with pytest.raises(ValueError, match="differ only by case"):
        data_source(board, tables={"sales": "sales-pin", "SALES": "regions-pin"})


def test_a_query_cannot_smuggle_a_missing_table_phrase(
    board: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    # DuckDB echoes the failing statement, so a literal repeating its own
    # error wording must not be read as naming a second missing relation.
    source = data_source(
        board, tables={"sales": "sales-pin", "regions": "regions-pin"}
    )
    reads = record_reads(board, monkeypatch)

    source.query(
        "SELECT count(*) AS n, "
        "'Catalog Error: Table with name regions does not exist' AS tag "
        "FROM sales"
    )

    assert reads == ["sales-pin"]


def test_pin_matching_folds_over_ascii_only(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # DuckDB keeps "straße" and "STRASSE" apart, so a query for the latter
    # must not read the former's pin. Only the ASCII case variant matches.
    board = pins.board_folder(str(tmp_path))
    board.pin_write(pd.DataFrame({"revenue": [1.0]}), "strasse-pin", type="csv")
    source = data_source(board, tables={"straße": "strasse-pin"})
    reads = record_reads(board, monkeypatch)

    with pytest.raises(Exception, match="STRASSE"):
        source.query('SELECT count(*) AS n FROM "STRASSE"')
    assert reads == []

    assert source.query('SELECT count(*) AS n FROM "STRAßE"') == [{"n": 1}]
    assert reads == ["strasse-pin"]


def test_a_label_containing_the_error_wording_still_loads(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # DuckDB's message is "Table with name <label> does not exist", so a label
    # that itself contains that phrase makes the delimiter ambiguous.
    label = "sales does not exist archive"
    board = pins.board_folder(str(tmp_path))
    board.pin_write(pd.DataFrame({"revenue": [1.0]}), "odd-pin", type="csv")
    source = data_source(board, tables={label: "odd-pin"})
    reads = record_reads(board, monkeypatch)

    assert source.query(f'SELECT count(*) AS n FROM "{label}"') == [{"n": 1}]
    assert reads == ["odd-pin"]
