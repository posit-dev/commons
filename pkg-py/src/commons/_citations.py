"""Parsing a citation block and verifying its quote against a trusted corpus.

The normalization rules and the matching verdicts are a cross-language contract
pinned by ``tests/shared/citations.json``; change that fixture, not just this
file. ``pkg-r/R/citations.R`` implements the same contract for R.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any, Literal, get_args

__all__ = [
    "CitationDecision",
    "CorpusEntry",
    "ParsedCitation",
    "match_citation",
    "normalize_citation",
    "parse_commons_citation",
]

# The minimum length is a guard, not a tuning knob: a fragment this short can
# appear in a trusted source by coincidence and must not promote an answer.
MIN_NORMALIZED_LENGTH = 10

# Not CommonMark: no indented marker and no lazy continuation, so evidence the
# model wrapped stays explanation rather than verifying only its first line.
_QUOTE_MARKER = re.compile("^> ?")

_WHITESPACE = re.compile(r"\s+")
_EMPHASIS = re.compile(r"[*_`]")
_SINGLE_QUOTES = re.compile("[\u2018\u2019]")
_DOUBLE_QUOTES = re.compile("[\u201c\u201d]")
_DASHES = re.compile("[\u2013\u2014]")

CitationKind = Literal["prose", "definition", "schema"]
CitationStatus = Literal["accepted", "rejected", "malformed"]


@dataclass(frozen=True)
class CorpusEntry:
    """One trusted passage a citation can be verified against.

    ``label`` is reader-facing and appears in the rendered aside.
    """

    label: str
    kind: CitationKind
    text: str


@dataclass(frozen=True)
class ParsedCitation:
    """The two halves of a ``<commons-citation>`` body.

    Only ``quote`` is ever verified. ``explanation`` is the model's own words
    and carries no trust.
    """

    explanation: str
    quote: str


# Derived from the type so the runtime guard and the annotation cannot drift.
_DECISION_STATUSES = get_args(CitationStatus)


@dataclass(frozen=True)
class CitationDecision:
    """One candidate and its verdict, recorded to ``commons.citation.candidates``.

    ``label`` and ``kind`` name the source that verified the quote, so they are
    absent unless the status is accepted. A malformed body has no quote to
    record.
    """

    quote: str | None
    status: CitationStatus
    label: str | None = None
    kind: str | None = None

    def __post_init__(self) -> None:
        # The R reviewer reads this record back out of the span, so a decision
        # that misreports its verdict must not be constructible. Literal is not
        # enforced at runtime, so the vocabulary is checked here too.
        if self.status not in _DECISION_STATUSES:
            raise ValueError(
                f"Unknown citation decision status {self.status!r}; expected "
                f"one of {', '.join(_DECISION_STATUSES)}."
            )
        if self.status == "accepted":
            if self.label is None or self.kind is None:
                raise ValueError(
                    "An accepted decision records the label and kind of the "
                    "source that verified the quote."
                )
        elif self.label is not None or self.kind is not None:
            raise ValueError(
                f"Only an accepted decision names a source; status is {self.status!r}."
            )
        if (self.quote is None) != (self.status == "malformed"):
            raise ValueError(
                f"Only a malformed decision has no quote; status is {self.status!r}."
            )

    def as_record(self) -> dict[str, Any]:
        """Serialize to the JSON shape the R trajectory reviewer reads."""
        record: dict[str, Any] = {"quote": self.quote, "status": self.status}
        if self.label is not None:
            record["label"] = self.label
        if self.kind is not None:
            record["kind"] = self.kind
        return record


def parse_commons_citation(body: str) -> ParsedCitation | None:
    """Split a citation body into evidence and explanation, or None if malformed.

    Exactly one contiguous run of blockquote lines holds the evidence; every
    other line is explanation. Zero runs or two separate runs are malformed.
    """
    lines = body.split("\n")
    quoted = [_QUOTE_MARKER.match(line) is not None for line in lines]
    runs = sum(
        1 for i, flag in enumerate(quoted) if flag and not (i > 0 and quoted[i - 1])
    )
    if runs != 1:
        return None

    quote = "\n".join(
        _QUOTE_MARKER.sub("", line) for line, flag in zip(lines, quoted) if flag
    )
    explanation = "\n".join(
        line for line, flag in zip(lines, quoted) if not flag
    ).strip()
    return ParsedCitation(explanation=explanation, quote=quote)


def normalize_citation(text: str) -> str:
    """Fold the ways a faithful quote can still drift from its source.

    Strips markdown emphasis, folds typographic quotes and dashes to ASCII, and
    collapses runs of whitespace. Case is deliberately preserved, because
    matching is case-sensitive.
    """
    text = _EMPHASIS.sub("", text)
    text = _SINGLE_QUOTES.sub("'", text)
    text = _DOUBLE_QUOTES.sub('"', text)
    text = _DASHES.sub("-", text)
    return _WHITESPACE.sub(" ", text).strip()


def match_citation(quote: str, corpus: Sequence[CorpusEntry]) -> CorpusEntry | None:
    """Find the first corpus entry that contains the quote, or None.

    Only the quote is ever verified; a model's explanation of it is not passed
    here. Corpus order is meaningful, running specific before general, so the
    first match wins rather than the best one.
    """
    needle = normalize_citation(quote)
    if len(needle) < MIN_NORMALIZED_LENGTH:
        return None
    return next(
        (entry for entry in corpus if needle in normalize_citation(entry.text)),
        None,
    )
