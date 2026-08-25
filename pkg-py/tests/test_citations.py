"""Citation normalization and corpus matching, driven by the shared fixture.

Every expectation is a cross-language contract, so the cases live in
``tests/shared/citations.json`` and the R suite runs the same ones. Do not
restate a case here; add it to the fixture.
"""

from dataclasses import FrozenInstanceError
from typing import Any

import pytest

from commons._citations import CorpusEntry, match_citation, normalize_citation

from ._shared import load_shared_fixture

SPEC = load_shared_fixture("citations")
NORMALIZE_CASES: list[dict[str, Any]] = SPEC["normalize_citation"]["cases"]
WHITESPACE: dict[str, Any] = SPEC["whitespace"]
MATCH: dict[str, Any] = SPEC["match_citation"]
MATCH_CASES: list[dict[str, Any]] = MATCH["cases"]


def _corpus(case: dict[str, Any]) -> list[CorpusEntry]:
    return [CorpusEntry(**entry) for entry in case["corpus"]]


def test_shared_fixture_is_populated() -> None:
    # Parametrizing over an empty list collects nothing and the suite still
    # passes, so pin what the fixture has to cover.
    assert len(NORMALIZE_CASES) >= 10
    assert {case["expected"] is None for case in MATCH_CASES} == {True, False}
    assert WHITESPACE["collapsed"] and WHITESPACE["preserved"]


@pytest.mark.parametrize("case", NORMALIZE_CASES, ids=lambda case: case["name"])
def test_normalization_matches_the_shared_cases(case: dict[str, Any]) -> None:
    assert normalize_citation(case["input"]) == case["expected"]


@pytest.mark.parametrize("code", WHITESPACE["collapsed"])
def test_listed_whitespace_collapses(code: str) -> None:
    char = chr(int(code, 16))

    assert normalize_citation(f"{char}a{char}b{char}") == "a b"


@pytest.mark.parametrize("code", WHITESPACE["preserved"])
def test_unlisted_characters_are_left_alone(code: str) -> None:
    # Neither implementation may treat these as whitespace. Python's \\s and R's
    # default engine disagree about several of them, which is why the set is
    # spelled out rather than delegated to either.
    char = chr(int(code, 16))
    text = f"{char}a{char}b{char}"

    assert normalize_citation(text) == text


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
    entry = CorpusEntry(label="documentation", kind="prose", text="x" * minimum)

    assert match_citation("x" * (minimum - 1), [entry]) is None
    assert match_citation("x" * minimum, [entry]) is entry


def test_matching_returns_the_entry_that_verified() -> None:
    # The caller needs the label and kind to render the aside, and returning
    # the entry keeps the quote the only thing ever verified.
    first = CorpusEntry(
        label="orders table", kind="schema", text="Revenue excludes tax."
    )
    second = CorpusEntry(
        label="documentation", kind="prose", text="Revenue excludes tax."
    )

    assert match_citation("Revenue excludes tax.", [first, second]) is first


def test_corpus_entries_are_immutable() -> None:
    entry = CorpusEntry(
        label="documentation", kind="prose", text="Revenue excludes tax."
    )

    with pytest.raises(FrozenInstanceError):
        entry.label = "something else"  # type: ignore[misc]
