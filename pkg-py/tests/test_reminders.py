"""Reminders appended to a user turn, driven by the shared fixture.

Which models earn the concise reminder, and the wording of both reminders, are
cross-language contracts, so the cases live in ``tests/shared/turn-reminders.json``
and the R suite runs the same ones. Do not restate a case here; add it to the
fixture.
"""

from typing import Any

import pytest
from chatlas.types import ContentText

from commons._reminders import (
    CLAUDE_5_TURN_REMINDER,
    RESTORED_CONVERSATION_REMINDER,
    ContentTurnReminder,
    append_restored_conversation_reminder,
    append_turn_reminder,
)

from ._shared import load_shared_fixture

SPEC = load_shared_fixture("turn-reminders")
CONCISE: dict[str, Any] = SPEC["claude_5_turn_reminder"]
RESTORED: dict[str, Any] = SPEC["restored_conversation_reminder"]


def test_the_fixture_covers_models_that_do_and_do_not_earn_the_reminder() -> None:
    assert {case["appended"] for case in CONCISE["cases"]} == {True, False}


@pytest.mark.parametrize("case", CONCISE["cases"], ids=lambda case: case["name"])
def test_the_concise_reminder_follows_the_shared_fixture(case: dict[str, Any]) -> None:
    inputs = append_turn_reminder(["What was revenue?"], case["model"])

    if not case["appended"]:
        assert inputs == ["What was revenue?"]
        return
    assert len(inputs) == 2
    assert isinstance(inputs[1], ContentTurnReminder)
    assert inputs[1].text == CONCISE["text"]


def test_the_concise_reminder_text_matches_the_shared_fixture() -> None:
    assert CLAUDE_5_TURN_REMINDER == CONCISE["text"]


def test_the_restored_reminder_renders_the_shared_wording() -> None:
    expected = RESTORED["template"].format(**RESTORED["substitutions"]["python"])

    assert RESTORED_CONVERSATION_REMINDER == expected


def test_the_restored_reminder_is_appended_after_the_prompt() -> None:
    inputs = append_restored_conversation_reminder(["What was revenue?"])

    assert len(inputs) == 2
    assert inputs[0] == "What was revenue?"
    assert isinstance(inputs[1], ContentTurnReminder)
    assert inputs[1].text == RESTORED_CONVERSATION_REMINDER


def test_appending_leaves_the_caller_s_inputs_alone() -> None:
    # The caller's list is the turn's own contents; appending in place would
    # add a second reminder on every retry of that turn.
    inputs: list[Any] = ["What was revenue?"]

    append_turn_reminder(inputs, "claude-sonnet-5")
    append_restored_conversation_reminder(inputs)

    assert inputs == ["What was revenue?"]


def test_a_reminder_is_text_the_model_reads() -> None:
    # Providers only accept content they know, so the reminder has to be a
    # kind of text; being its own type is what lets a UI leave it out.
    reminder = ContentTurnReminder(text=CLAUDE_5_TURN_REMINDER)

    assert isinstance(reminder, ContentText)
    assert reminder.content_type == "text"
