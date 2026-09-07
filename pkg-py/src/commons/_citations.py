"""Citations: verifying a quote against a trusted corpus, and asking for one.

The normalization rules and the matching verdicts are a cross-language contract
pinned by ``tests/shared/citations.json``, and where the citation request lands
by ``tests/shared/citation-request.json``; change those fixtures, not just this
file. ``pkg-r/R/citations.R`` implements the same contracts for R.
"""

from __future__ import annotations

import html
import re
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any, Literal, get_args

from chatlas import ContentToolResult, Turn
from chatlas.types import ContentText

from ._prompt import read_prompt
from ._provenance import Tag

__all__ = [
    "CitationDecision",
    "CitationRequest",
    "CorpusEntry",
    "ParsedCitation",
    "citation_aside_html",
    "match_citation",
    "normalize_citation",
    "parse_commons_citation",
    "tool_result",
    "turn_has_user_message",
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


# Derived from the types so the runtime guards and the annotations cannot drift.
_DECISION_STATUSES = get_args(CitationStatus)
_CITATION_KINDS = get_args(CitationKind)


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
    kind: CitationKind | None = None

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
        if self.kind is not None and self.kind not in _CITATION_KINDS:
            raise ValueError(
                f"Unknown citation kind {self.kind!r}; expected one of "
                f"{', '.join(_CITATION_KINDS)}."
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


def citation_aside_html(quote: str, explanation: str, label: str, kind: str) -> str:
    """Render a verified citation as the aside shinychat displays.

    ``kind`` selects the icon the UI layer draws beside the label. No icon is
    emitted yet: the URL comes from the served asset bundle, which arrives with
    the Python UI (see decision D10 in the port plan).
    """
    reason = f"{explanation}\n\n" if explanation else ""
    blockquote = "> " + quote.strip().replace("\n", "\n> ")
    # shinychat only renders the popover's title row for grouped asides, so the
    # body carries its own title to keep the source named for a lone citation.
    title = (
        '<span class="commons-citation-title">'
        '<span class="commons-citation-title-label">'
        f"{html.escape(label, quote=False)}</span></span>\n\n"
    )
    return (
        f'<shiny-aside label="{_escape_attr(label)}">'
        f"{title}{reason}{blockquote}</shiny-aside>"
    )


# Ampersands first, so the entities this generates are not escaped again.
def _escape_attr(text: str) -> str:
    return text.replace("&", "&amp;").replace('"', "&quot;")


def tool_result(value: Any, tag: Tag | None = None) -> ContentToolResult:
    """A tool result carrying the provenance tag of the output it holds.

    The tag is read back off ``extra`` when the turn is classified, so it is
    set here rather than at the point a result is added to the conversation.
    """
    return ContentToolResult(value=value, extra={"commons_tag": tag})


def citation_reminder_text() -> str:
    """The reminder text, from the prompt file both packages ship."""
    return read_prompt("citation-request.md")


@dataclass
class CitationRequest:
    """Whether this user turn has carried the citation reminder yet.

    The citation contract lives in the system prompt; this is the nudge that
    rides on the first tool result of a turn whose output has to be cited.
    """

    reminder: str = field(default_factory=citation_reminder_text)
    requested: bool = False

    def add_request(self, result: ContentToolResult) -> ContentToolResult:
        if self.requested:
            return result
        self.requested = True
        result.value = _with_reminder(result.value, self.reminder)
        return result

    def reset(self) -> None:
        """Start a new user turn, so the next eligible result asks again."""
        self.requested = False


def _with_reminder(value: Any, reminder: str) -> Any:
    if isinstance(value, str):
        return f"{value}\n\n{reminder}"
    part = ContentText(text=reminder)
    if isinstance(value, list):
        return [*value, part]
    # A tool result can hold something that is neither: it becomes the first
    # part rather than being reformatted to make room for the reminder.
    return [value, part]


def turn_has_user_message(turn: Turn) -> bool:
    """Whether a turn asks something new, rather than continuing the tool loop.

    A turn of nothing but tool results is the same question still running, so
    the reminder stays spent until the person says something.
    """
    return any(not isinstance(content, ContentToolResult) for content in turn.contents)
