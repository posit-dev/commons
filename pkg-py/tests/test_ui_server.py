"""The server function: the setup span, the prewarm, and the restore reminder.

Whether prewarm and restore really fire in a running app is `f6e3`'s
end-to-end acceptance. What is pinned here is the wiring: that the callbacks
are registered, and what each one does when it runs.
"""

from __future__ import annotations

import logging
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

import pytest

# shinychat brings shiny and htmltools with it, so it stands for the extra.
pytest.importorskip("shinychat", reason="commons[shiny] is not installed")

import pandas as pd
import shinychat
from chatlas import Chat
from shiny.session import session_context

import commons
from commons._agent import Commons
from commons._reminders import RESTORED_CONVERSATION_REMINDER, ContentTurnReminder

from ._provider import scripted_chat, text
from ._session import IdleSession


@pytest.fixture(scope="module")
def exported_spans() -> Iterator[Callable[[], tuple[Any, ...]]]:
    """Read the spans a test recorded, or skip without the SDK.

    A tracer provider can only be set once per process, so an SDK one another
    module installed is reused and this exporter added alongside its own.
    """
    pytest.importorskip("opentelemetry.sdk", reason="commons[tracing] is not installed")
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor
    from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
        InMemorySpanExporter,
    )

    provider = trace.get_tracer_provider()
    if not isinstance(provider, TracerProvider):
        provider = TracerProvider()
        trace.set_tracer_provider(provider)
    exporter = InMemorySpanExporter()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    yield exporter.get_finished_spans
    exporter.clear()


def frame() -> pd.DataFrame:
    return pd.DataFrame(
        {"revenue": [500.0, 900.0, 300.0], "region": ["EMEA", "Americas", "EMEA"]}
    )


def agent_with(client: Chat, **kwargs: Any) -> Commons:
    return Commons(client, commons.data_source(sales=frame()), **kwargs)


def test_the_client_has_to_be_a_commons_agent() -> None:
    # A plain chatlas chat has none of the citation or provenance handling the
    # surface renders, so it is refused rather than half-served.
    with pytest.raises(TypeError, match="client"):
        commons.ui.server("chat", scripted_chat())  # type: ignore[arg-type]


def test_the_chat_is_wired_to_the_agent() -> None:
    agent = agent_with(scripted_chat())
    session = IdleSession()

    with session_context(session):
        chat = commons.ui.server("chat", agent)

    assert isinstance(chat, shinychat.Chat)
    # shinychat wraps the client it was handed rather than holding it directly.
    wrapper = chat.client
    assert wrapper is not None
    assert wrapper.value is agent


def test_restoring_a_conversation_queues_the_restore_reminder() -> None:
    agent = agent_with(scripted_chat([text("An answer.")]))
    session = IdleSession()
    with session_context(session):
        chat = commons.ui.server("chat", agent)

    # shinychat fires these when it has replayed a stored conversation.
    for callback in chat.history._restore_callbacks:
        callback({})

    agent.chat("A question.", echo="none")
    reminders = [
        content.text
        for content in agent.get_turns()[0].contents
        if isinstance(content, ContentTurnReminder)
    ]
    assert RESTORED_CONVERSATION_REMINDER in reminders


def test_prewarm_runs_when_the_session_first_goes_idle(tmp_path: Path) -> None:
    notes = tmp_path / "notes.md"
    notes.write_text("# Revenue\n\nRevenue means booked revenue.", encoding="utf-8")
    agent = agent_with(
        scripted_chat(), context_layer=commons.context_layer(files=[notes])
    )
    layer = agent._context_layer
    assert layer is not None
    session = IdleSession()

    with session_context(session):
        commons.ui.server("chat", agent)

    # Warming is what the first question would otherwise pay for, so nothing
    # is built until the app has served its first page.
    assert layer._store_cache is None
    # once=True: warming fires on the first idle only, not on every flush.
    assert [once for _, once in session.idle_callbacks] == [True]
    session.go_idle()
    assert layer._store_cache is not None
    assert session.idle_callbacks == []


def test_a_failed_prewarm_is_logged_rather_than_stopping_the_app(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    pins = pytest.importorskip("pins")
    board = pins.board_folder(str(tmp_path))
    board.pin_write({"not": "a frame"}, "sales-pin", type="json")
    agent = Commons(
        scripted_chat(), commons.data_source(board, tables={"sales": "sales-pin"})
    )
    session = IdleSession()
    with session_context(session):
        commons.ui.server("chat", agent)

    # A cold cache is worth a log entry; an error escaping the callback would
    # take the app down with it.
    with caplog.at_level(logging.WARNING, logger="commons._ui._server"):
        session.go_idle()
    assert "not a data frame" in caplog.text


def test_extra_kwargs_are_passed_to_shinychat() -> None:
    agent = agent_with(scripted_chat())
    session = _IdleSession()

    with session_context(session):
        chat = commons.ui.server("chat", agent, on_error="unhandled")

    assert chat.on_error == "unhandled"


def test_the_setup_span_records_the_chat_element_id(
    exported_spans: Callable[[], tuple[Any, ...]],
) -> None:
    agent = agent_with(scripted_chat())

    with session_context(IdleSession()):
        commons.ui.server("chat", agent)

    (span,) = [span for span in exported_spans() if span.name == "commons_server_start"]
    assert span.attributes is not None
    assert span.attributes["commons.server.id"] == "chat"
