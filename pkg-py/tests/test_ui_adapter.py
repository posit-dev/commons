"""The adapter a chat UI is handed, and the client protocol it satisfies."""

from typing import Any

import pandas as pd
from chatlas import ContentToolRequest, StreamController
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
