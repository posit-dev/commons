"""Rendering query results for the model."""

import json
from decimal import Decimal
from pathlib import Path

import pytest

from commons._rows import frame_rows, render_value, rows_to_markdown


def test_rows_render_as_a_pipe_table() -> None:
    text = rows_to_markdown([{"region": "EMEA", "revenue": 500}])

    assert text == "| region | revenue |\n|---|---|\n| EMEA | 500 |"


def test_no_rows_says_so_rather_than_showing_an_empty_table() -> None:
    # With no rows there are no keys either, so there is no header to render.
    assert rows_to_markdown([]) == "No rows."


def test_a_column_missing_from_one_row_still_gets_a_header() -> None:
    text = rows_to_markdown([{"a": 1}, {"a": 2, "b": 3}])

    assert text.splitlines()[0] == "| a | b |"
    assert text.splitlines()[2] == "| 1 | NA |"


def test_a_null_reads_as_na() -> None:
    assert rows_to_markdown([{"a": None}]).splitlines()[2] == "| NA |"


def test_a_boolean_reads_as_r_spells_it() -> None:
    text = rows_to_markdown([{"x": True}, {"x": False}])

    assert text.splitlines()[2] == "| TRUE |"
    assert text.splitlines()[3] == "| FALSE |"


def test_a_float_is_trimmed_of_representation_noise() -> None:
    text = rows_to_markdown([{"x": 0.1 + 0.2}, {"x": 1.0}, {"x": 1e10}])

    assert text.splitlines()[2] == "| 0.3 |"
    assert text.splitlines()[3] == "| 1 |"
    assert text.splitlines()[4] == "| 1e+10 |"


def test_render_value_covers_the_shared_vocabulary() -> None:
    assert render_value(None) == "NA"
    assert render_value(False) == "FALSE"
    assert render_value(Decimal("2.50000001")) == "2.5"
    assert render_value("plain") == "plain"


def test_a_pipe_or_line_break_in_a_value_cannot_break_the_table() -> None:
    text = rows_to_markdown([{"note": "a|b\r\nc\rd\ne"}])

    assert text.splitlines()[2] == "| a\\|b c d e |"


def test_a_column_name_is_escaped_like_a_value() -> None:
    # A query names its own aliases, so the header is no safer than a cell.
    text = rows_to_markdown([{"a|b": 1}])

    assert text.splitlines()[0] == "| a\\|b |"


def test_the_row_cap_is_reported() -> None:
    rows = [{"n": index} for index in range(5)]

    text = rows_to_markdown(rows, max_rows=2)

    assert text.endswith("\n\n3 more rows not shown")
    assert "| 2 |" not in text


def test_frame_rows_reads_a_pandas_frame() -> None:
    pandas = pytest.importorskip("pandas")

    rows = frame_rows(pandas.DataFrame({"a": [1, 2]}))

    assert rows == [{"a": 1}, {"a": 2}]


def test_frame_rows_reads_a_polars_frame() -> None:
    polars = pytest.importorskip("polars")

    rows = frame_rows(polars.DataFrame({"a": [1, 2]}))

    assert rows == [{"a": 1}, {"a": 2}]


def test_frame_rows_declines_a_value_it_cannot_read_rows_from() -> None:
    assert frame_rows(object()) is None


def test_a_decimal_reads_the_same_as_a_float_of_the_same_magnitude() -> None:
    # Decimal does not pad its exponent, so the padding is added for it.
    assert render_value(Decimal("0.000012345")) == "1.2345e-05"
    assert render_value(0.000012345) == "1.2345e-05"


def test_a_signalling_decimal_nan_renders_rather_than_raising() -> None:
    # math.isnan() refuses to convert one to a float and raises.
    assert render_value(Decimal("sNaN")) == "NaN"
    assert render_value(Decimal("NaN")) == "NaN"


BATTERY = Path(__file__).parent / "data" / "r-format-signif.json"


def test_a_number_is_formatted_the_way_r_formats_it() -> None:
    """The battery is `format(x, digits = 7)` read off R, one value at a
    time, at the precision `render_value` uses. R is not available to this
    suite to ask at run time."""
    cases = json.loads(BATTERY.read_text())
    assert len(cases) > 100

    wrong = [
        (case["value"], case["text"], render_value(float(case["value"])))
        for case in cases
        if render_value(float(case["value"])) != case["text"]
    ]

    assert wrong == []
