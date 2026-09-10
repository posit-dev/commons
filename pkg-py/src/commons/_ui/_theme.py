"""The theme a commons chat page is built with."""

from __future__ import annotations

import shinychat
from htmltools import HTMLDependency
from shiny.ui import Theme

from ._assets import commons_chat_dependency

__all__ = ["theme"]

# Layered over shinychat's page chat defaults. Pinned by
# tests/shared/chat-theme.json, which the R suite reads too.
_VARIABLES: dict[str, str] = {
    "border-radius": "1rem",
    "border-radius-sm": "1rem",
    "shiny-chat-page-title-font-weight": "300",
    "shiny-chat-user-message-border-radius": "0.75rem",
    "shiny-chat-user-message-padding": "0.5rem 1.5rem",
}


class _CommonsTheme(Theme):
    """A theme that also serves the commons chat assets."""

    def _html_dependencies(self) -> list[HTMLDependency]:
        # `Theme._html_dependencies()` returns a list precisely so that a subclass can
        # extend it with further dependencies
        return [*super()._html_dependencies(), commons_chat_dependency()]


def theme(
    preset: str | None = "shiny",
    **variables: str | float | bool | None,
) -> Theme:
    """Build the theme a commons chat page uses.

    Layers the commons chat variables over `shinychat.page_chat_theme()` and
    attaches the dependency serving the chat script, stylesheet and icons.

    Parameters
    ----------
    preset
        A Shiny or Bootswatch preset name.
    **variables
        Sass-variable overrides, in either `snake_case` or `kebab-case`.
        These win over the commons defaults.
    """
    # shiny reads an underscore in a variable name as a dash, so normalize
    # before merging: otherwise a caller's `border_radius` lands beside the
    # commons `border-radius` instead of replacing it, and the commons one
    # wins because Sass keeps the first `!default` it sees.
    merged: dict[str, str | float | bool | None] = dict(_VARIABLES)
    merged.update({name.replace("_", "-"): value for name, value in variables.items()})

    built = shinychat.page_chat_theme(preset=preset, **merged)
    # page_chat_theme() builds a plain Theme, (not _CommonsTheme) so
    # we rebound the class definition on the instance it returns
    built.__class__ = _CommonsTheme
    return built
