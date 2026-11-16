"""Rebuild conversations from the chat spans a logging agent records.

``pkg-r/R/trajectory-read.R`` holds the R counterpart.
"""

import re
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from chatlas import Turn
from chatlas.types import ContentText, ContentToolResult

from .._citations import CitationDecision
from .._provenance import Tag
from .._tracing import TURN_SPAN, USER_ATTRIBUTE
from ._otlp import Span
from ._semconv import SYSTEM_INSTRUCTIONS, system_turns, trajectory_turns

TITLE_PROMPT = "You title chat conversations."

_EPOCH = datetime(1970, 1, 1, tzinfo=UTC)
_REMINDER = re.compile(r"^<(system-instruction|reminder)>.*</\1>$", re.DOTALL)

_SpanKey = tuple[str, str]


@dataclass(frozen=True)
class ExchangeProvenance:
    """The provenance of one exchange: a user's question and the turns that answer it.

    `tag` is the answer's provenance tag, or None when none was recorded.
    `decisions` are the citation decisions recorded for the answer.
    """

    tag: Tag | None
    decisions: list[CitationDecision]


@dataclass(frozen=True)
class Trajectory:
    """One logged conversation.

    `turns` are its chatlas turns as of its latest chat activity, and
    `last_active` is the time of that activity, in UTC. `user` is the
    authenticated user of the session, from the conversation's earliest
    recorded chat, or None when none was recorded. `provenance` has one
    record per exchange, in order.
    """

    turns: list[Turn]
    last_active: datetime
    user: str | None
    provenance: list[ExchangeProvenance]


def build_trajectories(spans: Sequence[Span]) -> dict[str, Trajectory]:
    """The conversations the chat spans record, keyed by conversation id, oldest first."""
    index = _span_index(spans)
    chat_spans = [span for span in spans if is_chat_span(span)]
    latest = latest_chat_spans(chat_spans)
    by_conversation: dict[str, list[Span]] = {}
    for span in chat_spans:
        by_conversation.setdefault(conversation_id(span), []).append(span)
    cache: dict[_SpanKey, list[Turn]] = {}

    trajectories: dict[str, Trajectory] = {}
    for id_, span in latest.items():
        turns = _chat_span_turns(span, cache)
        trajectories[id_] = Trajectory(
            turns=list(turns),
            last_active=_instant(span_time(span)),
            user=_conversation_user(by_conversation[id_], index),
            provenance=[ExchangeProvenance(None, []) for _ in split_exchanges(turns)],
        )
    return trajectories


def is_chat_span(span: Span) -> bool:
    return span.attributes.get("gen_ai.operation.name") == "chat"


def span_time(span: Span) -> int:
    """The span's end time, or its start time when it has no end time."""
    return span.end_time_unix_nano or span.start_time_unix_nano


def conversation_id(span: Span) -> str:
    """The span's conversation id, or its trace id when it records none."""
    id_ = span.attributes.get("gen_ai.conversation.id")
    return span.trace_id if id_ is None else str(id_)


def latest_chat_spans(chat_spans: Sequence[Span]) -> dict[str, Span]:
    """The chat span that supplies each conversation's turns, oldest first."""
    latest: dict[str, Span] = {}
    for span in chat_spans:
        id_ = conversation_id(span)
        current = latest.get(id_)
        if current is None or _is_preferred(span, current):
            latest[id_] = span
    return dict(sorted(latest.items(), key=lambda item: span_time(item[1])))


def _is_preferred(candidate: Span, current: Span) -> bool:
    candidate_is_title = _is_title_span(candidate)
    if candidate_is_title != _is_title_span(current):
        return not candidate_is_title
    return span_time(candidate) > span_time(current)


def _is_title_span(span: Span) -> bool:
    """Is this the call shinychat makes to title the conversation?"""
    system = system_turns(span.attributes.get(SYSTEM_INSTRUCTIONS))
    return bool(system) and system[0].text.startswith(TITLE_PROMPT)


def split_exchanges(turns: Sequence[Turn]) -> list[list[Turn]]:
    """Split turns at each plain user turn; turns before the first are in none."""
    exchanges: list[list[Turn]] = []
    for turn in turns:
        if (
            turn.role == "user"
            and not any(isinstance(c, ContentToolResult) for c in turn.contents)
            and not _is_internal_turn(turn)
        ):
            exchanges.append([turn])
        elif exchanges:
            exchanges[-1].append(turn)
    return exchanges


def _is_internal_turn(turn: Turn) -> bool:
    # Matched by text, since a recorded turn does not keep the content's class.
    return turn.role == "user" and all(
        isinstance(c, ContentText) and _REMINDER.match(c.text) is not None
        for c in turn.contents
    )


def _instant(nanos: int) -> datetime:
    try:
        return _EPOCH + timedelta(microseconds=nanos // 1000)
    except OverflowError:
        # A time past the range of datetime reads as that range's end.
        if nanos > 0:
            return datetime.max.replace(tzinfo=UTC)
        return datetime.min.replace(tzinfo=UTC)


def _span_key(span: Span) -> _SpanKey:
    return (span.trace_id, span.span_id)


def _span_index(spans: Sequence[Span]) -> dict[_SpanKey, Span]:
    index: dict[_SpanKey, Span] = {}
    for span in spans:
        index.setdefault(_span_key(span), span)
    return index


def _turn_ancestor(span: Span, index: dict[_SpanKey, Span]) -> Span | None:
    """The span's nearest turn span, itself included; the step limit ends a cycle."""
    current = span
    for _ in range(len(index)):
        if current.name == TURN_SPAN:
            return current
        if not current.parent_span_id:
            return None
        parent = index.get((span.trace_id, current.parent_span_id))
        if parent is None:
            return None
        current = parent
    return None


def _conversation_user(
    chat_spans: Sequence[Span], index: dict[_SpanKey, Span]
) -> str | None:
    """The user recorded above the conversation's earliest non-title chat span."""
    candidates = [span for span in chat_spans if not _is_title_span(span)]
    if not candidates:
        return None
    turn = _turn_ancestor(min(candidates, key=span_time), index)
    user = None if turn is None else turn.attributes.get(USER_ATTRIBUTE)
    return user if isinstance(user, str) and user else None


def _chat_span_turns(span: Span, cache: dict[_SpanKey, list[Turn]]) -> list[Turn]:
    """The turns a selected chat span records, parsed once per span."""
    key = _span_key(span)
    if key not in cache:
        cache[key] = trajectory_turns(span)
    return cache[key]
