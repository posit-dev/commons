"""The server side of a commons chat: what a py-shiny app wires around an agent."""

from __future__ import annotations

import logging
from typing import Any

import shinychat
from shiny.session import Session, require_active_session

from .._agent import Commons
from .._tracing import commons_span

__all__ = ["server"]

logger = logging.getLogger(__name__)


def server(id: str, client: Commons, **kwargs: Any) -> shinychat.Chat:
    """Wire a commons agent to the chat element `id` on the page.

    Pair this with a page built on `commons.ui.theme()`, so the chat assets
    the answers reference are served. In a deployed app, build the agent
    inside the server function and pass it here, so each session gets its
    own agent state.

    Parameters
    ----------
    id
        The id of the chat element on the page.
    client
        A commons agent.
    **kwargs
        Passed to `shinychat.Chat()`.

    A `client` that is not a commons agent raises `TypeError`: a plain
    chatlas chat has none of the citation or provenance handling the chat
    surface renders.
    """
    if not isinstance(client, Commons):
        raise TypeError(
            "client must be a commons agent, e.g. from commons.Commons(), "
            f"not {type(client).__name__}."
        )

    with commons_span("commons_server_start", {"commons.server.id": id}):
        _prewarm_on_idle(client, require_active_session(None))
        chat = shinychat.Chat(id, client=client, **kwargs)

        # shinychat owns the conversation identity; commons only needs to
        # know that a restore happened.
        @chat.history.on_restore
        def _(values: dict[str, Any]) -> None:
            client.queue_restore_reminder()

    return chat


def _prewarm_on_idle(client: Commons, session: Session) -> None:
    """Warm the agent's caches once the app has served its first page."""

    def prewarm() -> None:
        try:
            client.prewarm()
        except Exception as err:  # any failure must warn, not abort
            # A cold cache only costs the first question some time, and an
            # error escaping the callback would take the app down. Log rather
            # than warn: the warnings module shows an identical message only
            # once per process, which would hide a failure that recurs every
            # session.
            logger.warning("prewarm failed: %s", err, exc_info=True)

    session.on_flushed(prewarm, once=True)
