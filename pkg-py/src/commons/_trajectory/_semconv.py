"""Rebuild chatlas turns from the GenAI semantic-convention message attributes.

chatlas' ``as_otel_message()`` writes these attributes on a chat span;
``pkg-r/R/trajectory-read.R`` holds the R counterpart.
"""

import json
from typing import Any

from chatlas import AssistantTurn, SystemTurn, Turn, UserTurn
from chatlas.types import Content, ContentText

from ._otlp import Span

SYSTEM_INSTRUCTIONS = "gen_ai.system_instructions"
INPUT_MESSAGES = "gen_ai.input.messages"
OUTPUT_MESSAGES = "gen_ai.output.messages"


def trajectory_turns(span: Span) -> list[Turn]:
    """The turns a chat span recorded: system instructions, input, then output."""
    attributes = span.attributes
    return [
        *_system_turns(attributes.get(SYSTEM_INSTRUCTIONS)),
        *_message_turns(attributes.get(INPUT_MESSAGES)),
        *_message_turns(attributes.get(OUTPUT_MESSAGES)),
    ]


def _parse(text: object) -> list[Any] | None:
    """The JSON list in an attribute; None when absent, empty, or not a list."""
    if not isinstance(text, str) or not text:
        return None
    try:
        parsed = json.loads(text)
    except ValueError:
        return None
    return parsed if isinstance(parsed, list) else None


def _system_turns(text: object) -> list[Turn]:
    parts = _parse(text)
    if parts is None:
        return []
    contents = _contents(parts)
    return [SystemTurn(contents)] if contents else []


def _message_turns(text: object) -> list[Turn]:
    messages = _parse(text)
    if messages is None:
        return []
    turns = (_turn(message) for message in messages)
    return [turn for turn in turns if turn is not None]


def _contents(parts: list[Any]) -> list[Content]:
    contents = (_part_content(part) for part in parts)
    return [content for content in contents if content is not None]


def _turn(message: object) -> Turn | None:
    if not isinstance(message, dict):
        return None
    parts = message.get("parts")
    contents = _contents(parts) if isinstance(parts, list) else []
    if not contents:
        return None
    role = message.get("role")
    if role == "assistant":
        return AssistantTurn(contents)
    if role == "user":
        return UserTurn(contents)
    if role == "system":
        return SystemTurn(contents)
    return None


def _part_content(part: object) -> Content | None:
    if not isinstance(part, dict):
        return None
    if part.get("type") == "text":
        content = part.get("content")
        return ContentText(text="" if content is None else str(content))
    return None
