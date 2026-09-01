"""The streaming scanner that projects model text for display.

The projection is a cross-language contract, so the cases live in
``tests/shared/citations.json`` under ``citation_scan`` and the R suite runs
the same ones. Do not restate a case here; add it to the fixture.
"""

from collections.abc import Iterator, Sequence
from typing import Any

import pytest

from commons._citation_scan import CITATION_CLOSE, ELEMENT_BODY_CAP, CitationScanner
from commons._citations import CorpusEntry, citation_aside_html, match_citation

from ._shared import load_shared_fixture

SPEC: dict[str, Any] = load_shared_fixture("citations")["citation_scan"]
CASES: list[dict[str, Any]] = SPEC["cases"]
HOLDBACK_CASES: list[dict[str, Any]] = load_shared_fixture("citations")[
    "citation_holdback"
]["cases"]
CORPORA: dict[str, list[dict[str, Any]]] = SPEC["corpora"]
EXHAUSTIVE_MAX: int = SPEC["exhaustive_split_max_chars"]

PAD_TOKEN = "{{pad}}"
SPLIT_TOKEN = "{{split}}"
CITATION_OPEN = "<commons-citation>"

# One sample passage for the tests below that need a quote but do not pin the
# projection. Anything that pins the projection belongs in the fixture.
SAMPLE_QUOTE = "Canopy cover is always acre-weighted for reporting."
SAMPLE_CORPUS = [CorpusEntry(label="documentation", kind="prose", text=SAMPLE_QUOTE)]


def scan(chunks: Sequence[str], corpus: Sequence[CorpusEntry]) -> tuple[str, list[Any]]:
    scanner = CitationScanner(corpus)
    text = "".join(scanner.feed(chunk) for chunk in chunks) + scanner.finish()
    return text, [decision.as_record() for decision in scanner.candidates]


def _padding(case: dict[str, Any], text: str) -> str:
    """Expand ``{{pad}}`` so the first citation body reaches its stated length."""
    pad = case.get("pad")
    if pad is None:
        return ""
    body = text.split(CITATION_OPEN, 1)[1].split(CITATION_CLOSE, 1)[0]
    return pad["char"] * (pad["citation_body_length"] - len(body) + len(PAD_TOKEN))


def _render(
    case: dict[str, Any],
    expected: str,
    corpus: Sequence[CorpusEntry],
    padding: str,
) -> str:
    """Substitute each ``{{aside:N}}`` with the aside this package renders."""
    for index, aside in enumerate(case.get("asides", [])):
        quote = aside["quote"]
        entry = match_citation(quote, corpus)
        assert entry is not None, f"aside {index} of {case['name']} does not verify"
        explanation = aside["explanation"].replace(PAD_TOKEN, padding)
        html = citation_aside_html(quote, explanation, entry.label, entry.kind)
        expected = expected.replace(f"{{{{aside:{index}}}}}", html)
    return expected


def _chunkings(text: str, explicit: list[str]) -> Iterator[tuple[str, list[str]]]:
    yield "the whole text", [text]
    if len(explicit) > 1:
        yield "the fixture's feed boundaries", explicit
    if len(text) <= EXHAUSTIVE_MAX:
        yield "one character at a time", list(text)
        for at in range(1, len(text)):
            yield f"a split at {at}", [text[:at], text[at:]]


def test_shared_fixture_is_populated() -> None:
    # Parametrizing over an empty list collects nothing and the suite still
    # passes, so pin what the fixture has to cover.
    assert len(CASES) >= 20
    statuses = {decision["status"] for case in CASES for decision in case["decisions"]}
    assert statuses == {"accepted", "rejected", "malformed"}


def test_the_cap_matches_the_shared_fixture() -> None:
    assert ELEMENT_BODY_CAP == SPEC["element_body_cap"]


@pytest.mark.parametrize("case", CASES, ids=lambda case: case["name"])
def test_projection_matches_the_shared_cases(case: dict[str, Any]) -> None:
    corpus = [CorpusEntry(**entry) for entry in CORPORA[case["corpus"]]]
    text = case["text"].replace(SPLIT_TOKEN, "")
    padding = _padding(case, text)
    text = text.replace(PAD_TOKEN, padding)
    chunks = case["text"].replace(PAD_TOKEN, padding).split(SPLIT_TOKEN)
    expected = _render(
        case, case["expected_text"].replace(PAD_TOKEN, padding), corpus, padding
    )

    for description, fed in _chunkings(text, chunks):
        got_text, got_decisions = scan(fed, corpus)
        assert got_text == expected, f"fed {description}"
        assert got_decisions == case["decisions"], f"fed {description}"


@pytest.mark.parametrize("case", HOLDBACK_CASES, ids=lambda case: case["name"])
def test_each_feed_emits_the_shared_cases(case: dict[str, Any]) -> None:
    scanner = CitationScanner(SAMPLE_CORPUS)

    emitted = [scanner.feed(chunk) for chunk in case["chunks"]]

    assert emitted == case["emitted"]
    assert scanner.finish() == case["flushed"]


def test_any_verified_reports_whether_a_quote_was_accepted() -> None:
    scanner = CitationScanner(SAMPLE_CORPUS)
    assert not scanner.any_verified

    scanner.feed("<commons-citation>\n\nwhy\n\n> nothing supports this\n\n")
    scanner.feed("</commons-citation>")
    assert not scanner.any_verified

    scanner.feed(f"\n<commons-citation>\n\nwhy\n\n> {SAMPLE_QUOTE}\n\n")
    scanner.feed("</commons-citation>")
    assert scanner.any_verified


def test_an_oversized_unclosed_citation_does_not_grow_the_buffer() -> None:
    # Memory, not projection: the fixture pins that nothing is emitted, and
    # this pins that nothing is retained while waiting for a close tag.
    scanner = CitationScanner(SAMPLE_CORPUS)

    assert scanner.feed("<commons-citation>" + "x" * (ELEMENT_BODY_CAP + 1)) == ""
    assert len(scanner._buffer) < len(CITATION_CLOSE)
    assert scanner.feed("y" * (ELEMENT_BODY_CAP * 2)) == ""
    assert len(scanner._buffer) < len(CITATION_CLOSE)
    assert scanner.finish() == ""


def test_the_aside_escapes_its_label_and_reflows_the_quote() -> None:
    html = citation_aside_html(
        "first line\nsecond line", "why", 'a "quoted" & label', "prose"
    )

    # The attribute and the title text sit in different contexts, so they are
    # escaped differently: quotes in the attribute, angle brackets in the text.
    assert html.startswith('<shiny-aside label="a &quot;quoted&quot; &amp; label">')
    assert '>a "quoted" &amp; label</span>' in html
    assert html.endswith("why\n\n> first line\n> second line</shiny-aside>")


def test_the_aside_omits_the_explanation_when_the_model_gave_none() -> None:
    html = citation_aside_html(SAMPLE_QUOTE, "", "documentation", "prose")

    assert html.endswith(f"</span>\n\n> {SAMPLE_QUOTE}</shiny-aside>")
