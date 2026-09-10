"""An agent as a chat client, driven through shinychat's own code paths.

shinychat gates on `isinstance(client, chatlas.Chat)` in several places
rather than duck-typing what it is handed, so these run upstream's real
functions over an agent instead of asserting on a described contract.
Driving a whole `shinychat.Chat` needs an active Shiny session, which is
what the end-to-end acceptance task covers.
"""

from typing import Any

import pandas as pd
import pytest
from chatlas import (
    AssistantTurn,
    ContentToolRequest,
    ContentToolResult,
    StreamController,
    UserTurn,
)
from chatlas.types import ContentText

from commons import data_source
from commons._agent import Commons
from commons._provenance import Tag, provenance_aside

from ._provider import scripted_chat, text

pytest.importorskip("shinychat")


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


def answered() -> Commons:
    subject = agent()
    subject.set_turns([UserTurn("How much revenue?"), AssistantTurn("1400.")])
    return subject


def test_shinychat_takes_the_agent_for_a_chatlas_client() -> None:
    """The type check that gates bookmarking and the history drawer."""
    from shinychat._chat_bookmark import is_chatlas_chat_client

    assert is_chatlas_chat_client(agent())


async def test_the_stream_shinychat_drives_carries_the_marker() -> None:
    """`stream_async(input, *contents, content="all", controller=)`, verbatim."""
    subject = agent(queried("Three orders."))

    stream = await subject.stream_async(
        "How many orders?",
        ContentText(text="an attached part"),
        content="all",
        controller=StreamController(),
    )
    streamed = [chunk async for chunk in stream]

    assert "ContentToolRequest" in [type(chunk).__name__ for chunk in streamed]
    assert "Three orders." in "".join(c for c in streamed if isinstance(c, str))
    assert streamed[-1] == provenance_aside(Tag.C)


def test_the_history_drawer_serializes_and_titles_the_agents_turns() -> None:
    """`history=True` is shinychat's default, so this runs in any app."""
    from shinychat._history_client import as_turns_adapter
    from shinychat._history_title import fallback_title

    adapter = as_turns_adapter(answered())

    turns = adapter.get_turns_json()

    assert [turn.get("role") for turn in turns] == ["user", "assistant"]
    assert fallback_title(turns) == "How much revenue?"


def test_a_saved_conversation_records_the_provider_and_the_model() -> None:
    """`client_info()` returns `{}` for anything that is not a chatlas chat."""
    from shinychat._history_client import as_turns_adapter

    info = as_turns_adapter(answered()).client_info()

    assert info["provider"] == "scripted"
    assert info["model"] == answered().model


def test_a_client_swap_moves_turn_objects_between_clients() -> None:
    """`ChatClient` adds `get_turns()` to turns it built, so these are turns."""
    from shinychat._chat_client import messages_to_turns

    subject = answered()

    moved = subject.get_turns() + messages_to_turns(
        [{"role": "user", "content": "And by region?"}]
    )
    subject.set_turns(moved)

    assert [turn.role for turn in subject.get_turns()] == [
        "user",
        "assistant",
        "user",
    ]


async def test_a_bookmark_round_trips_through_shinychats_chatlas_hooks() -> None:
    """chatlas has no state methods; shinychat builds them for a chat."""
    from shinychat._chat_bookmark import get_chatlas_state, set_chatlas_state

    saved: Any = await get_chatlas_state(answered())()
    assert saved["version"] == 1

    restored = agent()
    await set_chatlas_state(restored)(saved)

    assert [turn.role for turn in restored.get_turns()] == ["user", "assistant"]


async def test_an_htmltools_tool_result_survives_a_bookmark() -> None:
    """A tool result can carry an htmltools object pydantic cannot dump.

    shinychat's own serializer renders it to HTML and lists the dependencies
    it needs, which is the shape a restored bookmark can put back on the
    page. Inheriting is what routes an agent through that serializer.
    """
    import htmltools
    from shinychat._chat_bookmark import get_chatlas_state

    request = ContentToolRequest(id="call-measure", name="measure", arguments={})
    result = ContentToolResult(
        id="call-measure", value=htmltools.div("1400."), request=request
    )
    subject = agent()
    subject.set_turns([UserTurn("How much?"), AssistantTurn([result])])

    saved: Any = await get_chatlas_state(subject)()

    assert saved["turns"][1]["contents"][0]["value"] == {
        "html": "<div>1400.</div>",
        "dependencies": [],
    }


async def test_a_generated_title_degrades_to_the_excerpt() -> None:
    """The one shinychat path an agent cannot serve.

    shinychat titles a conversation by deep-copying the client and asking it
    a one-shot question. An agent holds database connections that cannot be
    copied, and it has no `chat_async()` to ask through, so the drawer keeps
    the excerpt title `fallback_title()` derived. An app that wants a
    generated title passes shinychat a `title_fn`.
    """
    from shinychat._history_client import as_turns_adapter
    from shinychat._history_title import generate_title

    subject = answered()
    turns = as_turns_adapter(subject).get_turns_json()

    with pytest.warns(UserWarning, match="title generation failed"):
        assert await generate_title(None, subject, turns) is None
