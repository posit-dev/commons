"""The chat surface: what a py-shiny app needs to drive an agent."""

from __future__ import annotations

try:
    from ._assets import asset_base_url, commons_chat_dependency
    from ._theme import theme
except ModuleNotFoundError as err:
    # shiny, shinychat and htmltools arrive with the `shiny` extra.
    raise ImportError(
        f"commons.ui needs {err.name}, which is not installed. "
        'Install it with: pip install "commons[shiny]"'
    ) from err

__all__ = ["asset_base_url", "commons_chat_dependency", "theme"]
