"""Tests for decoding recorded GenAI messages into chatlas turns.

The cases live in ``tests/shared/trajectories/semconv.json``, and the R suite
runs the same cases, so a case belongs in the fixture rather than here. This
module adds only what the fixture cannot pin.
"""

import json
from typing import Any

import pytest
from chatlas import AssistantTurn, SystemTurn, Turn, UserTurn
from chatlas.types import ContentText, ContentToolRequest, ContentToolResult

from commons._trajectory._otlp import Span, parse_otlp_lines, read_local_spans
from commons._trajectory._semconv import trajectory_turns
from tests._shared import SHARED_DIR, load_shared_fixture

SEMCONV = load_shared_fixture("trajectories/semconv")


def _span(attributes: dict[str, Any]) -> Span:
    encoded = [
        {
            "key": key,
            "value": {"stringValue": v if isinstance(v, str) else json.dumps(v)},
        }
        for key, v in attributes.items()
    ]
    envelope = {
        "resourceSpans": [
            {
                "scopeSpans": [
                    {
                        "spans": [
                            {
                                "traceId": "t1",
                                "spanId": "s1",
                                "name": "chat",
                                "attributes": encoded,
                            }
                        ]
                    }
                ]
            }
        ]
    }
    (span,) = parse_otlp_lines([json.dumps(envelope)])
    return span


def _descriptor(content: object, turns: list[Turn]) -> dict[str, Any]:
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


def _described(turns: list[Turn]) -> list[dict[str, Any]]:
    return [
        {"role": turn.role, "contents": [_descriptor(c, turns) for c in turn.contents]}
        for turn in turns
    ]


def test_the_fixture_has_cases() -> None:
    assert SEMCONV["turns"]["cases"]
    assert SEMCONV["dropped"]["cases"]


@pytest.mark.parametrize(
    "case",
    SEMCONV["turns"]["cases"] + SEMCONV["dropped"]["cases"],
    ids=lambda case: case["name"],
)
def test_messages_decode_as_the_shared_fixture_pins(case: dict[str, Any]) -> None:
    assert _described(trajectory_turns(_span(case["attributes"]))) == case["turns"]


def test_each_role_decodes_to_its_chatlas_turn_class() -> None:
    turns = trajectory_turns(
        _span(
            {
                "gen_ai.system_instructions": [{"type": "text", "content": "S"}],
                "gen_ai.input.messages": [
                    {"role": "user", "parts": [{"type": "text", "content": "U"}]}
                ],
                "gen_ai.output.messages": [
                    {"role": "assistant", "parts": [{"type": "text", "content": "A"}]}
                ],
            }
        )
    )
    assert [type(turn) for turn in turns] == [SystemTurn, UserTurn, AssistantTurn]


TRACE = SHARED_DIR / "traces" / "python"
EXPECTED = json.loads((TRACE / "expected.json").read_text(encoding="utf-8"))


def test_the_committed_python_trace_decodes_to_the_expected_roles(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("OTEL_EXPORTER_OTLP_TRACES_FILE", raising=False)
    chats: dict[str, list[Span]] = {}
    for span in read_local_spans(TRACE):
        if span.attributes.get("gen_ai.operation.name") == "chat":
            chats.setdefault(span.attributes["gen_ai.conversation.id"], []).append(span)

    assert len(chats) == len(EXPECTED["conversations"])
    for spans, expected in zip(chats.values(), EXPECTED["conversations"], strict=True):
        roles = expected["roles"]
        for span in spans:
            decoded = [turn.role for turn in trajectory_turns(span)]
            assert decoded == roles[: len(decoded)]
        latest = max(spans, key=lambda span: span.end_time_unix_nano)
        turns = trajectory_turns(latest)
        assert [turn.role for turn in turns] == roles
        requests = [
            c for t in turns for c in t.contents if isinstance(c, ContentToolRequest)
        ]
        results = [
            c for t in turns for c in t.contents if isinstance(c, ContentToolResult)
        ]
        if expected["tool"] is None:
            assert requests == [] and results == []
        else:
            (request,) = requests
            (result,) = results
            assert request.name == expected["tool"]["name"]
            assert (result.request is request) == expected["tool"]["linked"]
