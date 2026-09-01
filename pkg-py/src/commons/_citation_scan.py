"""Project a model's streamed text for display, holding reserved markup back.

The projection is a cross-language contract pinned by the ``citation_scan``
cases in ``tests/shared/citations.json``; change that fixture, not just this
file. ``pkg-r/R/citation-scan.R`` implements the same contract for R.

Reserved markup is anything the display layer treats as trusted: a
``<commons-citation>`` block, which becomes an aside only once its quote
verifies, and a ``<shiny-aside>``, which the model must never be able to author.
Output cannot depend on where a chunk boundary falls, so text that could still
grow into a reserved tag is held back until the next chunk decides it.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Literal

from ._citations import (
    CitationDecision,
    CorpusEntry,
    citation_aside_html,
    match_citation,
    parse_commons_citation,
)

__all__ = ["CitationScanner"]

CITATION_OPEN = "<commons-citation>"
CITATION_CLOSE = "</commons-citation>"
# Attributes may follow, so the opening aside tag is matched without its bracket.
ASIDE_OPEN = "<shiny-aside"
ASIDE_CLOSE = "</shiny-aside>"

# A body this large is a runaway rather than a citation. Past it the element is
# abandoned, which is what keeps an unclosed tag from buffering without limit.
ELEMENT_BODY_CAP = 16384

_Mode = Literal["text", "citation", "discard"]
_Action = Literal["citation", "aside", "drop", "close"]

# Matched as patterns rather than by lowercasing the buffer, because casefolding
# can change a string's length and would shift every position that follows.
_LITERALS = {
    literal: re.compile(re.escape(literal), re.IGNORECASE)
    for literal in (CITATION_OPEN, CITATION_CLOSE, ASIDE_OPEN, ASIDE_CLOSE)
}
_PREFIXES = {
    literal: [
        re.compile(re.escape(literal[:length]) + r"\Z", re.IGNORECASE)
        for length in range(len(literal))
    ]
    for literal in _LITERALS
}
# The opening tag only counts at the start of a line, so prose that mentions it
# mid-sentence survives.
_CITATION_OPEN_ANCHORED = re.compile(
    r"(?<=\n)" + re.escape(CITATION_OPEN), re.IGNORECASE
)
_CITATION_OPEN_AT_START = re.compile(
    r"(?:^|(?<=\n))" + re.escape(CITATION_OPEN), re.IGNORECASE
)


@dataclass(frozen=True)
class _Event:
    """A reserved literal found in the buffer, and what to do with it."""

    pos: int
    length: int
    action: _Action


def _find(literal: str, buffer: str) -> re.Match[str] | None:
    return _LITERALS[literal].search(buffer)


def _held_back(buffer: str, literal: str, at_line_start: bool | None = None) -> int:
    """Length of the longest buffer suffix that could still grow into ``literal``.

    Pass ``at_line_start`` for a literal that only counts at the start of a
    line, so a tail that could never open an element is emitted rather than
    held; leave it None for the literals that count at any position.
    """
    for length in range(min(len(buffer), len(literal) - 1), 0, -1):
        start = len(buffer) - length
        if at_line_start is not None:
            anchored = at_line_start if start == 0 else buffer[start - 1] == "\n"
            if not anchored:
                continue
        if _PREFIXES[literal][length].match(buffer, start):
            return length
    return 0


class CitationScanner:
    """Rewrite verified citations and drop every other reserved element.

    Feed the model's chunks in and emit what is safe to display now. The
    scanner projects text for display and never rewrites what the caller
    stores, so the turn keeps the model's own words.
    """

    def __init__(
        self,
        corpus: Sequence[CorpusEntry] = (),
        *,
        max_element_bytes: int = ELEMENT_BODY_CAP,
    ) -> None:
        self._corpus = list(corpus)
        self._cap = max_element_bytes
        self._buffer = ""
        self._mode: _Mode = "text"
        self._at_line_start = True
        self._discard_close: str | None = None
        self._candidates: list[CitationDecision] = []
        self._out: list[str] = []

    def feed(self, chunk: str) -> str:
        """Consume a stream chunk and return the text safe to emit now."""
        self._buffer += chunk
        self._out = []
        while self._step():
            pass
        return "".join(self._out)

    def finish(self) -> str:
        """Flush held-back text at end of stream."""
        if self._mode == "text":
            flushed, self._buffer = self._buffer, ""
            return flushed
        # Incomplete model-authored markup must never reach the display.
        self._buffer = ""
        self._mode = "text"
        self._discard_close = None
        return ""

    @property
    def candidates(self) -> list[CitationDecision]:
        """Every candidate citation and its verdict, in the order they arrived."""
        return list(self._candidates)

    @property
    def any_verified(self) -> bool:
        """Whether any candidate's quote was found in the corpus."""
        return any(candidate.status == "accepted" for candidate in self._candidates)

    def _step(self) -> bool:
        """Advance once. True when the buffer moved and another step may apply."""
        if self._mode == "text":
            return self._step_text()
        if self._mode == "citation":
            return self._step_citation()
        return self._step_discard()

    def _step_text(self) -> bool:
        event = self._find_text_event()
        if event is not None:
            prefix = self._buffer[: event.pos]
            literal = self._buffer[event.pos : event.pos + event.length]
            self._emit(prefix)
            self._note_line_start(prefix)
            self._buffer = self._buffer[event.pos + event.length :]
            if event.action == "citation":
                self._mode = "citation"
            elif event.action == "aside":
                self._begin_discard(ASIDE_CLOSE)
            else:
                self._note_line_start(literal)
            return True

        flush_to = len(self._buffer) - self._holdback_length()
        if flush_to > 0:
            flushed = self._buffer[:flush_to]
            self._emit(flushed)
            self._note_line_start(flushed)
            self._buffer = self._buffer[flush_to:]
        return False

    def _step_citation(self) -> bool:
        event = self._find_reserved_event()
        if event is not None and event.action == "close" and event.pos <= self._cap:
            body = self._buffer[: event.pos]
            self._buffer = self._buffer[event.pos + event.length :]
            self._close_citation(body)
            self._mode = "text"
            self._at_line_start = False
            return True
        # Any other reserved literal inside the body means the element is not a
        # citation at all, so it is abandoned rather than parsed.
        if event is not None:
            self._begin_discard(CITATION_CLOSE)
            return True
        if self._confirmed_body_length() > self._cap:
            self._begin_discard(CITATION_CLOSE)
            return True
        return False

    def _step_discard(self) -> bool:
        assert self._discard_close is not None
        match = _find(self._discard_close, self._buffer)
        if match is not None:
            self._note_line_start(self._buffer[: match.end()])
            self._buffer = self._buffer[match.end() :]
            self._mode = "text"
            self._discard_close = None
            return True

        drop_to = len(self._buffer) - _held_back(self._buffer, self._discard_close)
        if drop_to > 0:
            self._note_line_start(self._buffer[:drop_to])
            self._buffer = self._buffer[drop_to:]
        return False

    def _find_text_event(self) -> _Event | None:
        pattern = (
            _CITATION_OPEN_AT_START if self._at_line_start else _CITATION_OPEN_ANCHORED
        )
        found: list[tuple[re.Match[str] | None, int, _Action]] = [
            (pattern.search(self._buffer), len(CITATION_OPEN), "citation"),
            (_find(ASIDE_OPEN, self._buffer), len(ASIDE_OPEN), "aside"),
            # A close tag with no open one is stray markup and is dropped, but
            # it leaves the text around it alone.
            (_find(CITATION_CLOSE, self._buffer), len(CITATION_CLOSE), "drop"),
            (_find(ASIDE_CLOSE, self._buffer), len(ASIDE_CLOSE), "drop"),
        ]
        events = [
            _Event(match.start(), length, action)
            for match, length, action in found
            if match is not None
        ]
        return min(events, key=lambda event: event.pos, default=None)

    def _find_reserved_event(self) -> _Event | None:
        found: list[tuple[re.Match[str] | None, int, _Action]] = [
            (_find(CITATION_OPEN, self._buffer), len(CITATION_OPEN), "drop"),
            (_find(CITATION_CLOSE, self._buffer), len(CITATION_CLOSE), "close"),
            (_find(ASIDE_OPEN, self._buffer), len(ASIDE_OPEN), "drop"),
            (_find(ASIDE_CLOSE, self._buffer), len(ASIDE_CLOSE), "drop"),
        ]
        events = [
            _Event(match.start(), length, action)
            for match, length, action in found
            if match is not None
        ]
        return min(events, key=lambda event: event.pos, default=None)

    def _confirmed_body_length(self) -> int:
        """Body length so far, less a partial close tag that may still complete.

        Counting the partial tag would let a chunk boundary push an in-range
        body over the cap.
        """
        return len(self._buffer) - _held_back(self._buffer, CITATION_CLOSE)

    def _holdback_length(self) -> int:
        return max(
            _held_back(self._buffer, CITATION_OPEN, self._at_line_start),
            _held_back(self._buffer, ASIDE_OPEN),
            _held_back(self._buffer, CITATION_CLOSE),
            _held_back(self._buffer, ASIDE_CLOSE),
        )

    def _close_citation(self, body: str) -> None:
        parsed = parse_commons_citation(body)
        if parsed is None:
            self._candidates.append(CitationDecision(quote=None, status="malformed"))
            return
        entry = match_citation(parsed.quote, self._corpus)
        if entry is None:
            self._candidates.append(
                CitationDecision(quote=parsed.quote, status="rejected")
            )
            return
        self._emit(
            citation_aside_html(
                parsed.quote, parsed.explanation, entry.label, entry.kind
            )
        )
        self._candidates.append(
            CitationDecision(
                quote=parsed.quote,
                status="accepted",
                label=entry.label,
                kind=entry.kind,
            )
        )

    def _begin_discard(self, close_literal: str) -> None:
        self._mode = "discard"
        self._discard_close = close_literal

    def _emit(self, text: str) -> None:
        if text:
            self._out.append(text)

    def _note_line_start(self, original: str) -> None:
        # Tag anchoring follows the model's own text, not the projected output.
        if original:
            self._at_line_start = original.endswith("\n")
