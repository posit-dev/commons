"""Provenance derivation and display copy, driven by the shared fixture.

The truth table and the display strings are a cross-language contract, so the
expectations live in ``tests/shared/provenance.json`` and the R suite runs the
same cases. Do not restate a case here; add it to the fixture.
"""

from dataclasses import FrozenInstanceError
from typing import Any

import pytest
from chatlas import AssistantTurn, ContentToolResult, UserTurn
from chatlas.types import ContentText

from commons._provenance import (
    PROVENANCE_DISPLAY,
    Tag,
    collect_appended_tags,
    derive_provenance_tag,
    provenance_aside,
)

from ._shared import load_shared_fixture

SPEC = load_shared_fixture("provenance")
DERIVATION_CASES: list[dict[str, Any]] = SPEC["derive_provenance_tag"]["cases"]
DISPLAY: dict[str, Any] = SPEC["provenance_display"]["tags"]
ASIDE_CASES: list[dict[str, Any]] = SPEC["provenance_aside"]["cases"]


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


def _tool_result(tag: Any) -> ContentToolResult:
    return ContentToolResult(value="42", extra={"commons_tag": tag})


def test_collects_the_tags_tool_results_set_in_the_appended_turns() -> None:
    turns = [
        UserTurn([_tool_result(Tag.A)]),
        UserTurn([_tool_result(Tag.B)]),
    ]

    assert collect_appended_tags(turns, 0) == [Tag.A, Tag.B]


def test_ignores_turns_before_the_index() -> None:
    # The index is taken before a turn starts, so tags an earlier exchange set
    # must not classify this one.
    turns = [
        UserTurn([_tool_result(Tag.B)]),
        UserTurn([_tool_result(Tag.A)]),
    ]

    assert collect_appended_tags(turns, 1) == [Tag.A]


def test_an_index_past_the_last_turn_collects_nothing() -> None:
    assert collect_appended_tags([AssistantTurn([ContentText(text="hi")])], 1) == []


def test_ignores_content_without_a_tag() -> None:
    turns = [
        UserTurn(
            [
                ContentText(text="Revenue was 42."),
                ContentToolResult(value="42"),
                _tool_result(None),
                _tool_result(Tag.A),
            ],
        )
    ]

    assert collect_appended_tags(turns, 0) == [Tag.A]


def test_reads_a_tag_that_deserialized_to_a_plain_string() -> None:
    # A restored conversation arrives as JSON, so `extra` holds "A" rather
    # than the enum member the tool set.
    turns = [UserTurn([_tool_result("A")])]

    assert collect_appended_tags(turns, 0) == [Tag.A]


def test_ignores_a_tag_value_that_is_not_an_outcome() -> None:
    # Nothing validates `extra`, and an unrecognized tag must not abort the
    # turn it appears in: the other tags still classify the answer.
    turns = [UserTurn([_tool_result("Z"), _tool_result(Tag.B)])]

    assert collect_appended_tags(turns, 0) == [Tag.B]


@pytest.mark.parametrize("case", ASIDE_CASES, ids=lambda case: case["name"])
def test_the_marker_follows_the_shared_fixture(case: dict[str, Any]) -> None:
    tag = None if case["tag"] is None else Tag(case["tag"])

    aside = provenance_aside(tag, include_cited=case["include_cited"])

    if not case["emits"]:
        assert aside == ""
        return
    assert tag is not None
    display = PROVENANCE_DISPLAY[tag]
    assert aside.startswith(f'<shiny-aside label="{display.label}">')
    assert display.body in aside


def test_the_shared_fixture_covers_both_outcomes_of_every_tag() -> None:
    # A fixture that lost its emits: false cases would still pass every
    # assertion above.
    assert {case["emits"] for case in ASIDE_CASES} == {True, False}
    assert {case["tag"] for case in ASIDE_CASES} == {"A", "B", "C", None}


def test_the_marker_carries_the_info_control() -> None:
    # The custom element upgrades when the UI mounts the aside, and renders as
    # nothing until then, so it is emitted before that UI exists.
    assert (
        '<commons-provenance-info class="commons-provenance-info">'
        "</commons-provenance-info>" in provenance_aside(Tag.A)
    )


def test_the_marker_names_no_icon_yet() -> None:
    # The icon URL comes from the served asset bundle, which arrives with the
    # Python UI. R emits one; a bare filename here would 404.
    assert "icon=" not in provenance_aside(Tag.A)
    assert "data:image" not in provenance_aside(Tag.A)
