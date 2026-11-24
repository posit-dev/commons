"""Build test agents over a sample sales table, and collect what they stream.

The agents answer from a scripted model instead of a live one, so each test
chooses the model's responses. ``collect()`` runs one ``stream_async()`` turn
and returns every chunk the agent yields.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from typing import Any

import pandas as pd
from chatlas.types import Content

from commons import data_source
from commons._agent import Commons

from ._provider import scripted_chat


def frame() -> pd.DataFrame:
    return pd.DataFrame(
        {"revenue": [500.0, 900.0, 300.0], "region": ["EMEA", "Americas", "EMEA"]}
    )


def sales() -> Any:
    return data_source(sales=frame())


async def collect(agent: Commons, *args: Any, **kwargs: Any) -> list[Any]:
    return [chunk async for chunk in await agent.stream_async(*args, **kwargs)]


def agent_over(source: Any, responses: Iterable[Sequence[Content]] = ()) -> Commons:
    return Commons(scripted_chat(responses), source)


def logging_agent_over(
    source: Any,
    responses: Iterable[Sequence[Content]] = (),
    *,
    conversation_id: str | None = None,
    **options: Any,
) -> Commons:
    """An agent with trajectory logging live.

    Needs a recording provider and message capture on, which the
    `logging_agent` fixture sets up.
    """
    client = scripted_chat(responses)
    client.conversation_id = conversation_id
    agent = Commons(client, source, log=True, **options)
    assert agent._tracing, "trajectory logging is not live"
    return agent
