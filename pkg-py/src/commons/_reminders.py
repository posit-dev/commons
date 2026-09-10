"""Reminders appended to a user's turn.

The wording and which models earn the concise reminder are a cross-language
contract pinned by ``tests/shared/turn-reminders.json``; change that fixture,
not just this file. ``pkg-r/R/turn-reminder.R`` holds the same contract for R.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any, Final

from chatlas.types import ContentText

from ._prompt import is_claude_5_model

__all__ = [
    "CLAUDE_5_TURN_REMINDER",
    "RESTORED_CONVERSATION_REMINDER",
    "ContentTurnReminder",
    "append_restored_conversation_reminder",
    "append_turn_reminder",
]


class ContentTurnReminder(ContentText):
    """Text the model reads and the UI leaves out.

    A provider only accepts content it knows, so a reminder travels as text;
    its own type is what lets a UI recognize and skip it.
    """


CLAUDE_5_TURN_REMINDER: Final = "<reminder>Be concise as a default.</reminder>"

RESTORED_CONVERSATION_REMINDER: Final = (
    "<reminder>The Python state associated with this restored conversation is "
    "unavailable. Do not assume that objects, loaded packages, or result "
    "handles from earlier run_python calls still exist. Re-run needed tools, "
    "recreate objects, and reload packages before continuing.</reminder>"
)


def append_turn_reminder(inputs: Sequence[Any], model: str | None) -> list[Any]:
    """Add the concise reminder for the models that need it."""
    if not is_claude_5_model(model):
        return list(inputs)
    return [*inputs, ContentTurnReminder(text=CLAUDE_5_TURN_REMINDER)]


def append_restored_conversation_reminder(inputs: Sequence[Any]) -> list[Any]:
    """Tell the model that the session behind its earlier results is gone."""
    return [*inputs, ContentTurnReminder(text=RESTORED_CONVERSATION_REMINDER)]
