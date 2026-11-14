"""The span around each turn of a logging agent, and the conversation it belongs to."""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any

import pytest

from commons._agent import Commons
from commons._tracing import TURN_SPAN, USER_ATTRIBUTE, trajectory_user

from ._agents import agent_over, collect, logging_agent_over, sales
from ._shared import load_shared_fixture

TURN = load_shared_fixture("traces")["conversation_turn"]


@pytest.fixture
def source() -> Any:
    return sales()


def conversation_ids(spans: Any) -> set[str | None]:
    return {
        span.attributes.get(TURN["conversation_attribute"])
        for span in spans("invoke_agent")
    }


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


# ---- whose conversation a turn belongs to ----------------------------------


async def test_a_script_gets_one_id_for_all_its_turns(
    logging_agent: Commons, spans: Any
) -> None:
    await collect(logging_agent, "one")
    await collect(logging_agent, "two")
    ids = conversation_ids(spans)
    assert len(ids) == 1 and None not in ids


async def test_an_id_the_caller_chose_is_kept(source: Any, logging_live: Any) -> None:
    agent = logging_agent_over(source, conversation_id="mine")
    await collect(agent, "one")
    assert agent.conversation_id == "mine"
    assert conversation_ids(logging_live) == {"mine"}


async def test_a_host_that_assigns_an_id_owns_it(logging_agent: Commons) -> None:
    logging_agent.conversation_id = "from-the-host"
    await collect(logging_agent, "one")
    assert logging_agent.conversation_id == "from-the-host"


async def test_a_host_that_clears_the_id_each_turn_still_gets_one_conversation(
    logging_agent: Commons, spans: Any
) -> None:
    # shinychat without a history controller assigns None before every turn.
    for prompt in ("one", "two"):
        logging_agent.conversation_id = None
        await collect(logging_agent, prompt)
    ids = conversation_ids(spans)
    assert len(ids) == 1 and None not in ids


async def test_clearing_the_turns_starts_a_new_conversation(
    logging_agent: Commons,
) -> None:
    await collect(logging_agent, "one")
    first = logging_agent.conversation_id
    logging_agent.set_turns([])
    await collect(logging_agent, "two")
    assert logging_agent.conversation_id not in (None, first)


async def test_clearing_the_turns_keeps_an_id_the_caller_chose(
    source: Any, logging_live: Any
) -> None:
    agent = logging_agent_over(source, conversation_id="mine")
    await collect(agent, "one")
    agent.set_turns([])
    await collect(agent, "two")
    assert conversation_ids(logging_live) == {"mine"}


def test_a_synchronous_chat_gets_an_id_too(logging_agent: Commons, spans: Any) -> None:
    logging_agent.chat("one", echo="none")
    logging_agent.chat("two", echo="none")
    ids = conversation_ids(spans)
    assert len(ids) == 1 and None not in ids


async def test_an_agent_that_does_not_log_leaves_the_id_alone(source: Any) -> None:
    agent = agent_over(source)
    await collect(agent, "one")
    assert agent.conversation_id is None
