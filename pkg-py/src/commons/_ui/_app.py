"""A complete commons chat app, for local development and demos."""

from __future__ import annotations

from typing import Any

import shiny
import shinychat
from shiny import ui as shiny_ui
from shinychat.types import HistoryOptions

from .._agent import Commons
from ._server import server
from ._theme import theme

__all__ = ["app"]


def app(client: Commons, *, toolbar: bool = True, **kwargs: Any) -> shiny.App:
    """Build a complete app around a commons agent.

    This is the app for local development and a demo. A deployed app
    assembles the page and the server itself, with `commons.ui.theme()` and
    `commons.ui.server()`, and builds the agent inside the server function so
    that each session gets its own.

    Parameters
    ----------
    client
        A commons agent.
    toolbar
        Whether to show the development toolbar, a dark-mode switch. Turn it
        off when serving this app to anyone else.
    **kwargs
        Passed to `shiny.App()`.
    """
    page = shinychat.page_chat(
        "commons",
        id="chat",
        theme=theme(),
        toolbar_global=shiny_ui.toolbar(shiny_ui.input_dark_mode()) if toolbar else None,
    )

    def chat_server(
        input: shiny.Inputs, output: shiny.Outputs, session: shiny.Session
    ) -> shinychat.Chat:
        # The conversation id rides in the query string, which is what R's
        # `enableBookmarking = "url"` buys, and needs no bookmark store. It
        # appears at the first submission, so the parameter shows up while
        # the first answer is still streaming (shinychat#343).
        return server("chat", client, history=HistoryOptions(restore_mode="url"))

    # shiny discards a server function's return value, and returning the
    # chat is what makes the wiring reachable from a test, as it is in R.
    return shiny.App(page, chat_server, **kwargs)  # type: ignore[bad-argument-type]
