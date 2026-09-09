"""The theme a chat page is built with, and the assets it carries."""

import re
from typing import Any

import pytest

# shinychat brings shiny and htmltools with it, so it stands for the extra.
pytest.importorskip("shinychat", reason="commons[shiny] is not installed")

from htmltools import HTMLDocument
from shiny import ui as shiny_ui

import commons

from ._shared import load_shared_fixture

FIXTURE: dict[str, Any] = load_shared_fixture("chat-theme")["chat_theme"]

_DECLARATION = re.compile(r"^\$([\w-]+):\s*(.*?)\s*!default;$")


def effective_defaults(theme: Any) -> dict[str, str]:
    """The value each Sass variable ends up with.

    Sass takes the first `!default` declaration of a variable and ignores
    every later one, so reading the theme's own Sass in order says what it
    resolves to without paying for a Bootstrap compile.
    """
    values: dict[str, str] = {}
    for line in theme.to_sass().splitlines():
        found = _DECLARATION.match(line.strip())
        if found is not None:
            values.setdefault(found.group(1), found.group(2))
    return values


def test_the_theme_layers_the_shared_sass_variables() -> None:
    expected = FIXTURE["variables"]
    assert expected
    values = effective_defaults(commons.ui.theme())
    assert {name: values[name] for name in expected} == expected


def test_the_theme_starts_from_the_shared_preset() -> None:
    assert commons.ui.theme().preset == FIXTURE["preset"]


def test_a_variable_argument_beats_a_shared_default() -> None:
    override = FIXTURE["override"]
    # Spelled the way Python callers reach for, which is not how a Sass
    # variable is named.
    argument = override["variable"].replace("-", "_")
    theme = commons.ui.theme(**{argument: override["value"]})
    assert effective_defaults(theme)[override["variable"]] == override["value"]


def test_another_preset_can_be_asked_for() -> None:
    assert commons.ui.theme(preset="minty").preset == "minty"


def test_the_theme_carries_the_chat_assets_onto_the_page() -> None:
    page = shiny_ui.page_fillable(shiny_ui.h1("hi"), theme=commons.ui.theme())
    html = HTMLDocument(page).render()["html"]
    base = commons.ui.asset_base_url()
    assert f"{base}/commons-chat.js" in html
    assert f"{base}/commons-chat.css" in html
