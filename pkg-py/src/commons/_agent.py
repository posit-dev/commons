"""The agent: its layers, the tools they earn, and the rules a turn follows.

`pkg-r/R/commons.R` assembles the same agent for R, in the order this follows.
A `chatlas.Chat` is composed rather than subclassed (decision D1 in the port
plan), so the public surface is a choice R never had to make: what an agent
needs, plus the chatlas methods the two turn rules have to hook.
"""

from __future__ import annotations

import warnings
from collections.abc import AsyncGenerator, Mapping, Sequence
from typing import Any, Literal

from chatlas import Chat, StreamController, Tool, Turn, UserTurn
from chatlas.types import ChatResponse, Content, SubmitInputArgsT

from ._backends import DuckDBBackend, EngineBackend
from ._citation_scan import CitationScanner
from ._citations import (
    CitationRequest,
    CorpusEntry,
    build_citation_corpus,
    turn_has_user_message,
)
from ._context_layer import ContextLayer, augment_context_layer
from ._data_source import DataSource
from ._definitions import Registry, build_registry
from ._handles import HandleStore
from ._measures import SemanticLayer, resolve_injections, semantic_layer
from ._prompt import (
    check_instructions,
    read_instructions,
    render_system_prompt,
    system_prompt_data,
    system_prompt_template,
)
from ._provenance import collect_appended_tags, derive_provenance_tag, provenance_aside
from ._reminders import append_restored_conversation_reminder, append_turn_reminder
from ._tools import FirstTouch, ToolContext, build_commons_tools

__all__ = ["Commons"]

EchoOptions = Literal["output", "all", "none", "text"]

# The label a lone source is filed under. An agent with one source never shows
# the model a `source` argument and never labels its prompt sections, so this
# is only what the agent's own bookkeeping keys on.
SOLE_SOURCE = "data"

# Frozen and empty, so every agent built without a semantic layer can share it.
_NO_MEASURES = semantic_layer()


class Commons:
    """An agent that answers questions about its data.

    Give it a `chatlas.Chat` for the provider and model, the data sources it
    can query, and optionally a semantic layer of trusted calculations and a
    context layer of prose. It registers the tools its composition earns and
    sets its own system prompt, so an answer can be classified by how it was
    produced.

    The provider and the model come from `client`; the agent builds its own
    chat from them, so nothing it does reaches an object the caller still
    holds, and nothing already on that object reaches the agent. A system
    prompt set on it is ignored with a warning; use `instructions` to add to
    commons' prompt instead.

    Parameters
    ----------
    client
        A `chatlas.Chat` giving the provider and model to use. For best
        results, enable thinking where the provider and model support it.
    data_sources
        A `DataSource`, or a mapping of name to `DataSource`. A measure can
        take a named source's connection as an argument named after it.
    semantic_layer
        An optional `SemanticLayer` of measures.
    context_layer
        An optional `ContextLayer` of prose.
    instructions
        Extra instructions placed under an `## Additional instructions`
        heading at the end of commons' built-in system prompt, as a string or
        the path to a text or Markdown file.
    """

    def __init__(
        self,
        client: Chat,
        data_sources: DataSource | Mapping[str, DataSource],
        semantic_layer: SemanticLayer | None = None,
        context_layer: ContextLayer | None = None,
        *,
        instructions: str | None = None,
    ) -> None:
        if not isinstance(client, Chat):
            raise TypeError(
                "client must be a chatlas.Chat, e.g. from chatlas.ChatAnthropic(), "
                f"not {type(client).__name__}."
            )
        sources = _as_data_sources(data_sources)
        if context_layer is not None and not isinstance(context_layer, ContextLayer):
            raise TypeError(
                "context_layer must be a ContextLayer from commons.context_layer(), "
                f"or None, not {type(context_layer).__name__}."
            )
        if semantic_layer is None:
            semantic_layer = _NO_MEASURES
        if not isinstance(semantic_layer, SemanticLayer):
            raise TypeError(
                "semantic_layer must be a SemanticLayer from "
                f"commons.semantic_layer(), or None, not "
                f"{type(semantic_layer).__name__}."
            )
        check_instructions(instructions)

        self._client = _agent_client(client)
        self._sources = sources
        self._context_layer = augment_context_layer(context_layer, sources.values())
        self._definitions = build_registry(sources)
        self._measures = semantic_layer.measures
        # The injectables side stays here because it is the only part that
        # knows what a DataSource is: a measure asks for a source by name and
        # receives whatever that source is queried through.
        self._injections = resolve_injections(
            self._measures, _measure_injectables(data_sources, sources)
        )
        self._first_touch = FirstTouch()
        self._handles = HandleStore()
        self._citation_request = CitationRequest()
        self._corpus = build_citation_corpus(
            self._context_layer, self._measures.values(), sources
        )
        self._restore_reminder_pending = False

        tools = build_commons_tools(
            ToolContext(
                sources=sources,
                measures=self._measures,
                definitions=self._definitions,
                context_layer=self._context_layer,
                handles=self._handles,
                citation_request=self._citation_request,
                injections=self._injections,
                first_touch=self._first_touch,
            )
        )
        self._client.set_tools(list(tools))
        self._client.system_prompt = _system_prompt(
            sources,
            self._definitions,
            instructions=instructions,
            tools=tools,
            model=self._client.model,
        )

    def __repr__(self) -> str:
        count = len(self._sources)
        plural = "" if count == 1 else "s"
        return f"A commons agent over {count} data source{plural}."

    # ---- asking it something ---------------------------------------------

    def chat(
        self,
        *args: Content | str,
        echo: EchoOptions = "output",
        stream: bool = True,
        kwargs: SubmitInputArgsT | None = None,
    ) -> ChatResponse:
        """Ask a question and wait for the whole answer."""
        was_pending = self._restore_reminder_pending
        inputs = self._prepare_turn_inputs(args)
        self._citation_request.reset()
        response = self._client.chat(*inputs, echo=echo, stream=stream, kwargs=kwargs)
        self._consume_restore_reminder(was_pending)
        return response

    async def stream_async(
        self,
        *args: Content | str,
        content: Literal["text", "all"] = "text",
        echo: EchoOptions = "none",
        kwargs: SubmitInputArgsT | None = None,
        controller: StreamController | None = None,
    ) -> AsyncGenerator[str | Content, None]:
        """Ask a question and stream the answer as it arrives.

        The signature is chatlas's, less `data_model`, so a chat UI can drive
        this agent directly: shinychat calls
        `stream_async(input, *contents, content="all", controller=controller)`
        and needs the attachment content, the mode, and the controller its
        stop button cancels through.

        Structured output is left out rather than passed through: its chunks
        are JSON to be parsed whole, and the provenance marker this appends
        would make that JSON unparseable.
        """
        from_index = len(self._client.get_turns())
        was_pending = self._restore_reminder_pending
        inputs = self._prepare_turn_inputs(args)
        self._citation_request.reset()
        raw = await self._client.stream_async(
            *inputs,
            content=content,
            echo=echo,
            kwargs=kwargs,
            controller=controller,
        )
        return self._projected(raw, from_index, was_pending)

    # Citations are always projected, so reserved model markup cannot reach
    # the browser whatever the display layer does with the stream.
    async def _projected(
        self,
        raw: AsyncGenerator[Any, None],
        from_index: int,
        was_pending: bool,
    ) -> AsyncGenerator[str | Content, None]:
        scanner = CitationScanner(self._corpus)
        async for chunk in raw:
            # A provider's structured content passes through untouched; only
            # the model's own text can carry the reserved dialect.
            if not isinstance(chunk, str):
                yield chunk
                continue
            projected = scanner.feed(chunk)
            if projected:
                yield projected

        self._consume_restore_reminder(was_pending)

        tail = scanner.finish()
        if tail:
            yield tail

        tag = derive_provenance_tag(
            collect_appended_tags(self._client.get_turns(), from_index),
            scanner.any_verified,
        )
        aside = provenance_aside(tag)
        if aside:
            yield aside

    # ---- what the agent knows --------------------------------------------

    def citation_corpus(self) -> list[CorpusEntry]:
        """The trusted text this agent's citations are verified against."""
        return list(self._corpus)

    def prewarm(self) -> None:
        """Build the caches the first question would otherwise pay for.

        Failures propagate: a direct call is typically warming caches ahead
        of a deployment, so a cold cache should fail the deploy.
        """
        if self._context_layer is not None:
            self._context_layer.prewarm()
        for source in self._sources.values():
            source.ensure_loaded()

    # ---- the turn rules ---------------------------------------------------

    def add_turn(self, turn: Turn) -> None:
        """Add a turn, restarting the citation request if a person spoke.

        A user turn of nothing but tool results is the same question still
        running, and an assistant turn is nobody asking anything.
        """
        if isinstance(turn, UserTurn) and turn_has_user_message(turn):
            self._citation_request.reset()
        self._client.add_turn(turn)

    def get_turns(self) -> list[Turn]:
        """The conversation so far."""
        return self._client.get_turns()

    def set_turns(self, turns: Sequence[Turn]) -> None:
        """Replace the conversation, dropping any reminder queued for it."""
        self._restore_reminder_pending = False
        self._client.set_turns(turns)

    def queue_restore_reminder(self) -> None:
        """Tell the next turn that the session behind its history is gone."""
        self._restore_reminder_pending = True

    def _prepare_turn_inputs(
        self, inputs: Sequence[Content | str]
    ) -> list[Content | str]:
        prepared = append_turn_reminder(inputs, self._client.model)
        if self._restore_reminder_pending:
            prepared = append_restored_conversation_reminder(prepared)
        return prepared

    # Only a reminder that was pending when the turn started is spent, so a
    # turn that failed, or one whose stream was never consumed, leaves the
    # next turn to deliver it.
    def _consume_restore_reminder(self, was_pending: bool) -> None:
        if was_pending:
            self._restore_reminder_pending = False


# Called straight from __init__, so one stacklevel reaches whoever built the
# agent from every warning below.
_CALLER = 3


def _agent_client(client: Chat) -> Chat:
    """A chat of the caller's provider and model, holding none of its state.

    The provider and the model come from `client`, and commons brings its own
    system prompt and tools, as `pkg-r/R/commons.R` does when it initializes
    from the client's provider. Building a chat rather than taking the given
    one over means an agent never changes an object its caller still holds.
    """
    if client.system_prompt is not None:
        warnings.warn(
            "The system prompt set on client is ignored; commons builds its "
            "own. Use `instructions` to add to commons' prompt.",
            stacklevel=_CALLER,
        )
    if client.get_turns():
        warnings.warn(
            "An agent starts a new conversation, so the turns on client are "
            "not carried over. Restore them with the agent's set_turns().",
            stacklevel=_CALLER,
        )

    agent_client = Chat(provider=client.provider, kwargs_chat=client.kwargs_chat)
    # chatlas never generates one, so an id the caller chose is theirs to keep.
    agent_client.conversation_id = client.conversation_id

    # chatlas has the setter for these and no getter, so they are read off the
    # attribute behind it and written back through the public setter, which
    # checks them against the provider again. An attribute that is missing, or
    # no longer a mapping, has to be told apart from an empty one, which means
    # nothing was set: dropping a temperature in silence is worse than saying
    # that this chatlas does not show what was set.
    params = getattr(client, "_standard_model_params", None)
    if not isinstance(params, Mapping):
        warnings.warn(
            "Any model parameters set on client with set_model_params() are "
            "not carried onto the agent: this version of chatlas does not "
            "expose them.",
            stacklevel=_CALLER,
        )
    elif params:
        agent_client.set_model_params(**dict(params))
    return agent_client


def _as_data_sources(
    data_sources: DataSource | Mapping[str, DataSource],
) -> dict[str, DataSource]:
    if isinstance(data_sources, DataSource):
        return {SOLE_SOURCE: data_sources}
    if not isinstance(data_sources, Mapping):
        raise TypeError(
            "data_sources must be a DataSource from commons.data_source(), or a "
            f"mapping of name to DataSource, not {type(data_sources).__name__}."
        )
    if not data_sources:
        raise ValueError("data_sources must name at least one DataSource.")
    wrong = [
        name
        for name, source in data_sources.items()
        if not isinstance(source, DataSource)
    ]
    if wrong:
        raise TypeError(
            f"Every entry in data_sources must be a DataSource from "
            f"commons.data_source(); {', '.join(sorted(wrong))} "
            f"{'is' if len(wrong) == 1 else 'are'} not."
        )
    return dict(data_sources)


# A measure can take a named source's connection as an argument named after
# the source. A lone source passed on its own has no name to be asked for, so
# it offers nothing to inject, as in pkg-r/R/commons.R.
def _measure_injectables(
    data_sources: DataSource | Mapping[str, DataSource],
    sources: Mapping[str, DataSource],
) -> dict[str, Any]:
    if isinstance(data_sources, DataSource):
        return {}
    return {name: _connection(source) for name, source in sources.items()}


def _connection(source: DataSource) -> Any:
    """What a measure queries a source through.

    The engine for a caller's database and the DuckDB connection for the
    in-process one commons builds, which is what each was queried through
    before it reached the measure.
    """
    backend = source.backend
    if isinstance(backend, EngineBackend):
        return backend.engine
    if isinstance(backend, DuckDBBackend):
        return backend.connection
    raise TypeError(f"No connection to inject for a {type(backend).__name__}.")


def _system_prompt(
    sources: Mapping[str, DataSource],
    definitions: Registry,
    instructions: str | None,
    tools: Sequence[Tool],
    model: str | None,
) -> str:
    data = system_prompt_data(
        sources,
        definitions,
        instructions=read_instructions(instructions),
        tools=[tool.name for tool in tools],
        model=model,
    )
    return render_system_prompt(system_prompt_template(), data)
