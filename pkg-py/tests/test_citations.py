"""The citation dialect: block parsing, normalization, and corpus matching.

Every expectation is a cross-language contract, so the cases live in
``tests/shared/citations.json`` and the R suite runs the same ones. Do not
restate a case here; add it to the fixture.
"""

from dataclasses import FrozenInstanceError
from typing import Any

import pytest

from commons._citations import (
    CitationDecision,
    CorpusEntry,
    ParsedCitation,
    match_citation,
    normalize_citation,
    parse_commons_citation,
)

from ._shared import load_shared_fixture

SPEC = load_shared_fixture("citations")
NORMALIZE_CASES: list[dict[str, Any]] = SPEC["normalize_citation"]["cases"]
MATCH: dict[str, Any] = SPEC["match_citation"]
MATCH_CASES: list[dict[str, Any]] = MATCH["cases"]
PARSE_CASES: list[dict[str, Any]] = SPEC["parse_commons_citation"]["cases"]
DECISION_CASES: list[dict[str, Any]] = SPEC["citation_decision"]["cases"]

# One sample passage for the tests that need a quote but do not pin its content.
# The shared cases carry their own inputs; these do not belong in the fixture,
# because the behavior they exercise has no counterpart in the R package.
SAMPLE_QUOTE = "Canopy cover is acre-weighted."
SAMPLE_LABEL = "documentation"
SAMPLE_KIND = "prose"
SAMPLE_ENTRY = CorpusEntry(label=SAMPLE_LABEL, kind=SAMPLE_KIND, text=SAMPLE_QUOTE)


def _corpus(case: dict[str, Any]) -> list[CorpusEntry]:
    return [CorpusEntry(**entry) for entry in case["corpus"]]


def test_shared_fixture_is_populated() -> None:
    # Parametrizing over an empty list collects nothing and the suite still
    # passes, so pin what the fixture has to cover.
    assert len(NORMALIZE_CASES) >= 10
    assert {case["expected"] is None for case in MATCH_CASES} == {True, False}
    assert {case["expected"] is None for case in PARSE_CASES} == {True, False}
    assert {case["decision"]["status"] for case in DECISION_CASES} == {
        "accepted",
        "rejected",
        "malformed",
    }


@pytest.mark.parametrize("case", NORMALIZE_CASES, ids=lambda case: case["name"])
def test_normalization_matches_the_shared_cases(case: dict[str, Any]) -> None:
    assert normalize_citation(case["input"]) == case["expected"]


@pytest.mark.parametrize("case", MATCH_CASES, ids=lambda case: case["name"])
def test_matching_matches_the_shared_cases(case: dict[str, Any]) -> None:
    result = match_citation(case["quote"], _corpus(case))

    if case["expected"] is None:
        assert result is None
    else:
        assert result is not None
        assert result.label == case["expected"]["label"]
        assert result.kind == case["expected"]["kind"]


def test_the_length_guard_sits_where_the_fixture_says() -> None:
    minimum = MATCH["min_normalized_length"]
    # Size the corpus from the minimum, so raising it cannot make the acceptance
    # fail for absence rather than for disagreeing with the fixture.
    entry = CorpusEntry(label=SAMPLE_LABEL, kind=SAMPLE_KIND, text="x" * minimum)

    assert match_citation("x" * (minimum - 1), [entry]) is None
    assert match_citation("x" * minimum, [entry]) is entry


def test_matching_returns_the_entry_that_verified() -> None:
    # The caller needs the label and kind to render the aside, and returning
    # the entry itself keeps the quote the only thing ever verified. Which
    # entry wins is the fixture's business, not this test's.
    assert match_citation(SAMPLE_QUOTE, [SAMPLE_ENTRY]) is SAMPLE_ENTRY


def test_corpus_entries_are_immutable() -> None:
    with pytest.raises(FrozenInstanceError):
        SAMPLE_ENTRY.label = "something else"  # type: ignore[misc]


@pytest.mark.parametrize("case", PARSE_CASES, ids=lambda case: case["name"])
def test_parsing_matches_the_shared_cases(case: dict[str, Any]) -> None:
    result = parse_commons_citation(case["body"])

    if case["expected"] is None:
        assert result is None
    else:
        assert result == ParsedCitation(**case["expected"])


def test_parsed_citations_are_immutable() -> None:
    parsed = parse_commons_citation(f"reason\n\n> {SAMPLE_QUOTE}")
    assert parsed is not None

    with pytest.raises(FrozenInstanceError):
        parsed.quote = "something else"  # type: ignore[misc]


@pytest.mark.parametrize("case", DECISION_CASES, ids=lambda case: case["name"])
def test_decisions_record_the_shared_shape(case: dict[str, Any]) -> None:
    # The R trajectory reviewer reads this JSON out of the span, so the field
    # names and the omissions are the contract, not the dataclass.
    expected = case["decision"]

    decision = CitationDecision(
        quote=expected["quote"],
        status=expected["status"],
        label=expected.get("label"),
        kind=expected.get("kind"),
    )

    assert decision.as_record() == expected


def test_citation_decisions_are_immutable() -> None:
    decision = CitationDecision(quote=SAMPLE_QUOTE, status="rejected")

    with pytest.raises(FrozenInstanceError):
        decision.status = "accepted"  # type: ignore[misc]


def test_only_an_accepted_decision_names_a_source() -> None:
    # The span record is read by the R reviewer, so a decision that claims a
    # source it does not have must not be constructible.
    with pytest.raises(ValueError, match="accepted"):
        CitationDecision(quote=SAMPLE_QUOTE, status="accepted")

    with pytest.raises(ValueError, match="accepted"):
        CitationDecision(
            quote=SAMPLE_QUOTE,
            status="accepted",
            label=SAMPLE_LABEL,
        )

    with pytest.raises(ValueError, match="accepted"):
        CitationDecision(
            quote=SAMPLE_QUOTE,
            status="rejected",
            label=SAMPLE_LABEL,
            kind=SAMPLE_KIND,
        )


def test_only_a_malformed_decision_has_no_quote() -> None:
    with pytest.raises(ValueError, match="malformed"):
        CitationDecision(quote=None, status="rejected")

    with pytest.raises(ValueError, match="malformed"):
        CitationDecision(quote=SAMPLE_QUOTE, status="malformed")


def test_an_unknown_status_is_rejected() -> None:
    # Literal is not enforced at runtime, so the class is the only place a
    # status the R reviewer cannot interpret can be caught.
    with pytest.raises(ValueError, match="status"):
        CitationDecision(quote=SAMPLE_QUOTE, status="Accepted")  # type: ignore[arg-type]


def test_an_unknown_kind_is_rejected() -> None:
    with pytest.raises(ValueError, match="kind"):
        CitationDecision(
            quote=SAMPLE_QUOTE,
            status="accepted",
            label=SAMPLE_LABEL,
            kind="Prose",  # type: ignore[arg-type]
        )
