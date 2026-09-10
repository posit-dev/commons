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
    TAG_EXTRA_KEY,
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
COLLECT_CASES: list[dict[str, Any]] = SPEC["collect_appended_tags"]["cases"]


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


def _content(spec: dict[str, Any]) -> Any:
    if spec["type"] == "text":
        return ContentText(text=spec["text"])
    if "tag" not in spec:
        return ContentToolResult(value="42")
    return ContentToolResult(value="42", extra={TAG_EXTRA_KEY: spec["tag"]})


@pytest.mark.parametrize("case", COLLECT_CASES, ids=lambda case: case["name"])
def test_collection_matches_the_shared_fixture(case: dict[str, Any]) -> None:
    turns = [
        (AssistantTurn if turn["role"] == "assistant" else UserTurn)(
            [_content(content) for content in turn["contents"]]
        )
        for turn in case["turns"]
    ]

    assert collect_appended_tags(turns, case["skip"]) == [
        Tag(tag) for tag in case["expected"]
    ]


def test_the_shared_fixture_covers_collection_edges() -> None:
    # A truncated fixture would still pass every parametrized case above.
    assert any(case["skip"] > 0 for case in COLLECT_CASES)
    assert any(case["expected"] == [] for case in COLLECT_CASES)


def test_ignores_a_tag_value_that_is_not_a_valid_tag() -> None:
    # Deliberately per-language, so the fixture does not pin it: Python drops
    # an unreadable tag at collection, so it cannot cost the exchange the
    # tags that are readable. R returns it; derive_provenance_tag ignores
    # anything but A and B either way.
    turns = [
        UserTurn(
            [
                ContentToolResult(value="1", extra={TAG_EXTRA_KEY: "Z"}),
                ContentToolResult(value="2", extra={TAG_EXTRA_KEY: "B"}),
            ]
        )
    ]

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


def test_the_marker_names_no_icon_without_a_served_bundle() -> None:
    # An icon URL is only knowable once a bundle is being served, and a bare
    # filename in the page would 404.
    assert "icon=" not in provenance_aside(Tag.A)
    assert "data:image" not in provenance_aside(Tag.A)


@pytest.mark.parametrize("tag", [Tag.A, Tag.C])
def test_a_served_bundle_puts_the_outcome_icon_on_the_marker(
    tag: Tag, served_bundle: str
) -> None:
    icon = PROVENANCE_DISPLAY[tag].icon

    assert icon is not None
    assert f'icon="{served_bundle}/figs/{icon}"' in provenance_aside(tag)


def test_the_outcome_with_no_icon_of_its_own_renders_without_one(
    served_bundle: str,
) -> None:
    marker = provenance_aside(Tag.B, include_cited=True)

    assert marker
    assert "icon=" not in marker
