"""Verifying a quoted citation against a trusted corpus.

The normalization rules, the whitespace set, and the matching verdicts are a
cross-language contract pinned by ``tests/shared/citations.json``; change that
fixture, not just this file. ``pkg-r/R/citations.R`` implements the same
contract for R.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Literal

__all__ = ["CorpusEntry", "match_citation", "normalize_citation"]

# The minimum length is a guard, not a tuning knob: a fragment this short can
# appear in a trusted source by coincidence and must not promote an answer.
MIN_NORMALIZED_LENGTH = 10

# The Unicode White_Space set, spelled out. Neither `\s` is used: Python's is
# Unicode-aware while R's default engine defers to locale-dependent C library
# classification, so relying on either would let the same quote verify in one
# language and not the other, with nothing erroring.
_WHITESPACE = re.compile(
    "[ \t\n\v\f\r\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+"
)
_EMPHASIS = re.compile(r"[*_`]")
_SINGLE_QUOTES = re.compile("[\u2018\u2019]")
_DOUBLE_QUOTES = re.compile("[\u201c\u201d]")
_DASHES = re.compile("[\u2013\u2014]")

CitationKind = Literal["prose", "definition", "schema"]


@dataclass(frozen=True)
class CorpusEntry:
    """One trusted passage a citation can be verified against.

    ``label`` is reader-facing and appears in the rendered aside.
    """

    label: str
    kind: CitationKind
    text: str


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
    # Collapsing first leaves at most a single space at each end, so stripping
    # only the space matches R's trimws() default rather than exceeding it.
    return _WHITESPACE.sub(" ", text).strip(" ")


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
