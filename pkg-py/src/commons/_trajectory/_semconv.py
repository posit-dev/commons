"""Rebuild chatlas turns from the GenAI semantic-convention message attributes.

chatlas' ``as_otel_message()`` writes these attributes on a chat span;
``pkg-r/R/trajectory-read.R`` is the R counterpart.
"""

import json
from typing import Any

from chatlas import AssistantTurn, SystemTurn, Turn, UserTurn
from chatlas.types import (
    Content,
    ContentText,
    ContentToolRequest,
    ContentToolResult,
)

from ._otlp import Span

SYSTEM_INSTRUCTIONS = "gen_ai.system_instructions"
INPUT_MESSAGES = "gen_ai.input.messages"
OUTPUT_MESSAGES = "gen_ai.output.messages"


def trajectory_turns(span: Span) -> list[Turn]:
    """The turns a chat span recorded: system instructions, input, then output."""
    attributes = span.attributes
    requests: dict[str, ContentToolRequest] = {}
    return [
        *_system_turns(attributes.get(SYSTEM_INSTRUCTIONS)),
        *_message_turns(attributes.get(INPUT_MESSAGES), requests),
        *_message_turns(attributes.get(OUTPUT_MESSAGES), requests),
    ]


def _parse(text: object) -> list[Any] | None:
    """The JSON list in an attribute; None when absent, empty, or not a list."""
    if not isinstance(text, str) or not text:
        return None
    try:
        parsed = json.loads(text)
    except (ValueError, RecursionError):
        return None
    return parsed if isinstance(parsed, list) else None


def _system_turns(text: object) -> list[Turn]:
    parts = _parse(text)
    if parts is None:
        return []
    # System instructions take no part in linking, so each part gets an empty
    # registry: no response here or later is linked to a tool call here.
    contents = [c for part in parts if (c := _part_content(part, {})) is not None]
    return [SystemTurn(contents)] if contents else []


def _message_turns(text: object, requests: dict[str, ContentToolRequest]) -> list[Turn]:
    messages = _parse(text)
    if messages is None:
        return []
    turns = (_turn(message, requests) for message in messages)
    return [turn for turn in turns if turn is not None]


def _contents(
    parts: list[Any], requests: dict[str, ContentToolRequest]
) -> list[Content]:
    contents = (_part_content(part, requests) for part in parts)
    return [content for content in contents if content is not None]


def _turn(message: object, requests: dict[str, ContentToolRequest]) -> Turn | None:
    if not isinstance(message, dict):
        return None
    parts = message.get("parts")
    contents = _contents(parts, requests) if isinstance(parts, list) else []
    if not contents:
        return None
    role = message.get("role")
    if role == "assistant":
        return AssistantTurn(contents)
    # A tool-result message is recorded with role "tool" and becomes a user
    # turn, as chatlas represents it.
    if role in ("user", "tool"):
        return UserTurn(contents)
    if role == "system":
        return SystemTurn(contents)
    return None


def _part_content(
    part: object, requests: dict[str, ContentToolRequest]
) -> Content | None:
    if not isinstance(part, dict):
        return None
    if part.get("type") == "text":
        content = part.get("content")
        return ContentText(text=_text(content))
    if part.get("type") == "tool_call":
        return _tool_request(part, requests)
    if part.get("type") == "tool_call_response":
        return _tool_result(part, requests)
    return None


def _tool_request(
    part: dict[str, Any], requests: dict[str, ContentToolRequest]
) -> ContentToolRequest:
    arguments = part.get("arguments")
    request = ContentToolRequest(
        id=_text(part.get("id")),
        name=_text(part.get("name")),
        arguments={} if arguments is None else arguments,
    )
    if request.id:
        requests[request.id] = request
    return request


def _tool_result(
    part: dict[str, Any], requests: dict[str, ContentToolRequest]
) -> ContentToolResult:
    request = None if part.get("id") is None else requests.get(str(part["id"]))
    return ContentToolResult(value=part.get("response"), request=request)


def _text(value: object) -> str:
    return "" if value is None else str(value)
