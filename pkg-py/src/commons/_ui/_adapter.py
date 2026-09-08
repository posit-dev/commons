"""The object a chat UI is handed in place of the agent.

`Commons` composes a `chatlas.Chat` (D1), so it is not one, and shinychat
hands its `client=` to code that expects chatlas's surface. This adapter is
that surface. The R package inherits from `ellmer::Chat` and needs no
equivalent; the Python side accepts the divergence and pays for it here.
"""

from __future__ import annotations

from collections.abc import Callable, Sequence
from typing import TYPE_CHECKING, Any, Literal

if TYPE_CHECKING:
    from collections.abc import AsyncGenerator

    from chatlas import StreamController, Tool, ToolBuiltIn, Turn
    from chatlas.types import Content, SubmitInputArgsT

    from .._agent import Commons

__all__ = ["CommonsChatClient"]


class CommonsChatClient:
    """A `Commons` agent behind the client surface a chat UI drives.

    Only `stream_async()` is the agent's own: the citation scanner and the
    provenance tag live in the agent, so a UI that streamed the composed
    chatlas client directly would render an answer with no marker.
    """

    def __init__(self, agent: Commons) -> None:
        self._agent = agent

    def __repr__(self) -> str:
        return f"A chat client over {self._agent!r}"

    @property
    def agent(self) -> Commons:
        """The agent this client speaks for."""
        return self._agent

    # ---- the one that must not forward ------------------------------------

    async def stream_async(
        self,
        *args: Content | str,
        content: Literal["text", "all"] = "text",
        echo: Literal["output", "all", "none", "text"] = "none",
        kwargs: SubmitInputArgsT | None = None,
        controller: StreamController | None = None,
    ) -> AsyncGenerator[str | Content, None]:
        """The agent's stream, scanner and provenance marker included."""
        return await self._agent.stream_async(
            *args, content=content, echo=echo, kwargs=kwargs, controller=controller
        )

    # ---- turns: history, restore, and client swaps ------------------------

    def get_turns(self, *, include_system_prompt: bool = False) -> list[Turn]:
        return self._agent.get_turns(include_system_prompt=include_system_prompt)

    def set_turns(self, turns: Sequence[Turn]) -> None:
        self._agent.set_turns(turns)

    def add_turn(self, turn: Turn) -> None:
        self._agent.add_turn(turn)

    # ---- tools and prompt -------------------------------------------------

    def get_tools(self) -> list[Tool | ToolBuiltIn]:
        return self._agent.get_tools()

    def set_tools(self, tools: Sequence[Tool | Callable[..., Any]]) -> None:
        self._agent.client.set_tools(tools)  # type: ignore[arg-type]

    def register_tool(self, *args: Any, **kwargs: Any) -> None:
        self._agent.client.register_tool(*args, **kwargs)

    @property
    def system_prompt(self) -> str | None:
        return self._agent.system_prompt

    @system_prompt.setter
    def system_prompt(self, value: str | None) -> None:
        # Writable where the agent's is not: a client swap assigns the old
        # prompt onto the new client, and refusing would abort the swap.
        self._agent.client.system_prompt = value

    # ---- conversation identity --------------------------------------------

    @property
    def conversation_id(self) -> str | None:
        return self._agent.client.conversation_id

    @conversation_id.setter
    def conversation_id(self, value: str | None) -> None:
        # The property this adapter exists for. shinychat assigns the id it
        # allocated only to an object that already has the attribute, and
        # skips it in silence otherwise, which leaves the id unset and every
        # turn reading as its own conversation.
        self._agent.client.conversation_id = value
