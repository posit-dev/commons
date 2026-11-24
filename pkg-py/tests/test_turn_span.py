"""Test the span a logging agent opens around each turn.

A trace reader uses this span to find the spans of one turn and the user who
asked it. These tests check that chatlas's spans nest under it in both
``chat()`` and ``stream_async()``, that it records a user only from an
authenticated Shiny session, and that concurrent conversations do not share
it. They also check that a stream ends the span however the stream stops,
and never leaves it current between chunks, where another context could
detach it.
"""

from __future__ import annotations

import asyncio
import gc
import logging
from collections.abc import AsyncIterator
from types import SimpleNamespace
from typing import Any

import pytest
from chatlas import Chat
from chatlas.types import Content
from opentelemetry import trace

from commons._agent import Commons
from commons._tracing import TURN_SPAN, USER_ATTRIBUTE, trajectory_user

from ._agents import agent_over, collect, logging_agent_over, sales
from ._provider import ScriptedProvider, text
from ._shared import load_shared_fixture

TURN = load_shared_fixture("traces")["conversation_turn"]


@pytest.fixture
def source() -> Any:
    return sales()


def test_the_names_match_the_shared_contract() -> None:
    assert TURN_SPAN == TURN["span"]
    assert USER_ATTRIBUTE == TURN["user_attribute"]


def test_the_shared_user_cases_are_present() -> None:
    assert TURN["user_cases"]


def session_for(case: dict[str, Any]) -> Any:
    if case.get("session") is False:
        return None
    if not case.get("module"):
        return SimpleNamespace(user=case["session_user"])
    pytest.importorskip("shiny")
    from ._session import IdleSession

    root = IdleSession()
    root.user = case["session_user"]
    return root.make_scope("module")


@pytest.mark.parametrize("case", TURN["user_cases"], ids=lambda c: c["name"])
def test_the_user_comes_only_from_an_authenticated_session(case: Any) -> None:
    assert trajectory_user(session_for(case)) == case["recorded"]


def test_a_module_scope_of_the_current_session_has_its_user() -> None:
    pytest.importorskip("shiny")
    from shiny.session import session_context

    from ._session import IdleSession

    root = IdleSession()
    root.user = "alice"
    with session_context(root.make_scope("module")):
        assert trajectory_user() == "alice"


def test_outside_a_session_there_is_no_user() -> None:
    assert trajectory_user() is None


# ---- the span around a turn ------------------------------------------------


def context_errors(caplog: pytest.LogCaptureFixture) -> list[logging.LogRecord]:
    return [r for r in caplog.records if r.name.startswith("opentelemetry.context")]


async def test_a_turns_chat_spans_descend_from_the_turn_span(
    logging_agent: Commons, spans: Any
) -> None:
    await collect(logging_agent, "one")
    (turn,) = spans(TURN["span"])
    (invoke,) = spans("invoke_agent")
    assert turn.parent is None
    assert invoke.parent.span_id == turn.context.span_id
    assert dict(turn.attributes) == {}


async def test_each_turn_is_its_own_trace(logging_agent: Commons, spans: Any) -> None:
    await collect(logging_agent, "one")
    await collect(logging_agent, "two")
    assert len({s.context.trace_id for s in spans(TURN["span"])}) == 2


def test_a_synchronous_chat_is_a_turn_too(logging_agent: Commons, spans: Any) -> None:
    logging_agent.chat("one", echo="none")
    (turn,) = spans(TURN["span"])
    (invoke,) = spans("invoke_agent")
    assert invoke.parent.span_id == turn.context.span_id


async def test_an_agent_that_does_not_log_opens_no_turn_span(
    source: Any, spans: Any
) -> None:
    await collect(agent_over(source), "one")
    assert spans(TURN["span"]) == []


async def test_three_concurrent_conversations_stay_apart(
    source: Any, logging_live: Any
) -> None:
    agents = [logging_agent_over(source, conversation_id=f"c{i}") for i in range(3)]

    async def talk(agent: Commons) -> None:
        for prompt in ("one", "two"):
            async for _ in await agent.stream_async(prompt):
                await asyncio.sleep(0)  # let the other conversations run

    await asyncio.gather(*(talk(agent) for agent in agents))
    turn_traces = {s.context.trace_id for s in logging_live(TURN["span"])}
    by_conversation: dict[str, set[int]] = {}
    for span in logging_live("invoke_agent"):
        assert span.context.trace_id in turn_traces
        conversation = span.attributes[TURN["conversation_attribute"]]
        by_conversation.setdefault(conversation, set()).add(span.context.trace_id)
    assert set(by_conversation) == {agent.conversation_id for agent in agents}
    assert all(len(traces) == 2 for traces in by_conversation.values())
    assert sum(len(t) for t in by_conversation.values()) == len(turn_traces) == 6


async def test_walking_away_early_still_ends_the_turn_span(
    source: Any, logging_live: Any, caplog: pytest.LogCaptureFixture
) -> None:
    agent = logging_agent_over(source, [text("First. ", "Second.")])
    stream = await agent.stream_async("one")
    await anext(stream)
    await stream.aclose()
    assert len(logging_live(TURN["span"])) == 1
    assert context_errors(caplog) == []


async def test_the_turn_span_is_not_current_between_chunks(
    source: Any, logging_live: Any
) -> None:
    agent = logging_agent_over(source, [text("First. ", "Second.")])
    stream = await agent.stream_async("one")
    await anext(stream)
    assert not trace.get_current_span().get_span_context().is_valid
    await stream.aclose()


async def test_a_stream_dropped_without_closing_still_ends_the_turn_span(
    source: Any, logging_live: Any, caplog: pytest.LogCaptureFixture
) -> None:
    agent = logging_agent_over(source, [text("First. ", "Second.")])
    stream = await agent.stream_async("one")
    await anext(stream)
    # The event loop closes an abandoned generator from a task of its own.
    del stream
    gc.collect()
    for _ in range(5):
        await asyncio.sleep(0)
    assert len(logging_live(TURN["span"])) == 1
    assert context_errors(caplog) == []


class ProviderDown(Exception):
    pass


class DroppingProvider(ScriptedProvider):
    """Stream the first chunk of each response, then fail."""

    async def chat_perform_async(self, **kwargs: Any) -> AsyncIterator[Content]:  # type: ignore[override]
        chunks = await super().chat_perform_async(**kwargs)

        async def dropping() -> AsyncIterator[Content]:
            async for chunk in chunks:
                yield chunk
                raise ProviderDown("the connection dropped")

        return dropping()


async def test_a_provider_error_partway_still_ends_the_turn_span(
    source: Any, logging_live: Any, caplog: pytest.LogCaptureFixture
) -> None:
    client = Chat(provider=DroppingProvider([text("First. ", "Second.")]))
    agent = Commons(client, source, log=True)
    assert agent._tracing
    with pytest.raises(ProviderDown):
        await collect(agent, "one")
    assert len(logging_live(TURN["span"])) == 1
    assert context_errors(caplog) == []


async def test_the_session_user_is_recorded_when_the_turn_starts(
    logging_agent: Commons, spans: Any
) -> None:
    pytest.importorskip("shiny")
    from shiny.session import session_context

    from ._session import IdleSession

    session = IdleSession()
    session.user = "alice"
    with session_context(session):
        stream = await logging_agent.stream_async("one")
    async for _ in stream:  # pulled outside the session, as a chat UI does
        pass
    (turn,) = spans(TURN["span"])
    assert turn.attributes[TURN["user_attribute"]] == "alice"


def test_a_synchronous_chat_records_the_session_user(
    logging_agent: Commons, spans: Any
) -> None:
    pytest.importorskip("shiny")
    from shiny.session import session_context

    from ._session import IdleSession

    session = IdleSession()
    session.user = "alice"
    with session_context(session):
        logging_agent.chat("one", echo="none")
    (turn,) = spans(TURN["span"])
    assert turn.attributes[TURN["user_attribute"]] == "alice"
