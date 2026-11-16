"""Tests for decoding recorded GenAI messages into chatlas turns.

The cases live in ``tests/shared/trajectories/semconv.json``, and the R suite
runs the same cases, so a case belongs in the fixture rather than here. This
module adds only what the fixture cannot pin.
"""

import json
from typing import Any

import pytest
from chatlas import AssistantTurn, SystemTurn, Turn, UserTurn
from chatlas.types import ContentText

from commons._trajectory._otlp import Span, parse_otlp_lines
from commons._trajectory._semconv import trajectory_turns
from tests._shared import load_shared_fixture

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
