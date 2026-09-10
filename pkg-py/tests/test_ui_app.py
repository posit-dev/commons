"""The complete app: what it composes for local development and demos."""

from __future__ import annotations

import pytest

# shinychat brings shiny and htmltools with it, so it stands for the extra.
pytest.importorskip("shinychat", reason="commons[shiny] is not installed")

import pandas as pd
import shiny
from htmltools import RenderedHTML
from shiny.session import session_context

import commons
from commons._agent import Commons

from ._provider import scripted_chat
from ._session import IdleSession


def agent() -> Commons:
    frame = pd.DataFrame({"revenue": [500.0, 900.0], "region": ["EMEA", "Americas"]})
    return Commons(scripted_chat(), commons.data_source(sales=frame))


def test_the_app_is_a_shiny_app() -> None:
    assert isinstance(commons.ui.app(agent()), shiny.App)


def test_the_conversation_id_rides_in_the_url() -> None:
    # R's app enables URL bookmarking so a conversation can be linked to.
    # shinychat's `url` restore mode is that, without a bookmark store.
    built = commons.ui.app(agent())
    session = IdleSession()

    with session_context(session):
        chat = built.server(session.input, session.output, session)

    assert chat is not None
    assert chat.history._restore_mode == "url"


def rendered(built: shiny.App) -> RenderedHTML:
    # `shiny.App` renders the page at construction.
    assert isinstance(built.ui, dict)
    return built.ui


def test_the_page_serves_the_commons_chat_assets() -> None:
    dependencies = rendered(commons.ui.app(agent()))["dependencies"]

    assert "commons-chat" in [dependency.name for dependency in dependencies]


def test_the_development_toolbar_carries_a_dark_mode_switch() -> None:
    html = rendered(commons.ui.app(agent()))["html"]

    assert "bslib-input-dark-mode" in html


def test_the_toolbar_can_be_turned_off_for_anyone_else() -> None:
    html = rendered(commons.ui.app(agent(), toolbar=False))["html"]

    assert "bslib-input-dark-mode" not in html
    assert 'id="chat"' in html


def test_the_client_has_to_be_a_commons_agent() -> None:
    # Refused when the app is built, not when the first visitor arrives, as
    # `commons_app()` does.
    with pytest.raises(TypeError, match="client"):
        commons.ui.app(scripted_chat())  # type: ignore[arg-type]
