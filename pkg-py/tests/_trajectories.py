"""Run the cases in ``tests/shared/trajectories/build.json`` and describe what they read.

The R suite's runner is ``trajectory_fixture_run()`` in
``pkg-r/tests/testthat/helper-otlp.R``.
"""

import json
import logging
import warnings
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest
from chatlas import Turn
from chatlas.types import ContentText, ContentToolRequest, ContentToolResult

from commons._trajectory import trajectory_read
from commons._trajectory._build import (
    Exchange,
    Trajectory,
    build_trajectories,
)
from commons._trajectory._otlp import parse_otlp_lines
from tests._shared import load_shared_fixture

BUILD = load_shared_fixture("trajectories/build")
BUILD_MEMBERS = (
    "conversation_id",
    "trace_id_fallback",
    "latest_span",
    "title_spans",
    "last_active",
    "session_users",
    "earliest_user",
    "exchanges",
    "provenance",
    "no_provenance",
    "duplicate_records",
    "conflicting_records",
    "incomplete_call",
)
READ_MEMBERS = ("contentless", "n", "window", "as_of")
BOUND_MEMBERS = ("local_midnight", "complete_parse")


def cases(members: Sequence[str]) -> list[Any]:
    return [
        pytest.param(BUILD[m], case, id=f"{m}: {case['name']}")
        for m in members
        for case in BUILD[m]["cases"]
    ]


_SHORTHAND = (
    ("conversation", "gen_ai.conversation.id"),
    ("system", "gen_ai.system_instructions"),
    ("input", "gen_ai.input.messages"),
    ("output", "gen_ai.output.messages"),
)


def _fixture_span(span: dict[str, Any]) -> dict[str, Any]:
    attributes: dict[str, Any] = (
        {"gen_ai.operation.name": "chat"} if span.get("chat") else {}
    )
    attributes.update({attr: span[key] for key, attr in _SHORTHAND if key in span})
    attributes.update(span.get("attributes", {}))
    encoded: dict[str, Any] = {
        "traceId": span["trace"],
        "spanId": span["span"],
        "name": "chat test-model" if span.get("chat") else span["name"],
        "attributes": [
            {
                "key": k,
                "value": {"stringValue": v if isinstance(v, str) else json.dumps(v)},
            }
            for k, v in attributes.items()
        ],
    }
    for key, field, default in (
        ("start", "startTimeUnixNano", "1"),
        ("end", "endTimeUnixNano", "2"),
    ):
        if span.get(key) is not False:
            encoded[field] = span.get(key, default)
    if "parent" in span:
        encoded["parentSpanId"] = span["parent"]
    return encoded


def fixture_line(spans: list[dict[str, Any]]) -> str:
    spans_ = [_fixture_span(span) for span in spans]
    return json.dumps({"resourceSpans": [{"scopeSpans": [{"spans": spans_}]}]})


def _descriptor(content: object, turns: Sequence[Turn]) -> dict[str, Any]:
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
        requests = [
            c for t in turns for c in t.contents if isinstance(c, ContentToolRequest)
        ]
        assert content.request is None or any(content.request is r for r in requests)
        return {
            "type": "tool_result",
            "value": content.value,
            "request": None
            if content.request is None
            else {"id": content.request.id, "name": content.request.name},
        }
    raise AssertionError(f"unexpected content {type(content).__name__}")


def described_turns(turns: Sequence[Turn]) -> list[dict[str, Any]]:
    return [
        {"role": turn.role, "contents": [_descriptor(c, turns) for c in turn.contents]}
        for turn in turns
    ]


def described_provenance(exchanges: Sequence[Exchange]) -> list[dict[str, Any]]:
    return [
        {
            "tag": None if e.tag is None else str(e.tag),
            "decisions": [d.as_record() for d in e.decisions],
        }
        for e in exchanges
    ]


def _assert_exchanges_tile_turns(t: Trajectory) -> None:
    """The exchanges are the trajectory's own turns, from the first question on."""
    tiled = [turn for exchange in t.exchanges for turn in exchange.turns]
    tail = t.turns[len(t.turns) - len(tiled) :]
    assert all(a is b for a, b in zip(tiled, tail, strict=True))
    assert all(e.turns and e.turns[0].role == "user" for e in t.exchanges)


class _Notices(logging.Handler):
    def __init__(self, notices: list[str]) -> None:
        super().__init__(logging.DEBUG)
        self.notices = notices

    def emit(self, record: logging.LogRecord) -> None:
        self.notices.append("message")


def _instant(seconds: float | None) -> datetime | None:
    return None if seconds is None else datetime.fromtimestamp(seconds, UTC)


def run_case(
    member: dict[str, Any], case: dict[str, Any], directory: Path | None = None
) -> tuple[dict[str, Trajectory], list[str]]:
    spans: list[dict[str, Any]] = case.get("spans", member.get("spans")) or []
    notices: list[str] = []
    logger = logging.getLogger("commons._trajectory")
    level = logger.level
    handler = _Notices(notices)
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("always")
            # Record each warning as it is shown, in order with the log messages.
            warnings.showwarning = lambda *_args, **_kwargs: notices.append("warning")
            if directory is None:
                result = build_trajectories(parse_otlp_lines([fixture_line(spans)]))
            else:
                trace = directory / "trace-1.jsonl"
                trace.write_text(fixture_line(spans) + "\n", encoding="utf-8")
                result = trajectory_read(
                    directory,
                    n=case.get("n"),
                    since=_instant(case.get("since")),
                    until=_instant(case.get("until")),
                )
    finally:
        logger.removeHandler(handler)
        logger.setLevel(level)
    return result, notices


def assert_trajectories(
    result: dict[str, Trajectory], expected: list[dict[str, Any]]
) -> None:
    assert list(result) == [e["id"] for e in expected]
    for e in expected:
        t = result[e["id"]]
        _assert_exchanges_tile_turns(t)
        if "turns" in e:
            assert described_turns(t.turns) == e["turns"], e["id"]
        if "provenance" in e:
            assert described_provenance(t.exchanges) == e["provenance"], e["id"]
        if "user" in e:
            assert t.user == e["user"], e["id"]
        if "last_active" in e:
            assert t.last_active.timestamp() == e["last_active"], e["id"]
