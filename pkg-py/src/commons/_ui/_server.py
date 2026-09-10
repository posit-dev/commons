"""The server side of a commons chat: what a py-shiny app wires around an agent."""

from __future__ import annotations

import warnings
from typing import Any

import shinychat
from shiny.session import Session, require_active_session

from .._agent import Commons
from .._tracing import commons_span

__all__ = ["server"]


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
        except Exception as err:  # noqa: BLE001 - any failure must warn, not abort
            # `prewarm()` fails a deployment when it is called directly, but
            # here a cold cache only costs the first question some time, and
            # an error escaping the callback would take the app down.
            warnings.warn(str(err), stacklevel=1)

    session.on_flushed(prewarm, once=True)
