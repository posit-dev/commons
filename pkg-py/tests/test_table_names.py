"""Table-name parsing, driven by the shared fixture.

How a `tables` string splits into catalog, schema, and table is a
cross-language contract, so the cases live in
``tests/shared/table-names.json`` and the R suite runs the same ones. Do not
restate a case here; add it to the fixture.
"""

from typing import Any

import pytest

from commons._data_source import normalize_table_registry

from ._shared import load_shared_fixture

CASES: list[dict[str, Any]] = load_shared_fixture("table-names")[
    "parse_table_name"
]["cases"]

# The fixture pins the refusal as a slug; the wording belongs to each
# language.
ERRORS: dict[str, tuple[type[Exception], str]] = {
    "too_many_parts": (ValueError, "at most three parts"),
    "empty_component": (ValueError, "empty name components"),
    "not_a_name": (TypeError, "must be a table name"),
}


def test_shared_fixture_covers_every_shape() -> None:
    # A truncated fixture would silently collect zero parametrized cases and
    # the suite would still pass, so pin the coverage the table must have.
    assert CASES
    part_counts = {
        len(case["expected"]) for case in CASES if "expected" in case
    }
    assert part_counts == {1, 2, 3}
    assert {case["error"] for case in CASES if "error" in case} == set(ERRORS)


@pytest.mark.parametrize("case", CASES, ids=lambda case: case["name"])
def test_parse_matches_the_shared_fixture(case: dict[str, Any]) -> None:
    if "error" in case:
        error, match = ERRORS[case["error"]]
        with pytest.raises(error, match=match):
            normalize_table_registry(case["input"])
        return

    (table_id,) = normalize_table_registry(case["input"]).values()
    expected = case["expected"]
    assert table_id.catalog == expected.get("catalog")
    assert table_id.schema == expected.get("schema")
    assert table_id.table == expected["table"]
    # The label is what the agent sees, so it round-trips the input.
    assert table_id.label == case["input"]
