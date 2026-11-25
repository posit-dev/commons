"""Rebuild conversations from the chat spans a logging agent records.

``pkg-r/R/trajectory-read.R`` holds the R counterpart.
"""

import functools
import json
import logging
import re
import warnings
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from chatlas import Turn, UserTurn
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
from ._semconv import (
    INPUT_MESSAGES,
    OUTPUT_MESSAGES,
    SYSTEM_INSTRUCTIONS,
    UnlinkedRequest,
    has_json,
    message_turns,
    system_turns,
    trajectory_turns,
)

TITLE_PROMPT = "You title chat conversations."
MISSING_INPUT = "(Input content was not captured.)"
MISSING_RESULT = "(Tool result was not captured.)"

_logger = logging.getLogger(__name__)

_EPOCH = datetime(1970, 1, 1, tzinfo=UTC)
_REMINDER = re.compile(r"^<(system-instruction|reminder)>.*</\1>$", re.DOTALL)

_SpanKey = tuple[str, str]


@dataclass(frozen=True)
class Exchange:
    """One exchange of a conversation: a user's question and the turns that answer it.

    `turns` starts with the user's turn and runs to the turn before the next
    question. They are the same `Turn` objects as in `Trajectory.turns`.
    `tag` is the answer's provenance tag, or None when none was recorded.
    `decisions` are the `CitationDecision`s recorded for the answer.
    """

    turns: list[Turn]
    tag: Tag | None
    decisions: list[CitationDecision]


@dataclass(frozen=True)
class Trajectory:
    """One logged conversation.

    `turns` are its chatlas turns as of its latest chat activity, and
    `last_active` is the time of that activity, in UTC. `user` is the
    authenticated user of the session, from the conversation's earliest
    recorded chat, or None when none was recorded. `exchanges` splits
    `turns` at each question the user asked, with the provenance recorded
    for each answer. Turns before the first question, such as the system
    prompt, are in no exchange.
    """

    turns: list[Turn]
    last_active: datetime
    user: str | None
    exchanges: list[Exchange]


@dataclass(frozen=True)
class _Record:
    """The provenance recorded for an exchange's answer."""

    tag: Tag | None
    decisions: list[CitationDecision]


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
    record: _Record
    recorded: str  # the record as written, which claims compare by


def build_trajectories(spans: Sequence[Span]) -> dict[str, Trajectory]:
    """The conversations the chat spans record, keyed by conversation id, oldest first."""
    index = span_index(spans)
    chat_spans = [span for span in spans if is_chat_span(span)]
    latest = latest_chat_spans(chat_spans)
    by_conversation = chat_spans_by_conversation(chat_spans)
    turns_of = functools.partial(
        _chat_span_turns, cache={}, by_conversation=by_conversation, index=index
    )
    provenance_spans = _latest_provenance_spans(spans, index)
    calls = _recorded_calls(chat_spans, index, provenance_spans)
    candidates = _call_candidates(calls, turns_of)

    trajectories: dict[str, Trajectory] = {}
    for id_, span in latest.items():
        turns = turns_of(span)
        exchanges = split_exchanges(turns)
        records = _associate_provenance(exchanges, candidates.get(id_, []), id_)
        trajectories[id_] = Trajectory(
            turns=list(turns),
            last_active=_instant(span_time(span)),
            user=_conversation_user(by_conversation[id_], index),
            exchanges=[
                Exchange(turns=exchange, tag=record.tag, decisions=record.decisions)
                for exchange, record in zip(exchanges, records, strict=True)
            ],
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
            stacklevel=3,  # the caller of trajectory_read()
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


def chat_spans_by_conversation(chat_spans: Sequence[Span]) -> dict[str, list[Span]]:
    """The chat spans of each conversation, in the order given."""
    by_conversation: dict[str, list[Span]] = {}
    for span in chat_spans:
        by_conversation.setdefault(conversation_id(span), []).append(span)
    return by_conversation


def latest_chat_spans(chat_spans: Sequence[Span]) -> dict[str, Span]:
    """The chat span that supplies each conversation's turns, oldest first."""
    latest: dict[str, Span] = {}
    for span in chat_spans:
        id_ = conversation_id(span)
        current = latest.get(id_)
        if current is None or _is_preferred(span, current):
            latest[id_] = span
    return dict(sorted(latest.items(), key=lambda item: span_time(item[1])))


def chat_span_gives_turns(span: Span, index: dict[_SpanKey, Span]) -> bool:
    """Does the chat span give its conversation turns, as recorded or rebuilt?"""
    if trajectory_turns(span):
        return True
    return (
        not has_json(span.attributes.get(INPUT_MESSAGES))
        and _turn_ancestor(span, index) is not None
    )


def reaches_first_question(chat_spans: Sequence[Span]) -> bool:
    """Do a conversation's chat spans reach back to its first question?

    True when the earliest of them, leaving out title calls, records one
    exchange. The spans after it then hold every later exchange. Earliest is
    by `span_time`, as `_conversation_user` picks the span the user is read
    from.
    """
    candidates = [span for span in chat_spans if not _is_title_span(span)]
    if not candidates:
        return False
    earliest = min(candidates, key=span_time)
    return len(split_exchanges(trajectory_turns(earliest))) == 1


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


def span_index(spans: Sequence[Span]) -> dict[_SpanKey, Span]:
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


def has_severed_ancestry(spans: Sequence[Span]) -> bool:
    """Has a chat span lost a parent between it and its turn span?"""
    index = span_index(spans)
    return any(_ancestry_severed(span, index) for span in spans if is_chat_span(span))


def _ancestry_severed(span: Span, index: dict[_SpanKey, Span]) -> bool:
    # A missing parent means a partial fetch, which a wider fetch can fix; a
    # root does not. The step limit ends a cycle.
    current = span
    for _ in range(len(index)):
        if current.name == TURN_SPAN or not current.parent_span_id:
            return False
        parent = index.get((span.trace_id, current.parent_span_id))
        if parent is None:
            return True
        current = parent
    return False


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


def _chat_span_turns(
    span: Span,
    cache: dict[_SpanKey, list[Turn]],
    by_conversation: dict[str, list[Span]],
    index: dict[_SpanKey, Span],
) -> list[Turn]:
    """The turns a selected chat span supplies, built once per span.

    When the span records no input and sits below a turn span, its history is
    rebuilt from earlier spans.
    """
    key = _span_key(span)
    if key not in cache:
        cache[key] = _recover_missing_input(
            span, trajectory_turns(span), by_conversation, index
        )
    return cache[key]


def _recover_missing_input(
    span: Span,
    turns: list[Turn],
    by_conversation: dict[str, list[Span]],
    index: dict[_SpanKey, Span],
) -> list[Turn]:
    """The span's turns, with its history rebuilt when its input is missing."""
    # A recorder that cannot write a call's input (rich content) leaves it
    # out, so the history is rebuilt from the conversation's earlier spans.
    if has_json(span.attributes.get(INPUT_MESSAGES)):
        return turns
    if _turn_ancestor(span, index) is None:
        return turns
    pairs: list[tuple[Span, Span]] = []
    for candidate in by_conversation.get(conversation_id(span), []):
        turn = _turn_ancestor(candidate, index)
        if turn is not None and not _is_title_span(candidate):
            pairs.append((candidate, turn))
    pairs.sort(key=lambda pair: span_time(pair[0]))
    key = _span_key(span)
    target = next(
        (i for i, (candidate, _) in enumerate(pairs) if _span_key(candidate) == key),
        None,
    )
    if target is None:
        return turns
    history: Span | None = None
    start = 0
    for i in range(target):
        if has_json(pairs[i][0].attributes.get(INPUT_MESSAGES)):
            history, start = pairs[i][0], i
    return _recovered_turns(span, history, pairs[start : target + 1])


def _recovered_turns(
    latest: Span,
    history: Span | None,
    output_spans: Sequence[tuple[Span, Span]],
) -> list[Turn]:
    """The history's input, then each output span's output, in order."""
    requests: dict[str, ContentToolRequest] = {}
    system = system_turns(latest.attributes.get(SYSTEM_INSTRUCTIONS))
    if not system and history is not None:
        system = system_turns(history.attributes.get(SYSTEM_INSTRUCTIONS))
    if history is None:
        input_ = [_missing_input_turn()]
    else:
        input_ = message_turns(history.attributes.get(INPUT_MESSAGES), requests)
    output: list[Turn] = []
    previous: list[Turn] = []
    previous_turn: _SpanKey | None = None
    for chat_span, turn_span in output_spans:
        turn_key = _span_key(turn_span)
        if previous_turn is not None:
            if turn_key == previous_turn:
                missing = _missing_tool_results(previous)
                if missing is not None:
                    output.append(missing)
            else:
                output.append(_missing_input_turn())
        previous = message_turns(chat_span.attributes.get(OUTPUT_MESSAGES), requests)
        output.extend(previous)
        previous_turn = turn_key
    return [*system, *input_, *output]


def _missing_input_turn() -> Turn:
    return UserTurn([ContentText(text=MISSING_INPUT)])


def _missing_tool_results(turns: Sequence[Turn]) -> Turn | None:
    """A placeholder result for each tool request in the turns, if any."""
    results = [
        ContentToolResult(value=MISSING_RESULT, request=content)
        for turn in turns
        for content in turn.contents
        if isinstance(content, ContentToolRequest)
    ]
    return UserTurn(results) if results else None


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


def _span_record(span: Span) -> _Record:
    """The provenance a span records; what does not decode reads as absent."""
    tag = span.attributes.get(TAG_ATTRIBUTE)
    try:
        tag = None if tag is None else Tag(str(tag))
    except ValueError:
        tag = None
    return _Record(tag, _decisions(span.attributes.get(CANDIDATES_ATTRIBUTE)))


def _recorded_text(span: Span) -> str:
    """The tag and decisions as recorded, before either is checked, as JSON text."""
    tag = span.attributes.get(TAG_ATTRIBUTE)
    decisions = _parsed(span.attributes.get(CANDIDATES_ATTRIBUTE))
    return json.dumps(
        [None if tag is None else str(tag), [] if decisions is None else decisions],
        default=repr,
    )


def _parsed(text: object) -> Any:
    if not isinstance(text, str):
        return None
    try:
        return json.loads(text)
    except (ValueError, RecursionError):
        return None


def _decisions(text: object) -> list[CitationDecision]:
    records = _parsed(text)
    if not isinstance(records, list):
        return []
    decisions: list[CitationDecision] = []
    for record in records:
        if not isinstance(record, dict):
            continue
        fields: dict[str, Any] = record
        quote = fields.get("quote")
        status: Any = fields.get("status")
        label = fields.get("label")
        if any(v is not None and not isinstance(v, str) for v in (quote, label)):
            continue
        try:
            decision = CitationDecision(
                quote=quote,
                status=status,
                label=label,
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


def _signature_text(signature: object) -> str:
    return json.dumps(signature, sort_keys=True, default=repr)


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
        request = content.request
        unlinked = request is None or isinstance(request, UnlinkedRequest)
        return {
            "type": "tool_result",
            "id": None if unlinked else request.id,
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
    calls: dict[_SpanKey, _RecordedCall], turns_of: Callable[[Span], list[Turn]]
) -> dict[str, list[_Candidate]]:
    """The records that complete calls claim, by conversation id."""
    candidates: dict[str, list[_Candidate]] = {}
    for call in calls.values():
        exchanges = split_exchanges(turns_of(call.chat_span))
        if not exchanges or not _exchange_is_complete(exchanges[-1]):
            continue
        candidates.setdefault(call.conversation_id, []).append(
            _Candidate(
                signature=[_exchange_signature(e) for e in exchanges],
                record=_span_record(call.record_span),
                recorded=_recorded_text(call.record_span),
            )
        )
    return candidates


def _associate_provenance(
    exchanges: Sequence[Sequence[Turn]],
    candidates: Sequence[_Candidate],
    conversation_id: str,
) -> list[_Record]:
    """One record per exchange, from the calls whose history leads to it.

    Records attach by matching recorded history rather than by position, so
    an edited or restored conversation never moves a record to another
    exchange.
    """
    canonical = [_signature_text(_exchange_signature(e)) for e in exchanges]
    claims: list[list[_Candidate]] = [[] for _ in exchanges]
    for candidate in candidates:
        length = len(candidate.signature)
        if (
            0 < length <= len(canonical)
            and [_signature_text(e) for e in candidate.signature] == canonical[:length]
        ):
            claims[length - 1].append(candidate)

    records: list[_Record] = []
    conflict = False
    for claim in claims:
        # Claims compare as recorded, so a decision dropped on reading still
        # counts.
        distinct = {c.recorded: c.record for c in claim}
        # A conflict fails closed: the exchange gets no record.
        if len(distinct) == 1:
            records.append(next(iter(distinct.values())))
        else:
            conflict = conflict or len(distinct) > 1
            records.append(_Record(None, []))
    if conflict:
        warnings.warn(
            f"Ignoring conflicting audit records in conversation '{conversation_id}'.",
            UserWarning,
            stacklevel=4,  # the caller of trajectory_read(), via build_trajectories()
        )
    return records
