"""The definition-rendering contract both packages consume.

The R suite runs the same cases from the same file. See tests/shared/README.md.
"""

import pytest

from commons._definitions import (
    ExportRecord,
    Registry,
    expand_tokens,
    index_overflows,
    index_text,
)
from commons._definitions._registry import _gist

from ._shared import load_shared_fixture

SPEC = load_shared_fixture("definition-rendering")
RECORDS = SPEC["records"]["values"]

# The fixture names why a query must be refused; the wording is this package's.
REFUSAL = {
    "table_not_in_query": "does not appear in this query",
    "unknown_token": "No governed definition matches",
    "ambiguous_token": "is ambiguous here",
}


def record(key: str) -> ExportRecord:
    return ExportRecord(**RECORDS[key])


def cases(section: str) -> list[dict]:
    # An empty section would collect zero cases and the runner would pass.
    found = SPEC[section]["cases"]
    assert found, section
    return found


@pytest.mark.parametrize("case", cases("expand_tokens"), ids=lambda c: c["name"])
def test_expansion_matches_the_shared_contract(case: dict) -> None:
    records = [record(key) for key in case["records"]]

    if case["expanded"] is None:
        with pytest.raises(ValueError, match=REFUSAL[case["reason"]]):
            expand_tokens(case["sql"], records)
        return

    sql, applied = expand_tokens(case["sql"], records)

    assert sql == case["expanded"]
    assert [found.name for found in applied] == case["applied"]


@pytest.mark.parametrize("case", cases("gist"), ids=lambda c: c["name"])
def test_the_gist_matches_the_shared_contract(case: dict) -> None:
    assert _gist(record(case["record"])) == case["expected"]


def test_every_record_in_the_bank_is_used() -> None:
    used: set[str] = set()
    for section in ("expand_tokens", "index"):
        for case in cases(section):
            used.update(case["records"])
    used.update(case["record"] for case in cases("gist"))

    assert used == set(RECORDS)


@pytest.mark.parametrize("case", cases("index"), ids=lambda c: c["name"])
def test_the_index_matches_the_shared_contract(case: dict) -> None:
    registry = Registry([record(key) for key in case["records"]])

    assert index_text(registry, case["cap_chars"]) == case["text"]
    assert index_overflows(registry, case["cap_chars"]) is case["overflows"]
