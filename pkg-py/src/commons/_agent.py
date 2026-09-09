"""The agent: its layers, the tools they earn, and the rules a turn follows.

`pkg-r/R/commons.R` assembles the same agent for R, in the order this follows.
A `Commons` agent inherits directly from `chatlas.Chat`,
in the same way it inherits from `ellmer::Chat` in R. A `Commons` agent
will reject `Chat` methods it does not explicitly support to prevent
interaction without provenance and citation tracking.
"""

from __future__ import annotations

import copy
import warnings
from collections.abc import AsyncGenerator, Mapping, Sequence
from typing import Any, Literal, NoReturn

from chatlas import Chat, StreamController, Tool, Turn, UserTurn
from chatlas.types import ChatResponse, Content, SubmitInputArgsT
from pydantic import BaseModel

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


class Commons(Chat[Any, Any]):
    """A trustworthy agent that answers questions about its data.

    Given a `chatlas.Chat` for the provider and model, the data sources it
    can query, and optionally a semantic layer of trusted calculations and a
    context layer of prose, a `Commons` agent will allow for agent interactions
    with answers classified by how they were produced.

    A `Commons` agent inherits directly from `chatlas.Chat` and relies on the
    chatlas infrastructure to set up the LLM provider and model. `Commons`
    initializes its own chat state and system prompt to ensure provenance
    and citation tracking. Passing a custom system prompt in the `Commons`
    constructor is ignored with a warning; use `instructions` to add to
    commons' prompt instead. For best results, enable thinking where the
    provider and model support it.

    `chat()` and `stream_async()` are the currently supported ways to
    interact with a `Commons` agent. The other entry points chatlas offers
    (`chat_async()`, `stream()`, `chat_structured()`, etc.)
    are disabled and raise `NotImplementedError`s because they are not (yet)
    tied in to the commons framework. The rest of chatlas's surface works as
    it does on any chat.

    `data_sources` is a `DataSource`, or a mapping of name to `DataSource`;
    a measure can take a named source's connection as an argument named
    after it. `instructions` is extra text placed under an
    `## Additional instructions` heading at the end of commons' built-in
    system prompt, as a string or the path to a text or Markdown file.

    Construction raises a TypeError if `client` is not a `chatlas.Chat`, if
    an entry of `data_sources` is not a `DataSource`, or if a layer is not
    the layer its argument claims; a ValueError if `data_sources` names no
    source or a measure asks for an injection no named source can fill; and
    a FileNotFoundError if `instructions` names a file that does not exist.
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
        # What the client carried is warned about before any other argument
        # is checked, as pkg-r/R/commons.R does, so a bad later argument
        # does not eat the warning.
        _warn_ignored_client_state(client)
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

        # Share the provider, which carries the chosen model; shallow-copy
        # the chat kwargs so later changes don't cross between the two.
        super().__init__(
            provider=client.provider, kwargs_chat=copy.copy(client.kwargs_chat)
        )
        # chatlas never generates one, so an id the caller chose is explicitly kept
        self.conversation_id = client.conversation_id
        _carry_model_params(self, client)

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
        self.set_tools(list(tools))
        self.system_prompt = _system_prompt(
            sources,
            self._definitions,
            instructions=instructions,
            tools=tools,
            model=self.model,
        )

    def __repr__(self) -> str:
        count = len(self._sources)
        plural = "" if count == 1 else "s"
        return f"A commons agent over {count} data source{plural}."

    def __deepcopy__(self, memo: dict[int, Any]) -> NoReturn:
        # chatlas Chat objects can be deep-copied to fork a conversation,
        # Because a Commons agent may have database connections (which can't be copied)
        # we explicitly forbid deep copying with a clear error.
        raise NotImplementedError(
            "A commons agent cannot be copied: it holds database connections "
            "that copying cannot reach. Build a second agent instead."
        )

    # ---- asking it something ---------------------------------------------

    def chat(
        self,
        *args: Content | str,
        echo: EchoOptions = "output",
        stream: bool = True,
        kwargs: SubmitInputArgsT | None = None,
    ) -> ChatResponse:
        """Ask a question and wait for the whole answer.

        A reminder queued with `queue_restore_reminder()` rides this turn,
        and a turn that fails leaves it queued for the next one.
        """
        was_pending = self._restore_reminder_pending
        inputs = self._prepare_turn_inputs(args)
        self._citation_request.reset()
        response = super().chat(*inputs, echo=echo, stream=stream, kwargs=kwargs)
        self._consume_restore_reminder(was_pending)
        return response

    async def stream_async(
        self,
        *args: Content | str,
        content: Literal["text", "all"] = "text",
        echo: EchoOptions = "none",
        data_model: type[BaseModel] | None = None,
        kwargs: SubmitInputArgsT | None = None,
        controller: StreamController | None = None,
    ) -> AsyncGenerator[Any, None]:
        """Ask a question and stream the answer as it arrives.

        The signature is identical to chatlas's, so a chat UI can drive this agent
        directly and needs the attachment content, the mode, and the controller its
        stop button cancels through.

        The Commons agent does not accept `data_model`. If you pass it, this
        method raises NotImplementedError. In chatlas, using `data_model` means
        the chunks are JSON that the caller parses as one document. Commons adds
        provenance markers and citations to the stream that are not compatible with
        `data_model`, so it is explicitly forbidden.
        """
        if data_model is not None:
            raise NotImplementedError(
                "stream_async(data_model=...) is not available on a commons "
                "agent: the provenance marker and citations it appends would leave the "
                "streamed JSON unparseable."
            )
        from_index = len(self.get_turns())
        was_pending = self._restore_reminder_pending
        inputs = self._prepare_turn_inputs(args)
        self._citation_request.reset()
        raw = await super().stream_async(
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
        try:
            async for chunk in raw:
                # A provider's structured content passes through untouched;
                # only the model's own text can carry the reserved dialect.
                if not isinstance(chunk, str):
                    yield chunk
                    continue
                projected = scanner.feed(chunk)
                if projected:
                    yield projected
        finally:
            # A consumer that walks away early without cancelling still
            # closes the provider's stream.
            await raw.aclose()

        self._consume_restore_reminder(was_pending)

        tail = scanner.finish()
        if tail:
            yield tail

        tag = derive_provenance_tag(
            collect_appended_tags(self.get_turns(), from_index),
            scanner.any_verified,
        )
        aside = provenance_aside(tag)
        if aside:
            yield aside

    # ---- chatlas.Chat entry points a Commons agent does not support ----------------

    def chat_async(self, *args: Any, **kwargs: Any) -> NoReturn:
        raise NotImplementedError(_unrouted("chat_async"))

    def stream(self, *args: Any, **kwargs: Any) -> NoReturn:
        raise NotImplementedError(_unrouted("stream"))

    def chat_structured(self, *args: Any, **kwargs: Any) -> NoReturn:
        raise NotImplementedError(_unrouted("chat_structured"))

    def chat_structured_async(self, *args: Any, **kwargs: Any) -> NoReturn:
        raise NotImplementedError(_unrouted("chat_structured_async"))

    def extract_data(self, *args: Any, **kwargs: Any) -> NoReturn:
        raise NotImplementedError(_unrouted("extract_data"))

    def extract_data_async(self, *args: Any, **kwargs: Any) -> NoReturn:
        raise NotImplementedError(_unrouted("extract_data_async"))

    def to_solver(self, *args: Any, **kwargs: Any) -> NoReturn:
        # chatlas's solver answers each eval sample through `chat_async()` or
        # `chat_structured_async()`, so it would raise mid-eval anyway.
        raise NotImplementedError(
            "A commons agent has no to_solver(): the solver it returns "
            "answers through chat_async(), which an agent does not provide."
        )

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
        super().add_turn(turn)

    def set_turns(self, turns: Sequence[Turn]) -> None:
        """Replace the conversation, dropping any reminder queued for it."""
        self._restore_reminder_pending = False
        super().set_turns(turns)

    def queue_restore_reminder(self) -> None:
        """Tell the next turn that the session behind its history is gone."""
        self._restore_reminder_pending = True

    def _prepare_turn_inputs(
        self, inputs: Sequence[Content | str]
    ) -> list[Content | str]:
        prepared = append_turn_reminder(inputs, self.model)
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


def _warn_ignored_client_state(client: Chat) -> None:
    """Warn about whatever the agent's own chat will not carry over."""
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


def _unrouted(name: str) -> str:
    """Why an inherited entry point is closed, and what to ask instead."""
    return (
        f"A commons agent has no {name}(): it would submit a turn outside "
        "commons' turn handling, and the answer would carry neither the "
        "citation scanner's work nor a provenance marker. Ask the agent "
        "with chat() or stream_async()."
    )


def _carry_model_params(agent: Chat, client: Chat) -> None:
    """Move whatever `set_model_params()` put on the caller's chat.

    The agent brings its own system prompt and tools and starts an empty
    conversation, as `pkg-r/R/commons.R` does when it initializes from the
    client's provider, so the model parameters are all there is to carry.
    """
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
        agent.set_model_params(**dict(params))


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
