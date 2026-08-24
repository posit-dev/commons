"""Provenance derivation and display copy, driven by the shared fixture.

The truth table and the display strings are a cross-language contract, so the
expectations live in ``tests/shared/provenance.json`` and the R suite runs the
same cases. Do not restate a case here; add it to the fixture.
"""

from dataclasses import FrozenInstanceError
from typing import Any

import pytest

from commons._provenance import PROVENANCE_DISPLAY, Tag, derive_provenance_tag

from ._shared import load_shared_fixture

SPEC = load_shared_fixture("provenance")
DERIVATION_CASES: list[dict[str, Any]] = SPEC["derive_provenance_tag"]["cases"]
DISPLAY: dict[str, Any] = SPEC["provenance_display"]["tags"]


def test_shared_fixture_covers_every_outcome() -> None:
    # A truncated fixture would silently collect zero parametrized cases and
    # the suite would still pass, so pin the coverage the table must have.
    outcomes = {case["expected"] for case in DERIVATION_CASES}
    assert outcomes == {None, "A", "B", "C"}
    assert {case["verified"] for case in DERIVATION_CASES} == {True, False}
    assert set(DISPLAY) == {"A", "B", "C"}


@pytest.mark.parametrize("case", DERIVATION_CASES, ids=lambda case: case["name"])
def test_derivation_matches_the_shared_truth_table(case: dict[str, Any]) -> None:
    tags = [Tag(value) for value in case["tags"]]
    expected = None if case["expected"] is None else Tag(case["expected"])

    assert derive_provenance_tag(tags, verified=case["verified"]) is expected


@pytest.mark.parametrize("name", sorted(DISPLAY))
def test_display_copy_matches_the_shared_fixture(name: str) -> None:
    entry = PROVENANCE_DISPLAY[Tag(name)]
    expected = DISPLAY[name]

    assert entry.label == expected["label"]
    assert entry.body == expected["body"]
    assert entry.icon == expected["icon"]
    assert entry.pill_class == expected["pill_class"]


def test_every_tag_has_display_copy() -> None:
    # A new Tag member without copy would render a pill with no words in it.
    assert set(PROVENANCE_DISPLAY) == set(Tag)


def test_tag_values_are_the_bare_strings_r_uses() -> None:
    # The tag crosses language boundaries as a string: tools set it, and it is
    # written to the commons.provenance.tag span attribute.
    assert [tag.value for tag in Tag] == ["A", "B", "C"]
    assert Tag.A == "A"


def test_tag_formats_as_the_bare_string() -> None:
    # A plain `enum.Enum` formats as "Tag.A", so writing a tag into the span
    # attribute with an f-string would emit a value the R trajectory reviewer
    # cannot match, and nothing would error.
    assert str(Tag.A) == "A"
    assert f"{Tag.A}" == "A"


def test_display_copy_is_immutable() -> None:
    with pytest.raises(FrozenInstanceError):
        PROVENANCE_DISPLAY[Tag.A].label = "Something else"  # type: ignore[misc]
