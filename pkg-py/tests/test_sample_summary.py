"""What the sample summary prints for values the shared fixture leaves out.

tests/shared/sample-summary.json pins the wording both packages share. These
are the Python side of the type token, and the shapes that have no R
counterpart to agree with: a column of nothing but nulls whose R type would
still carry facts, a column holding more than one kind of value, and the
Python types a driver can return that R's driver does not.
"""

import datetime
import json
from decimal import Decimal
from pathlib import Path

from commons._sample_summary import _format_signif, sample_summary


def line(values: list[object]) -> str:
    rows = [{"c": value} for value in values]
    return sample_summary(rows).splitlines()[1].removeprefix("* c: ")


def test_a_decimal_column_keeps_the_name_of_the_type_it_arrived_as() -> None:
    assert line([Decimal("1.50"), Decimal("3.25")]) == (
        "Decimal with range [1.5, 3.25], and 0 NAs"
    )


def test_a_mix_of_numeric_types_is_still_summarized_as_a_number() -> None:
    assert line([1, 2.5]) == "number with range [1, 2.5], and 0 NAs"


def test_a_column_of_several_kinds_reports_only_what_is_missing() -> None:
    assert line([1, "two"]) == "mixed with 0 NAs"


def test_bytes_and_mappings_report_only_their_type() -> None:
    assert line([b"ab", b"cd"]) == "bytes"
    assert line([{"a": 1}, {"a": 2}]) == "dict"


def test_an_all_null_column_cannot_name_a_type() -> None:
    # R's driver typed the vector, so R still says `character with 0 unique
    # values` here. A list of mappings carries no type, which is the one shape
    # tests/shared/sample-summary.json deliberately does not pin.
    assert line([None, None, None]) == "unknown with 3 NAs"


def test_a_control_character_in_a_listed_value_is_escaped() -> None:
    assert line(["a\x01b"]) == 'str with 0 NAs, and 1 unique values ("a\\x01b")'


def test_a_datetime_range_drops_the_sub_second_tail() -> None:
    # Naive on purpose: it is what a driver returns for a column with no zone.
    moment = datetime.datetime(2024, 1, 1, 10, 0, 0, 123456)  # noqa: DTZ001
    later = datetime.datetime(2024, 1, 2, 12, 30, 0, 987654)  # noqa: DTZ001

    assert line([moment, later]) == (
        "datetime with range [2024-01-01 10:00:00, 2024-01-02 12:30:00], and 0 NAs"
    )


def test_mixed_zones_report_no_zone_rather_than_one_of_them() -> None:
    utc = datetime.datetime(2024, 1, 1, 10, tzinfo=datetime.UTC)
    offset = datetime.datetime(
        2024, 1, 2, 10, tzinfo=datetime.timezone(datetime.timedelta(hours=2))
    )

    assert not line([utc, offset]).startswith("datetime with timezone")


def test_columns_are_the_union_of_the_keys_the_rows_carry() -> None:
    summary = sample_summary([{"a": 1}, {"b": 2}])

    assert summary.splitlines()[0] == "A data frame with 2 rows and 2 columns:"
    assert summary.splitlines()[1] == "* a: int with range [1, 1], and 1 NAs"


BATTERY = Path(__file__).parent / "data" / "r-format-signif.json"


def test_a_range_number_is_formatted_the_way_r_formats_it() -> None:
    """The battery is `format(x, digits = 4)` read off R, which is what
    ellmer's df_schema() renders a range with. The wording around a range is a
    shared contract, so the numbers inside it have to agree too, and R is not
    available to this suite to ask at run time."""
    cases = json.loads(BATTERY.read_text())
    assert len(cases) > 100

    wrong = [
        (case["value"], case["text"], _format_signif(float(case["value"])))
        for case in cases
        if _format_signif(float(case["value"])) != case["text"]
    ]

    assert wrong == []
