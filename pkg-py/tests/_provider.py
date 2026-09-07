"""A chatlas provider that replays a script, so the real chat loop runs offline.

Every part of chatlas an agent leans on is real here: the tool loop, the turns
it appends, the streamed chunk types, and the controller a stop button cancels
through. Only the network call is scripted, which is what lets a test assert
on what the agent does with a model's answer without having a model.
"""

from __future__ import annotations

from collections.abc import AsyncIterator, Iterable, Sequence
from typing import Any

from chatlas import Chat, Turn
from chatlas._provider import Provider
from chatlas._turn import AssistantTurn
from chatlas.types import Content, ContentText, ModelInfo


class ScriptedProvider(Provider):
    """Answer each request with the next scripted list of content chunks."""

    def __init__(
        self,
        responses: Iterable[Sequence[Content]] = (),
        model: str = "claude-sonnet-4-5",
    ) -> None:
        super().__init__(name="scripted", model=model)
        self.responses = [list(response) for response in responses]
        self.requests: list[list[Turn]] = []

    def _next_response(self) -> list[Content]:
        if self.responses:
            return self.responses.pop(0)
        return [ContentText(text="Nothing more to say.")]

    async def chat_perform_async(  # type: ignore[override]
        self,
        *,
        stream: bool,
        turns: list[Turn],
        tools: Any,
        data_model: Any,
        kwargs: Any,
    ) -> AsyncIterator[Content]:
        self.requests.append(list(turns))
        response = self._next_response()

        async def chunks() -> AsyncIterator[Content]:
            for chunk in response:
                yield chunk

        return chunks()

    def chat_perform(  # type: ignore[override]
        self,
        *,
        stream: bool,
        turns: list[Turn],
        tools: Any,
        data_model: Any,
        kwargs: Any,
    ) -> Iterable[Content]:
        self.requests.append(list(turns))
        return self._next_response()

    # A chunk is already the content it stands for, so merging is collecting.
    def stream_merge_chunks(self, completion: Any, chunk: Any) -> list[Content]:
        return [*(completion or []), chunk]

    def stream_content(
        self, chunk: Any, completion: Any, turns: Sequence[Turn] = ()
    ) -> Sequence[Content]:
        return [chunk]

    def stream_turn(
        self, completion: Any, has_data_model: bool, turns: Sequence[Turn] = ()
    ) -> AssistantTurn[Any]:
        return AssistantTurn(list(completion or []))

    def value_turn(
        self, completion: Any, has_data_model: bool, turns: Sequence[Turn] = ()
    ) -> AssistantTurn[Any]:
        return AssistantTurn(list(completion or []))

    def value_tokens(self, completion: Any) -> tuple[int, int, int] | None:
        return None

    def token_count(self, turns: list[Turn], *, tools: Any, data_model: Any) -> int:
        return 0

    async def token_count_async(
        self, turns: list[Turn], *, tools: Any, data_model: Any
    ) -> int:
        return 0

    def translate_model_params(self, params: Any) -> Any:
        return {}

    def supported_model_params(self) -> set[Any]:
        return set()

    def list_models(self) -> list[ModelInfo]:
        return []


def scripted_chat(
    responses: Iterable[Sequence[Content]] = (),
    model: str = "claude-sonnet-4-5",
) -> Chat:
    """A real `chatlas.Chat` whose provider replays `responses`."""
    return Chat(provider=ScriptedProvider(responses, model=model))


def text(*chunks: str) -> list[Content]:
    """One scripted response streaming `chunks` as separate text pieces."""
    return [ContentText(text=chunk) for chunk in chunks]


async def collect(stream: AsyncIterator[Any]) -> list[Any]:
    return [chunk async for chunk in stream]
