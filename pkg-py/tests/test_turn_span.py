"""The span around each turn of a logging agent, and the conversation it belongs to."""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any

import pytest

from commons._tracing import TURN_SPAN, USER_ATTRIBUTE, trajectory_user

from ._shared import load_shared_fixture

TURN = load_shared_fixture("traces")["conversation_turn"]


def test_the_names_match_the_shared_contract() -> None:
    assert TURN_SPAN == TURN["span"]
    assert USER_ATTRIBUTE == TURN["user_attribute"]


@pytest.mark.parametrize("case", TURN["user_cases"], ids=lambda c: c["name"])
def test_the_user_comes_only_from_an_authenticated_session(case: Any) -> None:
    session = (
        None
        if case.get("session") is False
        else SimpleNamespace(user=case["session_user"])
    )
    assert trajectory_user(session) == case["recorded"]


def test_outside_a_session_there_is_no_user() -> None:
    assert trajectory_user() is None
