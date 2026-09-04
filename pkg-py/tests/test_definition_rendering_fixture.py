"""The definition-rendering contract both packages consume.

This checks the fixture's own integrity: that every section has cases, that
each case names records the bank defines, and that a refusal says why. Running
the cases against an implementation comes with the registry.
"""

from typing import Any

from ._shared import load_shared_fixture

SPEC = load_shared_fixture("definition-rendering")
RECORDS: dict[str, dict[str, Any]] = SPEC["records"]["values"]
SECTIONS = ("expand_tokens", "gist", "index")


def test_every_section_has_cases() -> None:
    # An empty section would collect zero cases and every runner would pass.
    for section in SECTIONS:
        assert SPEC[section]["cases"], section


def test_every_record_is_used() -> None:
    used: set[str] = set()
    for section in ("expand_tokens", "index"):
        for case in SPEC[section]["cases"]:
            used.update(case["records"])
    used.update(case["record"] for case in SPEC["gist"]["cases"])

    assert used == set(RECORDS)


def test_every_named_record_resolves() -> None:
    for section in ("expand_tokens", "index"):
        for case in SPEC[section]["cases"]:
            for key in case["records"]:
                assert key in RECORDS, f"{section}: {case['name']}: {key}"


def test_refusals_say_why_and_expansions_do_not() -> None:
    for case in SPEC["expand_tokens"]["cases"]:
        if case["expanded"] is None:
            assert case["reason"], case["name"]
            assert case["applied"] == [], case["name"]
        else:
            assert "reason" not in case, case["name"]


def test_the_index_cases_pin_both_sides_of_the_cap() -> None:
    # A fixture where nothing overflows would pass against an implementation
    # that never reports overflow.
    overflows = {case["overflows"] for case in SPEC["index"]["cases"]}

    assert overflows == {True, False}


def test_the_gist_cases_cover_a_typeless_definition() -> None:
    # The defect this section exists for: an absent type must not take the
    # rest of the gist with it.
    typeless = [key for key, record in RECORDS.items() if record["type"] is None]

    assert typeless
    assert any(case["record"] in typeless for case in SPEC["gist"]["cases"])
