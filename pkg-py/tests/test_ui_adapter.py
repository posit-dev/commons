"""The adapter a chat UI is handed, and the client protocol it satisfies."""

from typing import Any

import pandas as pd
import pytest
from chatlas import AssistantTurn, ContentToolRequest, StreamController, UserTurn
from chatlas.types import ContentText

from commons import data_source
from commons._agent import Commons
from commons._provenance import Tag, provenance_aside
from commons._ui import CommonsChatClient

from ._provider import scripted_chat, text


def agent(responses: Any = ()) -> Commons:
    source = data_source(sales=pd.DataFrame({"revenue": [500.0, 900.0]}))
    return Commons(scripted_chat(responses), source)


def queried(answer: str) -> list[Any]:
    """A turn that runs a tool, so its answer earns a provenance tag."""
    return [
        [
            ContentToolRequest(
                id="call-run_sql",
                name="run_sql",
                arguments={"sql": "SELECT count(*) AS n FROM sales"},
            )
        ],
        text(answer),
    ]


async def collect(client: CommonsChatClient, *args: Any, **kwargs: Any) -> list[Any]:
    return [chunk async for chunk in await client.stream_async(*args, **kwargs)]


async def test_the_stream_is_the_agents_so_the_marker_survives() -> None:
    """Streaming the composed chatlas client directly would lose the marker."""
    client = CommonsChatClient(agent(queried("Revenue was 1400.")))

    streamed = await collect(client, "How much?", content="all")

    assert "Revenue was 1400." in "".join(c for c in streamed if isinstance(c, str))
    assert streamed[-1] == provenance_aside(Tag.C)


async def test_stream_async_accepts_the_call_shinychat_makes() -> None:
    """`stream_async(input, *contents, content="all", controller=)`, verbatim."""
    client = CommonsChatClient(agent(queried("Three orders.")))

    streamed = await collect(
        client,
        "How many orders?",
        ContentText(text="an attached part"),
        content="all",
        controller=StreamController(),
    )

    kinds = [type(chunk).__name__ for chunk in streamed]
    assert "ContentToolRequest" in kinds
    assert streamed[-1] == provenance_aside(Tag.C)


def test_turn_and_tool_members_reach_the_agent() -> None:
    """What shinychat touches for history and tools lands on the agent."""
    subject = agent()
    client = CommonsChatClient(subject)

    assert client.get_turns() == subject.get_turns()
    assert client.get_tools() == subject.get_tools()
    assert client.system_prompt == subject.system_prompt


def test_set_turns_round_trips_through_the_agent() -> None:
    """A restore path sets turns and the agent sees them."""
    subject = agent()
    client = CommonsChatClient(subject)
    client.set_turns([])

    assert subject.get_turns() == []


def test_system_prompt_is_writable_for_a_client_swap() -> None:
    """`ChatClient._swap_client()` assigns this; the agent's own is read-only."""
    client = CommonsChatClient(agent())
    client.system_prompt = "Replaced."

    assert client.system_prompt == "Replaced."


def test_the_agent_is_reachable_from_the_client() -> None:
    """The server function needs the agent back to queue its reminders."""
    subject = agent()

    assert CommonsChatClient(subject).agent is subject


# ---- the conversation id ----------------------------------------------------


def test_conversation_id_is_visible_to_the_check_shinychat_makes() -> None:
    """`hasattr(client, "conversation_id")` gates shinychat's assignment."""
    client = CommonsChatClient(agent())

    assert hasattr(client, "conversation_id")


def test_conversation_id_assignment_reaches_the_composed_chat() -> None:
    """shinychat assigns; the id has to land where chatlas reads it."""
    subject = agent()
    client = CommonsChatClient(subject)

    client.conversation_id = "conv-1"

    assert client.conversation_id == "conv-1"
    assert subject.client.conversation_id == "conv-1"


def test_conversation_id_accepts_none() -> None:
    """A chat with no history controller assigns `None`."""
    client = CommonsChatClient(agent())
    client.conversation_id = None

    assert client.conversation_id is None


def test_conversation_id_rejects_a_non_string() -> None:
    """chatlas validates the type, and forwarding keeps that error."""
    client = CommonsChatClient(agent())

    with pytest.raises(TypeError, match="must be a string or None"):
        client.conversation_id = 7  # type: ignore[assignment]


# ---- bookmarking ------------------------------------------------------------


def test_the_adapter_satisfies_shinychats_own_protocols() -> None:
    """The two `isinstance` gates, checked against upstream's definitions."""
    pytest.importorskip("shinychat")
    from shinychat._chat_bookmark import ClientWithState
    from shinychat._history_client import ClientWithTurns

    client = CommonsChatClient(agent())

    assert isinstance(client, ClientWithTurns)
    assert isinstance(client, ClientWithState)


async def test_get_state_matches_the_chatlas_bookmark_payload() -> None:
    """A bookmark either object writes stays readable by the other."""
    subject = agent()
    subject.set_turns([UserTurn("How much?"), AssistantTurn("1400.")])
    client = CommonsChatClient(subject)

    state = await client.get_state()

    assert state["version"] == 1
    assert [turn["role"] for turn in state["turns"]] == ["user", "assistant"]


async def test_set_state_restores_the_turns() -> None:
    """Restore rebuilds chatlas turns from the saved payload."""
    saved = CommonsChatClient(agent())
    saved.set_turns([UserTurn("How much?"), AssistantTurn("1400.")])
    payload = await saved.get_state()

    restored = CommonsChatClient(agent())
    await restored.set_state(payload)

    assert [turn.role for turn in restored.get_turns()] == ["user", "assistant"]


async def test_set_state_rejects_an_unknown_version() -> None:
    """The same guard chatlas's own restore applies."""
    client = CommonsChatClient(agent())

    with pytest.raises(ValueError, match="version"):
        await client.set_state({"version": 2, "turns": []})


async def test_set_state_rejects_a_payload_that_is_not_a_mapping() -> None:
    client = CommonsChatClient(agent())

    with pytest.raises(ValueError):
        await client.set_state([])
