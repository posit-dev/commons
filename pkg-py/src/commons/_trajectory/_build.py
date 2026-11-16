"""Rebuild conversations from the chat spans a logging agent records.

``pkg-r/R/trajectory-read.R`` holds the R counterpart.
"""

import json
import logging
import re
import warnings
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from chatlas import Turn
from chatlas.types import ContentText, ContentToolRequest, ContentToolResult

from .._citations import CitationDecision
from .._provenance import Tag
from .._tracing import (
    CANDIDATES_ATTRIBUTE,
    PROVENANCE_SPAN,
    TAG_ATTRIBUTE,
    TURN_SPAN,
    USER_ATTRIBUTE,
)
from ._otlp import Span
from ._semconv import SYSTEM_INSTRUCTIONS, system_turns, trajectory_turns

TITLE_PROMPT = "You title chat conversations."

_logger = logging.getLogger(__name__)

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


@dataclass(frozen=True)
class _RecordedCall:
    """A turn span's latest chat span, and the span that records its provenance."""

    conversation_id: str
    record_span: Span
    chat_span: Span


@dataclass(frozen=True)
class _Candidate:
    """A recorded call's exchange signatures and the record it claims for the last."""

    signature: list[list[dict[str, Any]]]
    record: ExchangeProvenance


def build_trajectories(spans: Sequence[Span]) -> dict[str, Trajectory]:
    """The conversations the chat spans record, keyed by conversation id, oldest first."""
    index = _span_index(spans)
    chat_spans = [span for span in spans if is_chat_span(span)]
    latest = latest_chat_spans(chat_spans)
    by_conversation: dict[str, list[Span]] = {}
    for span in chat_spans:
        by_conversation.setdefault(conversation_id(span), []).append(span)
    provenance_spans = _latest_provenance_spans(spans, index)
    calls = _recorded_calls(chat_spans, index, provenance_spans)
    cache: dict[_SpanKey, list[Turn]] = {}
    candidates = _call_candidates(calls, cache)

    trajectories: dict[str, Trajectory] = {}
    for id_, span in latest.items():
        turns = _chat_span_turns(span, cache)
        trajectories[id_] = Trajectory(
            turns=list(turns),
            last_active=_instant(span_time(span)),
            user=_conversation_user(by_conversation[id_], index),
            provenance=_associate_provenance(
                split_exchanges(turns), candidates.get(id_, []), id_
            ),
        )
    return trajectories


def drop_contentless(trajectories: dict[str, Trajectory]) -> dict[str, Trajectory]:
    """Drop the conversations with no turns, saying why when that is all of them."""
    empty = sum(1 for trajectory in trajectories.values() if not trajectory.turns)
    if trajectories and empty == len(trajectories):
        warnings.warn(
            f"Found {empty} {_conversations(empty)} of spans, but none record "
            "message content; returning none. Message content is captured only "
            "when the agent runs with log=True while OpenTelemetry tracing is "
            "active. On Posit Connect, check the app's startup log for warnings "
            "from commons.",
            UserWarning,
            stacklevel=2,
        )
    elif empty:
        _logger.info(
            "Dropping %d %s whose spans record no message content.",
            empty,
            _conversations(empty),
        )
    return {id_: t for id_, t in trajectories.items() if t.turns}


def _conversations(count: int) -> str:
    return "conversation" if count == 1 else "conversations"


def filter_chat_spans(
    spans: Sequence[Span], since: datetime | None, until: datetime | None
) -> list[Span]:
    """Keep the chat spans that start in the window, and every other span."""
    low = None if since is None else _nanos(since)
    high = None if until is None else _nanos(until)
    return [
        span
        for span in spans
        if not is_chat_span(span)
        or (
            (low is None or span.start_time_unix_nano >= low)
            and (high is None or span.start_time_unix_nano < high)
        )
    ]


def _nanos(at: datetime) -> int:
    return (at - _EPOCH) // timedelta(microseconds=1) * 1000


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


def _latest_provenance_spans(
    spans: Sequence[Span], index: dict[_SpanKey, Span]
) -> dict[_SpanKey, Span]:
    """The latest provenance span below each turn span, keyed by the turn span."""
    latest: dict[_SpanKey, Span] = {}
    for span in spans:
        if span.name != PROVENANCE_SPAN:
            continue
        turn = _turn_ancestor(span, index)
        if turn is None:
            continue
        key = _span_key(turn)
        current = latest.get(key)
        if current is None or span_time(span) > span_time(current):
            latest[key] = span
    return latest


def _recorded_calls(
    chat_spans: Sequence[Span],
    index: dict[_SpanKey, Span],
    provenance_spans: dict[_SpanKey, Span],
) -> dict[_SpanKey, _RecordedCall]:
    """Each turn span's latest chat span, keyed by the turn span."""
    calls: dict[_SpanKey, _RecordedCall] = {}
    for span in chat_spans:
        turn = _turn_ancestor(span, index)
        if turn is None:
            continue
        key = _span_key(turn)
        current = calls.get(key)
        if current is None or span_time(span) > span_time(current.chat_span):
            calls[key] = _RecordedCall(
                conversation_id=conversation_id(span),
                record_span=provenance_spans.get(key, turn),
                chat_span=span,
            )
    return calls


def _span_record(span: Span) -> ExchangeProvenance:
    """The provenance a span records; what does not decode reads as absent."""
    tag = span.attributes.get(TAG_ATTRIBUTE)
    try:
        tag = None if tag is None else Tag(str(tag))
    except ValueError:
        tag = None
    return ExchangeProvenance(
        tag, _decisions(span.attributes.get(CANDIDATES_ATTRIBUTE))
    )


def _decisions(text: object) -> list[CitationDecision]:
    if not isinstance(text, str):
        return []
    try:
        records = json.loads(text)
    except (ValueError, RecursionError):
        return []
    if not isinstance(records, list):
        return []
    decisions: list[CitationDecision] = []
    for record in records:
        if not isinstance(record, dict):
            continue
        fields: dict[str, Any] = record
        quote = fields.get("quote")
        status: Any = fields.get("status")
        if quote is not None and not isinstance(quote, str):
            continue
        try:
            decision = CitationDecision(
                quote=quote,
                status=status,
                label=fields.get("label"),
                kind=fields.get("kind"),
            )
        except (ValueError, TypeError):
            continue
        decisions.append(decision)
    return decisions


def _exchange_signature(exchange: Sequence[Turn]) -> list[dict[str, Any]]:
    """An exchange's turns as plain content, so two recordings of it compare equal."""
    return [
        {"role": turn.role, "contents": [_content_signature(c) for c in turn.contents]}
        for turn in exchange
    ]


def _content_signature(content: object) -> dict[str, Any]:
    if isinstance(content, ContentText):
        return {"type": "text", "text": content.text}
    if isinstance(content, ContentToolRequest):
        return {
            "type": "tool_request",
            "id": content.id,
            "name": content.name,
            "arguments": content.arguments,
        }
    if isinstance(content, ContentToolResult):
        return {
            "type": "tool_result",
            "id": None if content.request is None else content.request.id,
            "value": content.value,
        }
    return {"type": type(content).__name__}


def _exchange_is_complete(exchange: Sequence[Turn]) -> bool:
    """Does the exchange end in an answer: an assistant turn with no tool request?"""
    if len(exchange) < 2:
        return False
    final = exchange[-1]
    return final.role == "assistant" and not any(
        isinstance(c, ContentToolRequest) for c in final.contents
    )


def _call_candidates(
    calls: dict[_SpanKey, _RecordedCall], cache: dict[_SpanKey, list[Turn]]
) -> dict[str, list[_Candidate]]:
    """The records that complete calls claim, by conversation id."""
    candidates: dict[str, list[_Candidate]] = {}
    for call in calls.values():
        exchanges = split_exchanges(_chat_span_turns(call.chat_span, cache))
        if not exchanges or not _exchange_is_complete(exchanges[-1]):
            continue
        candidates.setdefault(call.conversation_id, []).append(
            _Candidate(
                signature=[_exchange_signature(e) for e in exchanges],
                record=_span_record(call.record_span),
            )
        )
    return candidates


def _associate_provenance(
    exchanges: Sequence[Sequence[Turn]],
    candidates: Sequence[_Candidate],
    conversation_id: str,
) -> list[ExchangeProvenance]:
    """One record per exchange, from the calls whose history leads to it.

    Records attach by matching recorded history rather than by position, so
    an edited or restored conversation never moves a record to another
    exchange.
    """
    canonical = [_exchange_signature(e) for e in exchanges]
    claims: list[list[ExchangeProvenance]] = [[] for _ in exchanges]
    for candidate in candidates:
        length = len(candidate.signature)
        if 0 < length <= len(canonical) and candidate.signature == canonical[:length]:
            claims[length - 1].append(candidate.record)

    records: list[ExchangeProvenance] = []
    conflict = False
    for claim in claims:
        distinct: list[ExchangeProvenance] = []
        for record in claim:
            if record not in distinct:
                distinct.append(record)
        # A conflict fails closed: the exchange gets no record.
        if len(distinct) == 1:
            records.append(distinct[0])
        else:
            conflict = conflict or len(distinct) > 1
            records.append(ExchangeProvenance(None, []))
    if conflict:
        warnings.warn(
            f"Ignoring conflicting audit records in conversation '{conversation_id}'.",
            UserWarning,
            stacklevel=2,
        )
    return records
