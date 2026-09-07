"""The sample-summary contract both packages consume.

The R suite runs the same cases from the same file. See tests/shared/README.md.
"""

import datetime
from typing import Any

import pytest

from commons._sample_summary import SAMPLE_SUMMARY_HEADING, sample_summary

from ._shared import load_shared_fixture

SPEC = load_shared_fixture("sample-summary")

BUILDERS = {
    "integer": int,
    "double": float,
    "string": str,
    "boolean": bool,
    "date": datetime.date.fromisoformat,
    "datetime_utc": lambda text: datetime.datetime.fromisoformat(text).replace(
        tzinfo=datetime.UTC
    ),
    "datetime_naive": datetime.datetime.fromisoformat,
    "list": list,
}


def cases() -> list[dict[str, Any]]:
    # An empty fixture would enumerate no cases and the runner would pass.
    found = SPEC["cases"]
    assert found
    return found


def build(spec: dict[str, Any]) -> list[Any]:
    make = BUILDERS[spec["type"]]
    return [None if value is None else make(value) for value in spec["values"]]


def expected(case: dict[str, Any]) -> str:
    """The case's own wording, with this package's type token in each line."""
    lines = [case["header"]]
    for column in case["columns"]:
        line = column["line"].replace("{type}", column["tokens"]["python"])
        lines.append(f"* {column['name']}: {line}")
    return "\n".join(lines)


@pytest.mark.parametrize("case", cases(), ids=lambda c: c["name"])
def test_the_summary_matches_the_shared_contract(case: dict[str, Any]) -> None:
    built = {column["name"]: build(column) for column in case["columns"]}
    height = max((len(values) for values in built.values()), default=0)
    rows = [
        {name: values[index] for name, values in built.items()}
        for index in range(height)
    ]

    assert sample_summary(rows, list(built)) == expected(case)


def test_the_heading_is_the_shared_one() -> None:
    assert SAMPLE_SUMMARY_HEADING == SPEC["heading"]


def test_every_builder_the_fixture_names_is_exercised() -> None:
    used = {column["type"] for case in cases() for column in case["columns"]}

    assert used == set(BUILDERS)


def test_the_cases_pin_both_sides_of_each_listing_limit() -> None:
    # A fixture that only ever listed values, or only ever withheld them,
    # would pass against an implementation that always did one of the two.
    lines = [column["line"] for case in cases() for column in case["columns"]]

    assert any("unique values (" in line for line in lines)
    assert any(line.endswith("unique values") for line in lines)


def test_the_cases_pin_both_range_notations() -> None:
    lines = [column["line"] for case in cases() for column in case["columns"]]

    assert any("1e+10" in line for line in lines)
    assert any("range [1.5, 3.5]" in line for line in lines)
